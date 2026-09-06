// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "./Constants.sol";
import {VaultStorage} from "./VaultStorage.sol";
import {IProtocolAddressProvider} from "../interfaces/core/IProtocolAddressProvider.sol";
import {IAssetAdapter} from "../interfaces/modules/IAssetAdapter.sol";
import {IPriceOracle} from "../interfaces/modules/IPriceOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title VaultMath
 * @notice Pure math and view helpers for Demeter multi-asset vaults.
 *
 * @dev
 * This library centralizes every financial formula touched by the vault:
 *
 * - Total AUM in USD (idle balance + yield-adapter balance, oracle-priced).
 * - Portfolio drift detection vs. target weights.
 * - Share minting math with virtual-offset inflation defence.
 * - Share redemption math (pro-rata per-asset, round-down).
 * - NAV-per-share for high-water-mark fee tracking.
 * - Management fee accrual (time-based, annualized).
 * - Performance fee calculation (high-water-mark model).
 *
 * Rounding conventions (vault-favourable):
 * - {calcSharesToMint}  → Floor  (depositor receives fewer shares)
 * - {calcAssetToReturn} → Floor  (withdrawer receives fewer tokens)
 * - All fee share minting → Floor (fee recipient receives slightly less)
 *
 * All AUM figures are denominated in USD with {Constants.AUM_DECIMALS} = 8 decimals
 * (e.g. $1.00 = 1e8 AUM units), matching standard Chainlink price feed precision.
 * Vault shares carry 18 decimals (VAULT_DECIMALS = 18).
 */
