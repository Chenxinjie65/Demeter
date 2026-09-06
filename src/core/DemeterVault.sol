// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDemeterVault} from "../interfaces/core/IDemeterVault.sol";
import {IProtocolAddressProvider} from "../interfaces/core/IProtocolAddressProvider.sol";
import {IAssetWhitelist} from "../interfaces/modules/IAssetWhitelist.sol";
import {IAssetAdapter} from "../interfaces/modules/IAssetAdapter.sol";
import {IPriceOracle} from "../interfaces/modules/IPriceOracle.sol";
import {ICircuitBreaker} from "../interfaces/modules/ICircuitBreaker.sol";
import {IUniswapV3SwapRouter} from "../interfaces/external/IUniswapV3.sol";

import {VaultStorage} from "../libraries/VaultStorage.sol";
import {VaultMath} from "../libraries/VaultMath.sol";
import {TransientReentrancyGuard} from "../libraries/TransientLock.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";
import {DataTypes} from "../libraries/DataTypes.sol";

/**
 * @title DemeterVault
 * @notice Core multi-asset index vault with in-kind deposits/withdrawals and yield integration.
 *
 * @dev
 * Architecture:
 * - BeaconProxy pattern: this contract is the implementation behind UpgradeableBeacon.
 * - Storage: ERC-7201 namespaced slot via {VaultStorage.layout()}.
 * - ERC-20: inline implementation (no inheritance) to avoid storage collisions.
 * - Reentrancy: EIP-1153 transient-storage guard via {TransientReentrancyGuard}.
 * - Yield: pluggable {IAssetAdapter} per asset (e.g. AaveV3Adapter).
 * - Safety: CircuitBreaker (ERC-7265), Pausable, Ownable2Step manager, Chainlink slippage guard.
 *
 * Key invariants:
 * - Deposits: strictly in-kind (proportional basket). Oracle only used on bootstrap.
 * - Withdrawals: strictly pro-rata. Oracle NOT used (pure ratio-based).
 * - Rounding: always floor (vault-favourable) for both mint and burn.
 * - Inflation defence: virtual offset in {VaultMath.calcSharesToMint} (bootstrap only).
 * - Aave DoS: withdrawals gracefully handle 100% utilization by reverting with clear error.
 * - Emergency: Guardian can pause deposits/rebalance; withdrawals always enabled.
 * - Buffer restoration: withdrawMulti restores the idle buffer ratio in one Aave round-trip.
 */
