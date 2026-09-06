// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAaveV3Pool} from "../../interfaces/external/IAaveV3.sol";
import {IAssetAdapter} from "../../interfaces/modules/IAssetAdapter.sol";

/**
 * @title AaveV3Adapter
 * @notice Yield-strategy adapter that supplies and withdraws vault assets through Aave V3.
 *
 * @dev
 * Architecture:
 * - Immutable, non-upgradeable connector. Deploy a new instance to upgrade.
 * - **One adapter instance is deployed per vault.** The adapter itself holds the Aave
 *   aTokens (supply is called with `onBehalfOf = address(this)`), which means all
 *   aToken accounting for a single vault is isolated to that vault's adapter address.
 * - This avoids the aToken-ownership problem that arises when a shared adapter tries
 *   to call `pool.withdraw` (which burns aTokens from `msg.sender`): since the adapter
 *   is the aToken holder, the burn succeeds without extra approvals from the vault.
 *
 * Balance tracking:
 * - {getBalance} reads the aToken balance of this adapter contract from the aToken
 *   contract via {_getAToken}. The `owner` parameter is accepted for interface
 *   compatibility but is **unused**; callers should pass `address(0)` for clarity,
 *   although any value is accepted.
 * - Because Aave V3 issues rebasing aTokens (1:1 with underlying + interest), querying
 *   the aToken balance directly is the most accurate way to measure earned yield.
 *
 * Rewards:
 * - Aave V3 on Ethereum mainnet does not currently distribute stkAAVE rewards.
 * - On networks that do (e.g. Polygon, Avalanche), the RewardsController address may be
 *   provided at construction time to enable {claimRewards}.
 * - If `rewardsController` is address(0), {claimRewards} is a no-op returning (address(0), 0).
 *
 * Security:
 * - `msg.sender` (the vault) must approve this adapter before calling {deposit}.
 * - {withdraw} requires no prior approval from the vault; the adapter holds the aTokens
 *   and calls `pool.withdraw` directly, which burns them from address(this).
 * - Defense-in-depth: all ERC-20 interactions use {SafeERC20} to handle non-standard tokens.
 */