library VaultMath {
    // =========================================================================
    // Total AUM
    // =========================================================================

    /**
     * @notice Computes the total AUM of the vault in USD (8-decimal precision).
     *
     * @dev
     * For each asset in the portfolio the function sums:
     *   - `asset.balanceOf(vault)`                          — idle (in-vault) balance
     *   - `IAssetAdapter(adapter).getBalance(asset, vault)` — yield-deployed balance (if any)
     *
     * Each balance is converted to USD using the Chainlink oracle registered in
     * the `ProtocolAddressProvider`. Adapter read failures are silently swallowed
     * so that a malfunctioning adapter does not render the vault inoperable.
     *
     * @param s Vault storage layout.
     * @return totalAUM Total AUM in USD, scaled to {Constants.AUM_DECIMALS} (1e8 = $1).
     */
    function computeTotalAUMUsd(VaultStorage.Layout storage s) internal view returns (uint256 totalAUM) {
        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        address oracleAddr = provider.getPriceOracle();
        require(oracleAddr != address(0), "VaultMath: oracle not set");
        IPriceOracle oracle = IPriceOracle(oracleAddr);

        uint256 len = s.assets.length;
        for (uint256 i; i < len; ) {
            address asset = s.assets[i];
            if (asset == address(0)) { unchecked { i++; } continue; }

            // Idle balance held directly by the vault.
            uint256 balance = IERC20Metadata(asset).balanceOf(address(this));

            // Yield-adapter balance (e.g. aTokens held via AaveV3Adapter).
            address adapter = s.strategyAdapter[asset];
            if (adapter != address(0)) {
                // Swallow adapter failures: a broken adapter should not block
                // every vault operation. The AUM will be understated but the
                // vault remains operational.
                try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 adapterBal) {
                    balance += adapterBal;
                } catch {}
            }

            if (balance == 0) { unchecked { i++; } continue; }

            // USD value: priceUsd has ORACLE_PRICE_DECIMALS (8) decimals.
            // Normalise by asset decimals so value is also in 8-decimal USD.
            uint256 priceUsd     = oracle.getPrice(asset);
            uint8   assetDec     = IERC20Metadata(asset).decimals();
            uint256 valueUsd     = Math.mulDiv(balance, priceUsd, 10 ** uint256(assetDec));
            totalAUM += valueUsd;

            unchecked { i++; }
        }
    }

    // =========================================================================
    // Portfolio drift
    // =========================================================================

    /**
     * @notice Returns `false` if any asset's actual weight deviates from its
     *         target by more than `maxDriftBps`.
     *
     * @dev
     * Actual weight for asset i:  actualBps = valueUsd_i * BPS / totalAUM
     * Drift for asset i:          |actualBps - targetBps_i|
     *
     * An empty portfolio (totalAUM == 0) is considered balanced.
     *
     * @param s           Vault storage layout.
     * @param maxDriftBps Maximum allowed per-asset deviation in basis points.
     * @return balanced   True when every asset is within the allowed drift band.
     */
    function isPortfolioBalanced(
        VaultStorage.Layout storage s,
        uint256 maxDriftBps
    ) internal view returns (bool balanced) {
        uint256 totalAUM_ = computeTotalAUMUsd(s);
        if (totalAUM_ == 0) return true;

        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        address oracleAddr = provider.getPriceOracle();
        require(oracleAddr != address(0), "VaultMath: oracle not set");
        IPriceOracle oracle = IPriceOracle(oracleAddr);

        uint256 len = s.assets.length;
        require(len == s.weights.length, "VaultMath: assets/weights length mismatch");

        for (uint256 i; i < len; ) {
            address asset = s.assets[i];
            if (asset == address(0)) { unchecked { i++; } continue; }

            uint256 balance = IERC20Metadata(asset).balanceOf(address(this));
            address adapter = s.strategyAdapter[asset];
            if (adapter != address(0)) {
                try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                    balance += ab;
                } catch {}
            }

            if (balance == 0 && s.weights[i] == 0) { unchecked { i++; } continue; }

            uint256 priceUsd  = oracle.getPrice(asset);
            uint8   assetDec  = IERC20Metadata(asset).decimals();
            uint256 valueUsd  = Math.mulDiv(balance, priceUsd, 10 ** uint256(assetDec));

            uint256 actualBps = Math.mulDiv(valueUsd, Constants.BPS, totalAUM_);
            uint256 targetBps = s.weights[i];
            uint256 diff      = actualBps > targetBps ? actualBps - targetBps : targetBps - actualBps;

            if (diff > maxDriftBps) return false;

            unchecked { i++; }
        }
        return true;
    }

    // =========================================================================
    // Share minting (deposits)
    // =========================================================================

    /**
     * @notice Calculates shares to mint for a given USD deposit value.
     *
     * @dev
     * Uses a virtual-offset model (inspired by OZ ERC-4626 decimal offset) to
     * prevent the "first deposit inflation attack":
     *
     *   shares = depositAUM * (totalShares + VIRTUAL_SHARES)
     *                       / (totalAUM    + VIRTUAL_AUM   )   [Floor]
     *
     * With {Constants.VIRTUAL_SHARES} = 1e10 and {Constants.VIRTUAL_AUM} = 1:
     * - The initial share price is anchored at ~$1 per share.
     * - An attacker who deposits 1 wei of AUM first would gain only 1e10 share
     *   units (≈ 0 shares), making griefing economically unviable.
     * - No explicit dead-share minting is required.
     *
     * Rounding: Floor — the depositor receives fewer shares when division is not exact.
     *
     * @param depositAUM  USD value of the deposit (8-decimal precision).
     * @param totalAUM    Pre-deposit total AUM (8-decimal precision).
     * @param totalShares Pre-deposit total shares (18-decimal share units).
     * @return shares     Share units to mint (18-decimal).
     */
    function calcSharesToMint(
        uint256 depositAUM,
        uint256 totalAUM,
        uint256 totalShares
    ) internal pure returns (uint256 shares) {
        shares = Math.mulDiv(
            depositAUM,
            totalShares + Constants.VIRTUAL_SHARES,
            totalAUM    + Constants.VIRTUAL_AUM,
            Math.Rounding.Floor
        );
    }

    // =========================================================================
    // Asset redemption (withdrawals)
    // =========================================================================

    /**
     * @notice Calculates the amount of a single asset to return for a given
     *         share redemption.
     *
     * @dev
     * Pro-rata formula:
     *   amount = shares * totalAssetBalance / totalShares   [Floor]
     *
     * Rounding: Floor — the withdrawer receives slightly fewer tokens, which
     * protects the vault from rounding-based insolvency.
     *
     * @param shares             Shares being redeemed.
     * @param totalShares        Current total share supply.
     * @param totalAssetBalance  Total vault-controlled balance of this asset
     *                           (idle + adapter balance).
     * @return amount            Token amount to transfer to the withdrawer.
     */
    function calcAssetToReturn(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAssetBalance
    ) internal pure returns (uint256 amount) {
        if (totalShares == 0) return 0;
        amount = Math.mulDiv(shares, totalAssetBalance, totalShares, Math.Rounding.Floor);
    }

    // =========================================================================
    // NAV per share
    // =========================================================================

    /**
     * @notice Returns the current NAV per share.
     *
     * @dev
     * navPerShare = totalAUM * 1e18 / totalShares
     *
     * The result is expressed in AUM-units per 1e18 share-units.
     * Example: $1000 AUM (= 1e11), 1000 shares (= 1e21 share units)
     *          → navPerShare = 1e11 * 1e18 / 1e21 = 1e8  (i.e. $1.00 per share).
     *
     * This scaling ensures non-zero and precise results when stored as the
     * high-water-mark for performance fee calculations.
     *
     * @param totalAUM    Total AUM in 8-decimal USD units.
     * @param totalShares Total shares in 18-decimal share units.
     * @return nav        NAV per share (AUM units × 1e18 / share units).
     */
    function navPerShare(uint256 totalAUM, uint256 totalShares) internal pure returns (uint256 nav) {
        if (totalShares == 0) return 0;
        nav = Math.mulDiv(totalAUM, 1e18, totalShares, Math.Rounding.Floor);
    }

    // =========================================================================
    // Management fee (time-based, annualized)
    // =========================================================================

    /**
     * @notice Calculates management fee AUM accrued over a time interval.
     *
     * @dev
     * Annualized rate in bps applied pro-rata over `dt` seconds:
     *
     *   annualRateWad = mgmtFeeBps * 1e14          // bps → WAD (1e18)
     *   rDelta        = annualRateWad * dt / SECONDS_PER_YEAR
     *   feeAUM        = aumSnapshot * rDelta / 1e18
     *
     * Integer precision is maintained throughout; the result rounds toward zero.
     *
     * @param aumSnapshot AUM at the last fee collection (8-decimal USD).
     * @param dt          Seconds elapsed since last fee collection.
     * @param mgmtFeeBps  Annualized management fee in basis points (1e4 = 100%).
     * @return feeAUM     Accrued management fee in 8-decimal USD.
     */
    function calcManagementFeeAUM(
        uint256 aumSnapshot,
        uint256 dt,
        uint256 mgmtFeeBps
    ) internal pure returns (uint256 feeAUM) {
        if (aumSnapshot == 0 || dt == 0 || mgmtFeeBps == 0) return 0;

        // Convert bps to WAD annual rate then pro-rate by elapsed time.
        uint256 annualRateWad = mgmtFeeBps * 1e14;
        uint256 rDelta        = Math.mulDiv(annualRateWad, dt, Constants.SECONDS_PER_YEAR);
        feeAUM = Math.mulDiv(aumSnapshot, rDelta, 1e18);
    }

    // =========================================================================
    // Performance fee (high-water mark)
    // =========================================================================

    /**
     * @notice Calculates performance fee AUM above the high-water-mark.
     *
     * @dev
     * - `highWaterMark` and `currentNAV` must both be in the same unit returned
     *   by {navPerShare}: AUM-units × 1e18 / share-units.
     * - Fee is charged only on gains above the HWM:
     *
     *   gainPerShare = currentNAV - highWaterMark
     *   gainAUM      = gainPerShare * totalShares / 1e18
     *   feeAUM       = gainAUM * perfFeeBps / BPS
     *
     * The caller is responsible for updating `highWaterMark` after minting the
     * fee shares, so that the HWM ratchets up monotonically.
     *
     * @param highWaterMark  Historical max NAV per share (navPerShare units).
     * @param currentNAV     Current NAV per share (navPerShare units).
     * @param totalShares    Current total share supply (18-decimal).
     * @param perfFeeBps     Performance fee rate in basis points.
     * @return feeAUM        Performance fee in 8-decimal USD.
     */
    function calcPerformanceFeeAUM(
        uint256 highWaterMark,
        uint256 currentNAV,
        uint256 totalShares,
        uint256 perfFeeBps
    ) internal pure returns (uint256 feeAUM) {
        if (totalShares == 0 || perfFeeBps == 0) return 0;
        if (currentNAV <= highWaterMark) return 0;

        uint256 gainPerShare = currentNAV - highWaterMark;
        // Convert back from (AUM-units × 1e18 / share-units) × share-units → AUM-units.
        uint256 gainAUM = Math.mulDiv(gainPerShare, totalShares, 1e18, Math.Rounding.Floor);
        feeAUM = Math.mulDiv(gainAUM, perfFeeBps, Constants.BPS, Math.Rounding.Floor);
    }
}