contract DemeterVault is Initializable, TransientReentrancyGuard, IDemeterVault {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice ERC-20 decimals for vault shares (standard 18).
    uint8 public constant VAULT_DECIMALS = 18;

    // =========================================================================
    // Storage accessor
    // =========================================================================

    function _layout() private pure returns (VaultStorage.Layout storage) {
        return VaultStorage.layout();
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Disables initializers on the implementation contract.
     * @dev Prevents direct initialization of the implementation; only proxies may call {initialize}.
     */
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // Initialization (BeaconProxy)
    // =========================================================================

    /**
     * @notice Initializes a newly deployed DemeterVault proxy.
     * @dev
     * - MUST be called exactly once per proxy instance.
     * - Validates:
     *   - Assets and weights arrays match in length.
     *   - Weights sum to BPS (10_000).
     *   - All assets are whitelisted.
     * - Sets up ERC-20 metadata, fee configuration, and rebalancing parameters.
     *
     * @param params Initialization parameters (see {IDemeterVault.InitializeParams}).
     */
    function initialize(InitializeParams calldata params) external override initializer {
        VaultStorage.Layout storage s = _layout();

        // Validate inputs.
        if (params.assets.length != params.weights.length) revert Errors.WeightsMismatch();
        if (params.assets.length == 0) revert Errors.ArraysLengthMismatch();

        uint256 weightSum;
        for (uint256 i; i < params.weights.length; ) {
            if (params.weights[i] == 0) revert Errors.InvalidWeight();
            weightSum += params.weights[i];
            unchecked { i++; }
        }
        if (weightSum != Constants.BPS) revert Errors.WeightsNotNormalized();

        // Validate assets are whitelisted.
        IProtocolAddressProvider provider = IProtocolAddressProvider(params.addressProvider);
        address whitelistAddr = provider.getAssetWhitelist();
        if (whitelistAddr != address(0)) {
            IAssetWhitelist whitelist = IAssetWhitelist(whitelistAddr);
            for (uint256 i; i < params.assets.length; ) {
                if (!whitelist.isWhitelisted(params.assets[i])) {
                    revert Errors.AssetNotInPortfolio(params.assets[i]);
                }
                unchecked { i++; }
            }
        }

        // Store configuration.
        s.baseAsset        = params.baseAsset;
        s.manager          = params.manager;
        s.addressProvider  = params.addressProvider;
        s.assets           = params.assets;
        s.weights          = params.weights;
        s.name             = params.name;
        s.symbol           = params.symbol;
        s.isMutable        = params.isMutable;
        s.circuitBreaker   = params.circuitBreaker;

        // Build reverse index: asset => 1-based index.
        for (uint256 i; i < params.assets.length; ) {
            s.assetIndex[params.assets[i]] = i + 1;
            unchecked { i++; }
        }

        // Fee configuration (read from AddressProvider treasury + defaults).
        address treasury = provider.getTreasury();
        s.feeRecipient       = treasury != address(0) ? treasury : params.manager;
        s.performanceFeeBps  = Constants.DEFAULT_PERFORMANCE_FEE_BPS;
        s.managementFeeBps   = Constants.DEFAULT_MANAGEMENT_FEE_BPS;

        // Rebalancing parameters.
        s.maxDriftBps        = 500;  // 5% default drift threshold.
        s.rebalanceCooldown  = Constants.DEFAULT_REBALANCE_COOLDOWN;
        s.bufferRatioBps     = uint16(Constants.DEFAULT_BUFFER_RATIO_BPS);
        s.maxSlippageBps     = uint16(Constants.DEFAULT_MAX_SLIPPAGE_BPS);

        // Mark as initialized.
        s.initialized = true;
    }

    // =========================================================================
    // ERC-20 Metadata (IERC20Metadata)
    // =========================================================================

    function name() external view override returns (string memory) {
        return _layout().name;
    }

    function symbol() external view override returns (string memory) {
        return _layout().symbol;
    }

    function decimals() external pure override returns (uint8) {
        return VAULT_DECIMALS;
    }

    function totalSupply() external view override returns (uint256) {
        return _layout().totalShares;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _layout().balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _layout().allowances[owner][spender];
    }

    // =========================================================================
    // ERC-20 Transfer Functions
    // =========================================================================

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        VaultStorage.Layout storage s = _layout();
        uint256 currentAllowance = s.allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert Errors.InsufficientShares(amount, currentAllowance);
            unchecked {
                _approve(from, msg.sender, currentAllowance - amount);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // =========================================================================
    // Vault View Functions (IDemeterVault)
    // =========================================================================

    function manager() external view override returns (address) {
        return _layout().manager;
    }

    function isMutable() external view override returns (bool) {
        return _layout().isMutable;
    }

    function baseAsset() external view override returns (address) {
        return _layout().baseAsset;
    }

    function addressProvider() external view override returns (address) {
        return _layout().addressProvider;
    }

    function getAssets() external view override returns (address[] memory) {
        return _layout().assets;
    }

    function getWeights() external view override returns (uint256[] memory) {
        return _layout().weights;
    }

    function getStrategy(address asset) external view override returns (address) {
        return _layout().strategyAdapter[asset];
    }

    function totalAUM() external view override returns (uint256) {
        return VaultMath.computeTotalAUMUsd(_layout());
    }

    function navPerShare() external view override returns (uint256) {
        VaultStorage.Layout storage s = _layout();
        uint256 aum = VaultMath.computeTotalAUMUsd(s);
        return VaultMath.navPerShare(aum, s.totalShares);
    }

    function performanceFeeBps() external view override returns (uint16) {
        return _layout().performanceFeeBps;
    }

    function managementFeeBps() external view override returns (uint16) {
        return _layout().managementFeeBps;
    }

    function feeRecipient() external view override returns (address) {
        return _layout().feeRecipient;
    }

    /**
     * @inheritdoc IDemeterVault
     */
    function getTotalBalance(address asset) external view override returns (uint256 total) {
        VaultStorage.Layout storage s = _layout();
        total = IERC20(asset).balanceOf(address(this));
        address adapter = s.strategyAdapter[asset];
        if (adapter != address(0)) {
            try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                total += ab;
            } catch {}
        }
    }

    // =========================================================================
    // Multi-Asset Deposit (In-Kind)
    // =========================================================================

    /**
     * @notice Deposits a proportional basket of assets and mints shares to the receiver.
     *
     * @dev
     * Bootstrap path (totalShares == 0):
     * 1. Pause check.
     * 2. Validate maxAmountsIn length and non-zero amounts.
     * 3. Collect accrued fees (no-op on first deposit).
     * 4. Compute deposit AUM via oracle.
     * 5. Mint shares = VaultMath.calcSharesToMint(depositAUM, 0, 0).
     * 6. Validate shares >= sharesOut (minSharesOut guard).
     * 7. Transfer all maxAmountsIn from sender → vault.
     * 8. Deploy excess to adapters (respecting bufferRatio).
     * 9. Update AUM snapshot and HWM to post-deposit values.
     * 10. Emit Deposited event.
     *
     * Normal path (totalShares > 0):
     * 1. Pause check.
     * 2. Validate maxAmountsIn length.
     * 3. Collect accrued fees (updates totalShares).
     * 4. For each asset: compute actualAmounts[i] = sharesOut * totalBal[i] / totalShares.
     * 5. Validate actualAmounts[i] <= maxAmountsIn[i] (per-asset slippage guard).
     * 6. Transfer actualAmounts[i] from sender → vault.
     * 7. Mint exactly sharesOut shares to receiver.
     * 8. Deploy excess to adapters.
     * 9. Emit Deposited event.
     *
     * @param sharesOut     Bootstrap: minimum shares (minSharesOut). Normal: exact shares to mint.
     * @param maxAmountsIn  Maximum per-asset amounts ordered by getAssets().
     * @param receiver      Address receiving the minted shares.
     * @return actualAmounts Actual amount of each asset pulled from msg.sender.
     */
    function depositMulti(
        uint256            sharesOut,
        uint256[] calldata maxAmountsIn,
        address            receiver
    )
        external
        override
        nonReentrant
        returns (uint256[] memory actualAmounts)
    {
        VaultStorage.Layout storage s = _layout();

        // 1. Pause check.
        if (s.paused) revert Errors.VaultPaused();

        // 2. Validate input length.
        uint256 n = s.assets.length;
        if (maxAmountsIn.length != n) revert Errors.ArraysLengthMismatch();

        // 3. Collect fees (updates totalShares; no-op on bootstrap).
        _collectFees();

        uint256 totalShares_ = s.totalShares;
        actualAmounts = new uint256[](n);

        if (totalShares_ == 0) {
            // ── Bootstrap path ────────────────────────────────────────────────
            // Validate non-zero amounts.
            for (uint256 i; i < n; ) {
                if (maxAmountsIn[i] == 0) revert Errors.ZeroAmount();
                actualAmounts[i] = maxAmountsIn[i];
                unchecked { i++; }
            }

            // Compute deposit value via oracle.
            uint256 depositAUM = _computeDepositValueUSD(s, maxAmountsIn);

            // Mint shares using virtual offset formula (inflation defence).
            uint256 shares = VaultMath.calcSharesToMint(depositAUM, 0, 0);
            if (shares < sharesOut) revert Errors.SlippageExceeded(sharesOut, shares);
            if (shares == 0) revert Errors.ZeroShares();

            // Transfer assets from sender.
            for (uint256 i; i < n; ) {
                IERC20(s.assets[i]).safeTransferFrom(msg.sender, address(this), actualAmounts[i]);
                unchecked { i++; }
            }

            // Mint shares to receiver.
            _mintShares(receiver, shares);

            // Deploy excess to adapters (respecting bufferRatio).
            _deployExcessToAdapters(s);

            // Update AUM snapshot and HWM to post-deposit values.
            // _collectFees() ran before tokens arrived; overwrite snapshot here so that
            // management fees in the NEXT period are computed on the correct (post-deposit) AUM,
            // and the HWM reflects the real initial NAV, preventing spurious perf-fee charges.
            uint256 postAUM = VaultMath.computeTotalAUMUsd(s);
            s.lastAUMSnapshot = postAUM;
            uint256 postNAV = VaultMath.navPerShare(postAUM, s.totalShares);
            if (postNAV > s.highWaterMark) s.highWaterMark = postNAV;

            emit Deposited(receiver, s.assets, actualAmounts, shares);

        } else {
            // ── Normal path ───────────────────────────────────────────────────
            if (sharesOut == 0) revert Errors.ZeroShares();

            // Compute pro-rata actualAmounts from current balances.
            for (uint256 i; i < n; ) {
                address asset = s.assets[i];

                // Total balance = idle + adapter.
                uint256 totalBal = IERC20(asset).balanceOf(address(this));
                address adapter  = s.strategyAdapter[asset];
                if (adapter != address(0)) {
                    try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                        totalBal += ab;
                    } catch {}
                }

                // Pro-rata floor: sharesOut / totalShares * totalBal.
                uint256 amount = Math.mulDiv(sharesOut, totalBal, totalShares_);

                // Per-asset slippage guard: caller caps their contribution.
                if (amount > maxAmountsIn[i]) revert Errors.SlippageExceeded(maxAmountsIn[i], amount);

                actualAmounts[i] = amount;
                unchecked { i++; }
            }

            // Transfer exact actualAmounts from sender.
            for (uint256 i; i < n; ) {
                IERC20(s.assets[i]).safeTransferFrom(msg.sender, address(this), actualAmounts[i]);
                unchecked { i++; }
            }

            // Mint exactly sharesOut shares.
            _mintShares(receiver, sharesOut);

            // Deploy excess to adapters.
            _deployExcessToAdapters(s);

            emit Deposited(receiver, s.assets, actualAmounts, sharesOut);
        }
    }

    // =========================================================================
    // Multi-Asset Withdrawal (In-Kind)
    // =========================================================================

    /**
     * @notice Burns shares and withdraws a pro-rata basket of assets.
     * @dev
     * Flow:
     * 1. Validate shares > 0 and owner balance.
     * 2. Handle allowance if caller != owner.
     * 3. Collect fees.
     * 4. Circuit breaker check (USD value).
     * 5. For each portfolio asset (strict in-kind):
     *    a. Compute pro-rata amount (floor).
     *    b. Check minAmountOut.
     *    c. Pull from idle first; if sufficient, transfer and optionally restore buffer.
     *    d. If idle < amount, withdraw shortfall + targetIdle from adapter in one call.
     * 6. Burn shares.
     * 7. Emit Withdrawn event.
     *
     * @param params See {DataTypes.MultiAssetWithdrawParams}.
     * @return amounts Actual amounts transferred per asset.
     */
    function withdrawMulti(DataTypes.MultiAssetWithdrawParams calldata params)
        external
        override
        nonReentrant
        returns (uint256[] memory amounts)
    {
        VaultStorage.Layout storage s = _layout();

        // 1. Validate shares.
        if (params.shares == 0) revert Errors.ZeroShares();
        if (s.balances[params.owner] < params.shares) {
            revert Errors.InsufficientShares(params.shares, s.balances[params.owner]);
        }

        // 2. Handle allowance.
        if (msg.sender != params.owner) {
            uint256 currentAllowance = s.allowances[params.owner][msg.sender];
            if (currentAllowance != type(uint256).max) {
                if (currentAllowance < params.shares) {
                    revert Errors.InsufficientShares(params.shares, currentAllowance);
                }
                unchecked {
                    _approve(params.owner, msg.sender, currentAllowance - params.shares);
                }
            }
        }

        // 3. Collect fees.
        _collectFees();

        uint256 totalShares_ = s.totalShares;

        // 4. Circuit breaker check.
        if (s.circuitBreaker != address(0)) {
            uint256 withdrawUSD = _computeWithdrawalValueUSD(s, params.shares, totalShares_);
            ICircuitBreaker(s.circuitBreaker).checkAndRecordOutflow(withdrawUSD);
        }

        // Enforce strict in-kind: minAmountsOut must cover all portfolio assets.
        uint256 numAssets = s.assets.length;
        if (params.minAmountsOut.length != numAssets) revert Errors.ArraysLengthMismatch();

        // 5. Withdraw all portfolio assets pro-rata.
        amounts = new uint256[](numAssets);
        for (uint256 i; i < numAssets; ) {
            address asset   = s.assets[i];
            address adapter = s.strategyAdapter[asset];

            // Compute total balance (idle + adapter).
            uint256 totalBal = IERC20(asset).balanceOf(address(this));
            if (adapter != address(0)) {
                try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                    totalBal += ab;
                } catch {}
            }

            // Pro-rata amount (floor).
            uint256 amount = VaultMath.calcAssetToReturn(params.shares, totalShares_, totalBal);
            if (amount < params.minAmountsOut[i]) {
                revert Errors.SlippageExceeded(params.minAmountsOut[i], amount);
            }
            amounts[i] = amount;

            // Pull from idle first.
            uint256 idle = IERC20(asset).balanceOf(address(this));
            if (idle >= amount) {
                // Idle is sufficient. Transfer to receiver.
                IERC20(asset).safeTransfer(params.receiver, amount);

                // Buffer restoration: if leftover idle exceeds target, deploy excess back to adapter.
                if (adapter != address(0)) {
                    uint256 newIdle   = idle - amount;
                    uint256 remaining = totalBal - amount;
                    uint256 target    = Math.mulDiv(remaining, s.bufferRatioBps, Constants.BPS);
                    if (newIdle > target) {
                        uint256 toDeploy = newIdle - target;
                        IERC20(asset).safeIncreaseAllowance(adapter, toDeploy);
                        IAssetAdapter(adapter).deposit(asset, toDeploy);
                    }
                }
            } else {
                // Idle insufficient; must withdraw from adapter.
                if (adapter == address(0)) {
                    revert Errors.InsufficientLiquidity(asset, amount, idle);
                }

                uint256 shortfall = amount - idle;

                // Withdraw shortfall + target idle buffer in one Aave call (avoids future DoS).
                uint256 totalRemaining = totalBal - amount;
                uint256 targetIdle     = Math.mulDiv(totalRemaining, s.bufferRatioBps, Constants.BPS);
                uint256 toWithdraw     = shortfall + targetIdle;

                // Cap at adapter balance (cannot withdraw more than available).
                uint256 adapterBal;
                try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                    adapterBal = ab;
                } catch {}
                if (adapterBal < shortfall) revert Errors.AaveWithdrawalFailed(asset, shortfall);
                if (toWithdraw > adapterBal) toWithdraw = adapterBal;

                // Withdraw to vault, then transfer amount to receiver.
                try IAssetAdapter(adapter).withdraw(asset, toWithdraw, address(this)) returns (uint256) {
                    IERC20(asset).safeTransfer(params.receiver, amount);
                } catch {
                    revert Errors.AaveWithdrawalFailed(asset, shortfall);
                }
            }

            unchecked { i++; }
        }

        // 6. Burn shares.
        _burnShares(params.owner, params.shares);

        // 7. Emit event.
        emit Withdrawn(params.owner, params.receiver, s.assets, amounts, params.shares);
    }

    // =========================================================================
    // Rebalancing
    // =========================================================================

    /**
     * @notice Executes a portfolio rebalance via explicit swap instructions.
     * @dev
     * Flow:
     * 1. Pause check.
     * 2. Cooldown check.
     * 3. Validate newWeights (length, sum, deviation OR weights changed).
     * 4. Collect fees.
     * 5. Capture pre-rebalance AUM for keeper reward.
     * 6. Execute swaps; accumulate swapped USD volume.
     * 7. Update weights + lastRebalanceTime.
     * 8. Mint keeper reward: 0.1% of swapped USD volume expressed as shares.
     * 9. Emit Rebalanced event.
     *
     * @param newWeights New target weights (must sum to BPS).
     * @param swaps      Swap instructions provided by the keeper.
     */
    function rebalance(uint256[] calldata newWeights, RebalanceSwap[] calldata swaps) external override nonReentrant {
        VaultStorage.Layout storage s = _layout();

        // 1. Pause check.
        if (s.paused) revert Errors.VaultPaused();

        // 2. Cooldown check.
        if (block.timestamp < s.lastRebalanceTime + s.rebalanceCooldown) {
            revert Errors.CooldownNotElapsed(
                s.lastRebalanceTime + s.rebalanceCooldown - block.timestamp
            );
        }

        // 3. Validate newWeights.
        if (newWeights.length != s.assets.length) revert Errors.WeightsMismatch();
        uint256 weightSum;
        for (uint256 i; i < newWeights.length; ) {
            weightSum += newWeights[i];
            unchecked { i++; }
        }
        if (weightSum != Constants.BPS) revert Errors.WeightsNotNormalized();

        // Check deviation OR weights changed.
        bool balanced      = VaultMath.isPortfolioBalanced(s, s.maxDriftBps);
        bool weightsChanged = _weightsChanged(s.weights, newWeights);
        if (balanced && !weightsChanged) revert Errors.DeviationBelowThreshold();

        // 4. Collect fees.
        _collectFees();

        // 5. Capture pre-rebalance AUM (used for keeper reward denominator).
        uint256 preAUM = VaultMath.computeTotalAUMUsd(s);

        // 6. Execute swaps; get total swapped USD volume.
        uint256 swappedVolumeUsd = _executeSwaps(s, swaps);

        // 7. Update state.
        s.weights          = newWeights;
        s.lastRebalanceTime = block.timestamp;

        // 8. Mint keeper reward: 0.1% of swapped USD volume, expressed as shares.
        uint256 keeperReward = _calcKeeperReward(swappedVolumeUsd, preAUM, s.totalShares);
        if (keeperReward > 0) {
            _mintShares(msg.sender, keeperReward);
        }

        // 9. Emit event.
        emit Rebalanced(msg.sender, newWeights);
    }

    // =========================================================================
    // Management Functions
    // =========================================================================

    function setManager(address newManager) external override {
        VaultStorage.Layout storage s = _layout();
        if (msg.sender != s.manager) revert Errors.NotManager();
        address oldManager = s.manager;
        s.manager = newManager;
        emit ManagerUpdated(oldManager, newManager);
    }

    function setWeights(uint256[] calldata newWeights) external override {
        VaultStorage.Layout storage s = _layout();
        if (msg.sender != s.manager) revert Errors.NotManager();
        if (!s.isMutable) revert Errors.VaultImmutable();
        if (newWeights.length != s.assets.length) revert Errors.WeightsMismatch();

        uint256 sum;
        for (uint256 i; i < newWeights.length; ) {
            sum += newWeights[i];
            unchecked { i++; }
        }
        if (sum != Constants.BPS) revert Errors.WeightsNotNormalized();

        uint256[] memory oldWeights = s.weights;
        s.weights = newWeights;
        emit WeightsUpdated(oldWeights, newWeights);
    }

    function setStrategy(address asset, address newAdapter) external override {
        VaultStorage.Layout storage s = _layout();
        if (msg.sender != s.manager) revert Errors.NotManager();
        if (s.assetIndex[asset] == 0) revert Errors.AssetNotInPortfolio(asset);

        address oldAdapter = s.strategyAdapter[asset];
        s.strategyAdapter[asset] = newAdapter;
        emit StrategyUpdated(asset, oldAdapter, newAdapter);
    }

    /**
     * @notice Pauses the vault (Guardian only).
     * @dev Deposits and rebalancing are blocked; withdrawals remain enabled.
     */
    function pause() external {
        VaultStorage.Layout storage s = _layout();
        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        address guardian = provider.getGuardian();
        if (msg.sender != guardian && msg.sender != s.manager) revert Errors.NotGuardian();
        s.paused = true;
    }

    /**
     * @notice Unpauses the vault (Guardian only).
     */
    function unpause() external {
        VaultStorage.Layout storage s = _layout();
        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        address guardian = provider.getGuardian();
        if (msg.sender != guardian && msg.sender != s.manager) revert Errors.NotGuardian();
        s.paused = false;
    }

    /**
     * @notice Sets the Uniswap V3 swap router address (Manager only).
     */
    function setSwapRouter(address router) external {
        VaultStorage.Layout storage s = _layout();
        if (msg.sender != s.manager) revert Errors.NotManager();
        s.swapRouter = router;
    }

    /**
     * @notice Sets the circuit breaker address (Manager only).
     */
    function setCircuitBreaker(address breaker) external {
        VaultStorage.Layout storage s = _layout();
        if (msg.sender != s.manager) revert Errors.NotManager();
        s.circuitBreaker = breaker;
    }

    // =========================================================================
    // Internal Helpers — ERC-20
    // =========================================================================

    function _transfer(address from, address to, uint256 amount) private {
        VaultStorage.Layout storage s = _layout();
        if (from == address(0) || to == address(0)) revert Errors.ZeroAddress(bytes32(0));
        uint256 fromBalance = s.balances[from];
        if (fromBalance < amount) revert Errors.InsufficientShares(amount, fromBalance);
        unchecked {
            s.balances[from] = fromBalance - amount;
            s.balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        VaultStorage.Layout storage s = _layout();
        if (owner == address(0) || spender == address(0)) revert Errors.ZeroAddress(bytes32(0));
        s.allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _mintShares(address to, uint256 amount) private {
        VaultStorage.Layout storage s = _layout();
        if (to == address(0)) revert Errors.ZeroAddress(bytes32(0));
        s.totalShares += amount;
        s.balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burnShares(address from, uint256 amount) private {
        VaultStorage.Layout storage s = _layout();
        if (from == address(0)) revert Errors.ZeroAddress(bytes32(0));
        uint256 fromBalance = s.balances[from];
        if (fromBalance < amount) revert Errors.InsufficientShares(amount, fromBalance);
        unchecked {
            s.balances[from] = fromBalance - amount;
            s.totalShares -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // =========================================================================
    // Internal Helpers — Fee Collection
    // =========================================================================

    /**
     * @notice Collects accrued management and performance fees.
     * @dev
     * - Management fee: time-based, annualized, charged on lastAUMSnapshot.
     * - Performance fee: charged on NAV gains above highWaterMark.
     * - Both fees are minted as new shares to the feeRecipient.
     * - Updates lastAUMSnapshot, lastFeeCollectionTime, and highWaterMark.
     */
    function _collectFees() private {
        VaultStorage.Layout storage s = _layout();

        uint256 currentAUM  = VaultMath.computeTotalAUMUsd(s);
        uint256 totalShares_ = s.totalShares;

        // Management fee.
        uint256 mgmtFeeAUM;
        if (s.lastFeeCollectionTime > 0) {
            uint256 dt = block.timestamp - s.lastFeeCollectionTime;
            mgmtFeeAUM = VaultMath.calcManagementFeeAUM(s.lastAUMSnapshot, dt, s.managementFeeBps);
        }

        // Performance fee.
        uint256 currentNAV = VaultMath.navPerShare(currentAUM, totalShares_);
        uint256 perfFeeAUM = VaultMath.calcPerformanceFeeAUM(
            s.highWaterMark,
            currentNAV,
            totalShares_,
            s.performanceFeeBps
        );

        uint256 totalFeeAUM = mgmtFeeAUM + perfFeeAUM;
        if (totalFeeAUM > 0) {
            uint256 feeShares = VaultMath.calcSharesToMint(totalFeeAUM, currentAUM - totalFeeAUM, totalShares_);
            if (feeShares > 0) {
                _mintShares(s.feeRecipient, feeShares);
            }
        }

        // Update state.
        s.lastAUMSnapshot       = currentAUM;
        s.lastFeeCollectionTime = block.timestamp;
        if (currentNAV > s.highWaterMark) {
            s.highWaterMark = currentNAV;
        }
    }

    // =========================================================================
    // Internal Helpers — Deposit/Withdrawal
    // =========================================================================

    /**
     * @notice Computes the USD value of a deposit using the oracle.
     */
    function _computeDepositValueUSD(
        VaultStorage.Layout storage s,
        uint256[] calldata amounts
    ) private view returns (uint256 totalUSD) {
        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        IPriceOracle oracle = IPriceOracle(provider.getPriceOracle());

        for (uint256 i; i < s.assets.length; ) {
            address asset    = s.assets[i];
            uint256 priceUsd = oracle.getPrice(asset);
            uint8   dec      = IERC20Metadata(asset).decimals();
            totalUSD += Math.mulDiv(amounts[i], priceUsd, 10 ** uint256(dec));
            unchecked { i++; }
        }
    }

    /**
     * @notice Computes the USD value of a withdrawal for circuit breaker check.
     */
    function _computeWithdrawalValueUSD(
        VaultStorage.Layout storage s,
        uint256 shares,
        uint256 totalShares_
    ) private view returns (uint256 totalUSD) {
        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        IPriceOracle oracle = IPriceOracle(provider.getPriceOracle());

        for (uint256 i; i < s.assets.length; ) {
            address asset    = s.assets[i];
            uint256 totalBal = IERC20(asset).balanceOf(address(this));
            address adapter  = s.strategyAdapter[asset];
            if (adapter != address(0)) {
                try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                    totalBal += ab;
                } catch {}
            }

            uint256 amount   = VaultMath.calcAssetToReturn(shares, totalShares_, totalBal);
            uint256 priceUsd = oracle.getPrice(asset);
            uint8   dec      = IERC20Metadata(asset).decimals();
            totalUSD += Math.mulDiv(amount, priceUsd, 10 ** uint256(dec));

            unchecked { i++; }
        }
    }

    /**
     * @notice Deploys excess idle balance to yield adapters (respecting bufferRatio).
     * @dev Iterates all portfolio assets and deploys any idle above target buffer.
     */
    function _deployExcessToAdapters(VaultStorage.Layout storage s) private {
        for (uint256 i; i < s.assets.length; ) {
            address asset   = s.assets[i];
            address adapter = s.strategyAdapter[asset];
            if (adapter == address(0)) { unchecked { i++; } continue; }

            uint256 idle;
            uint256 adapterBal;
            idle = IERC20(asset).balanceOf(address(this));
            try IAssetAdapter(adapter).getBalance(asset, address(this)) returns (uint256 ab) {
                adapterBal = ab;
            } catch {}

            uint256 totalBal  = idle + adapterBal;
            uint256 targetIdle = Math.mulDiv(totalBal, s.bufferRatioBps, Constants.BPS);

            if (idle > targetIdle) {
                uint256 toDeploy = idle - targetIdle;
                IERC20(asset).safeIncreaseAllowance(adapter, toDeploy);
                IAssetAdapter(adapter).deposit(asset, toDeploy);
            }

            unchecked { i++; }
        }
    }

    // =========================================================================
    // Internal Helpers — Rebalancing
    // =========================================================================

    /**
     * @notice Executes all swaps with dual slippage protection.
     * @return swappedVolumeUsd Total USD value of assets swapped (for keeper reward).
     */
    function _executeSwaps(VaultStorage.Layout storage s, RebalanceSwap[] calldata swaps)
        private
        returns (uint256 swappedVolumeUsd)
    {
        if (s.swapRouter == address(0)) revert Errors.SwapRouterNotSet();
        IUniswapV3SwapRouter router = IUniswapV3SwapRouter(s.swapRouter);
        IProtocolAddressProvider provider = IProtocolAddressProvider(s.addressProvider);
        IPriceOracle oracle = IPriceOracle(provider.getPriceOracle());

        for (uint256 i; i < swaps.length; ) {
            RebalanceSwap calldata swap = swaps[i];

            // Validate tokens are in portfolio.
            if (s.assetIndex[swap.tokenIn] == 0)  revert Errors.AssetNotInPortfolio(swap.tokenIn);
            if (s.assetIndex[swap.tokenOut] == 0) revert Errors.AssetNotInPortfolio(swap.tokenOut);

            // Compute Chainlink-based minimum output.
            uint256 chainlinkMinOut  = _computeChainlinkMinOut(oracle, swap);
            uint256 enforcedMinOut   = chainlinkMinOut > swap.minAmountOut ? chainlinkMinOut : swap.minAmountOut;

            // Withdraw tokenIn from adapter if idle is insufficient.
            uint256 idle = IERC20(swap.tokenIn).balanceOf(address(this));
            if (idle < swap.amountIn) {
                address adapter = s.strategyAdapter[swap.tokenIn];
                if (adapter != address(0)) {
                    uint256 shortfall = swap.amountIn - idle;
                    IAssetAdapter(adapter).withdraw(swap.tokenIn, shortfall, address(this));
                }
            }

            // Execute swap.
            IERC20(swap.tokenIn).safeIncreaseAllowance(address(router), swap.amountIn);
            uint256 amountOut;
            try router.exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn:          swap.tokenIn,
                    tokenOut:         swap.tokenOut,
                    fee:              swap.fee,
                    recipient:        address(this),
                    deadline:         block.timestamp,
                    amountIn:         swap.amountIn,
                    amountOutMinimum: enforcedMinOut,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 out) {
                amountOut = out;
            } catch {
                revert Errors.SwapFailed(swap.tokenIn, swap.tokenOut);
            }

            // Accumulate swapped USD volume for keeper reward.
            {
                uint8   decIn    = IERC20Metadata(swap.tokenIn).decimals();
                uint256 priceIn  = oracle.getPrice(swap.tokenIn);
                swappedVolumeUsd += Math.mulDiv(swap.amountIn, priceIn, 10 ** uint256(decIn));
            }

            // Deploy tokenOut to adapter (respecting bufferRatio).
            address adapterOut = s.strategyAdapter[swap.tokenOut];
            if (adapterOut != address(0)) {
                uint256 idleOut;
                uint256 adapterBalOut;
                idleOut = IERC20(swap.tokenOut).balanceOf(address(this));
                try IAssetAdapter(adapterOut).getBalance(swap.tokenOut, address(this)) returns (uint256 ab) {
                    adapterBalOut = ab;
                } catch {}

                uint256 totalBalOut  = idleOut + adapterBalOut;
                uint256 targetIdleOut = Math.mulDiv(totalBalOut, s.bufferRatioBps, Constants.BPS);

                if (idleOut > targetIdleOut) {
                    uint256 toDeployOut = idleOut - targetIdleOut;
                    IERC20(swap.tokenOut).safeIncreaseAllowance(adapterOut, toDeployOut);
                    IAssetAdapter(adapterOut).deposit(swap.tokenOut, toDeployOut);
                }
            }

            unchecked { i++; }
        }
    }

    /**
     * @notice Computes Chainlink-based minimum output with slippage tolerance.
     */
    function _computeChainlinkMinOut(IPriceOracle oracle, RebalanceSwap calldata swap)
        private
        view
        returns (uint256 minOut)
    {
        VaultStorage.Layout storage s = _layout();
        uint256 priceIn  = oracle.getPrice(swap.tokenIn);
        uint256 priceOut = oracle.getPrice(swap.tokenOut);
        uint8   decIn    = IERC20Metadata(swap.tokenIn).decimals();
        uint8   decOut   = IERC20Metadata(swap.tokenOut).decimals();

        // Theoretical output: amountIn * priceIn / priceOut, adjusted for decimals.
        uint256 theoreticalOut = Math.mulDiv(
            swap.amountIn * priceIn,
            10 ** uint256(decOut),
            priceOut * (10 ** uint256(decIn))
        );

        // Apply slippage tolerance.
        minOut = Math.mulDiv(theoreticalOut, Constants.BPS - s.maxSlippageBps, Constants.BPS);
    }

    /**
     * @notice Calculates keeper reward as shares proportional to swapped USD volume.
     *
     * @dev
     * Old formula: `totalShares * 0.1%` — catastrophically inflated rewards (0.1% of ALL shares).
     * New formula: `0.1% of swappedVolumeUsd`, converted to shares at current AUM/share price.
     * This means the keeper earns ~0.1% of the value they moved, a fair market-maker model.
     *
     * @param swappedVolumeUsd Total USD value of all swaps executed in the rebalance.
     * @param currentAUM       AUM (USD) at the start of the rebalance (before fees/swaps).
     * @param totalShares_     Current total share supply (after fee collection).
     */
    function _calcKeeperReward(
        uint256 swappedVolumeUsd,
        uint256 currentAUM,
        uint256 totalShares_
    ) private pure returns (uint256) {
        if (swappedVolumeUsd == 0 || currentAUM == 0) return 0;
        uint256 rewardUsd = Math.mulDiv(swappedVolumeUsd, Constants.KEEPER_BASE_REWARD_BPS, Constants.BPS);
        return Math.mulDiv(rewardUsd, totalShares_, currentAUM);
    }

    /**
     * @notice Returns true if any weight has changed.
     */
    function _weightsChanged(uint256[] memory oldWeights, uint256[] calldata newWeights)
        private
        pure
        returns (bool)
    {
        if (oldWeights.length != newWeights.length) return true;
        for (uint256 i; i < oldWeights.length; ) {
            if (oldWeights[i] != newWeights[i]) return true;
            unchecked { i++; }
        }
        return false;
    }
}