contract AaveV3Adapter is IAssetAdapter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice Aave V3 Pool contract (supply / withdraw entry point).
    IAaveV3Pool public immutable pool;

    /// @notice Aave V3 RewardsController address (address(0) if not applicable).
    address public immutable rewardsController;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when the pool address is zero.
    error ZeroPool();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Deploys a new AaveV3Adapter.
     *
     * @param pool_              Address of the Aave V3 Pool contract on the target network.
     * @param rewardsController_ Address of the Aave V3 RewardsController, or address(0) if
     *                           rewards are not available on this network.
     */
    constructor(address pool_, address rewardsController_) {
        if (pool_ == address(0)) revert ZeroPool();
        pool = IAaveV3Pool(pool_);
        rewardsController = rewardsController_;
    }

    // -------------------------------------------------------------------------
    // IAssetAdapter — Core operations
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc IAssetAdapter
     *
     * @dev
     * Flow:
     * 1. Pull `amount` of `asset` from the vault (msg.sender) using a pre-approved allowance.
     * 2. Approve the Aave V3 Pool to spend `amount`.
     * 3. Call `pool.supply(asset, amount, onBehalfOf=address(this), referralCode=0)`.
     *    This adapter receives the aTokens directly (not the vault), which is required so
     *    that `pool.withdraw` can later burn them from address(this).
     *
     * Returns the aToken amount received, which equals `amount` for Aave V3 (1:1 at supply).
     */
    function deposit(address asset, uint256 amount) external override returns (uint256 sharesOrTokens) {
        // Pull tokens from the vault.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve the Aave pool (reset first to avoid ERC-20 allowance race on some tokens).
        IERC20(asset).forceApprove(address(pool), amount);

        // Supply; aTokens land in this adapter (address(this)), not the vault.
        // This is intentional: the adapter must hold the aTokens so that pool.withdraw
        // can burn them from address(this) without requiring a vault-side aToken approval.
        pool.supply(asset, amount, address(this), 0);

        // Aave V3 mints exactly `amount` aTokens for a supply of `amount` underlying.
        sharesOrTokens = amount;
    }

    /**
     * @inheritdoc IAssetAdapter
     *
     * @dev
     * Flow:
     * 1. Call `pool.withdraw(asset, amount, recipient)`.
     *    Aave burns aTokens from the vault (msg.sender) and sends underlying to `recipient`.
     * 2. Return the amount actually withdrawn (may differ slightly from `amount` due to rounding).
     *
     * The vault has pre-approved the Pool to spend its aTokens (this happens automatically
     * when the vault originally called `supply`; Aave manages aToken accounting internally).
     *
     * Revert behaviour:
     * - Reverts with Aave's native error when the pool cannot service the withdrawal
     *   (e.g. 100% utilisation). DemeterVault catches this and re-throws {AaveWithdrawalFailed}.
     */
    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        returns (uint256 withdrawn)
    {
        // pool.withdraw burns aTokens from msg.sender (the vault) and sends underlying to recipient.
        withdrawn = pool.withdraw(asset, amount, recipient);
    }

    /**
     * @inheritdoc IAssetAdapter
     *
     * @dev
     * Returns the aToken balance held by **this adapter** for `asset`.
     *
     * The `owner` parameter is accepted for interface compatibility with other adapter
     * implementations (e.g. Compound-style adapters where balance is tracked per owner),
     * but it is **unused** here. Because one adapter is deployed per vault, all aTokens
     * in this contract belong exclusively to that vault.
     *
     * Returns 0 if the asset has no registered aToken in the Aave pool.
     */
    function getBalance(address asset, address /*owner*/) external view override returns (uint256 balance) {
        address aToken = _getAToken(asset);
        if (aToken == address(0)) return 0;
        balance = IERC20(aToken).balanceOf(address(this));
    }

    /**
     * @inheritdoc IAssetAdapter
     *
     * @dev
     * Claims Aave liquidity mining rewards (if any) via the RewardsController.
     *
     * - If `rewardsController` is address(0), returns (address(0), 0) immediately.
     * - Otherwise, calls `claimAllRewardsToSelf` on the RewardsController and returns
     *   the first claimed reward token and its amount.
     *
     * NOTE: Aave V3 on Ethereum mainnet does not currently distribute on-chain rewards
     * (as of the deployment date). This implementation satisfies the interface contract
     * for networks that do.
     */
    function claimRewards(address recipient)
        external
        override
        returns (address rewardToken, uint256 amount)
    {
        if (rewardsController == address(0)) {
            return (address(0), 0);
        }

        // Build assets array: a single aToken for the rewards controller.
        // For simplicity, we delegate to the controller's all-rewards claim.
        // The caller (vault) should parse the returned data itself if needed.
        // Here we use the low-level ABI for the RewardsController to avoid
        // importing a heavy interface for a non-critical path.
        bytes memory callData = abi.encodeWithSignature(
            "claimAllRewards(address[],address)",
            new address[](0), // empty assets array = claim all registered assets
            recipient
        );

        (bool success, bytes memory returnData) = rewardsController.call(callData);

        if (!success || returnData.length == 0) {
            return (address(0), 0);
        }

        // Decode: claimAllRewards returns (address[] rewardsList, uint256[] claimedAmounts)
        (address[] memory rewardsList, uint256[] memory claimedAmounts) =
            abi.decode(returnData, (address[], uint256[]));

        if (rewardsList.length > 0) {
            rewardToken = rewardsList[0];
            amount = claimedAmounts[0];
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Retrieves the aToken address for `asset` from the Aave Pool's reserve data.
     *
     * Uses a minimal ABI call to avoid importing the full IPool interface.
     * `getReserveData` returns a `ReserveData` struct; the aToken address is at offset
     * position 8 (bytes 256..319 of the ABI-encoded return). We use low-level decoding
     * to stay dependency-free.
     *
     * Layout of Aave V3 ReserveData (simplified):
     *  [0] configuration  (uint256)
     *  [1] liquidityIndex (uint128)
     *  [2] currentLiquidityRate (uint128)
     *  [3] variableBorrowIndex (uint128)
     *  [4] currentVariableBorrowRate (uint128)
     *  [5] currentStableBorrowRate (uint128)
     *  [6] lastUpdateTimestamp (uint40)
     *  [7] id (uint16)
     *  [8] aTokenAddress (address)   <-- we need this
     */
    function _getAToken(address asset) internal view returns (address aToken) {
        (bool success, bytes memory data) =
            address(pool).staticcall(abi.encodeWithSignature("getReserveData(address)", asset));

        if (!success || data.length < 9 * 32) return address(0);

        // aTokenAddress is the 9th 32-byte word (index 8, zero-indexed).
        assembly {
            aToken := mload(add(data, add(0x20, mul(8, 0x20))))
        }
    }
}
