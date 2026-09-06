// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DataTypes} from "../../libraries/DataTypes.sol";

/**
 * @title IDemeterVault
 * @notice Interface for the core Demeter multi-asset index vault.
 *
 * @dev
 * - Shares are standard ERC-20 tokens (this interface extends {IERC20Metadata}).
 * - Underlying exposure is a basket of assets with target weights, valued in USD.
 * - Core vault only supports in-kind (proportional) deposits and withdrawals.
 * - External routers may provide single-asset or zap-style UX on top.
 *
 * This interface intentionally does not inherit ERC-4626. Instead, it exposes
 * vault-specific multi-asset primitives while remaining ERC-20 compatible.
 * Upgradeability is expected to be handled via proxies (e.g. Beacon).
 */
interface IDemeterVault is IERC20Metadata {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when the target weights of the portfolio are updated.
     * @param oldWeights Previous target weights (basis points, e.g. 3000 = 30%).
     * @param newWeights New target weights.
     */
    event WeightsUpdated(uint256[] oldWeights, uint256[] newWeights);

    /**
     * @notice Emitted when the strategy adapter for a given asset is updated.
     * @param asset Underlying asset whose strategy is being updated.
     * @param oldAdapter Previous adapter address.
     * @param newAdapter New adapter address.
     */
    event StrategyUpdated(address indexed asset, address indexed oldAdapter, address indexed newAdapter);

    /**
     * @notice Emitted when the vault performs a rebalance.
     * @param caller Address that initiated the rebalance (typically keeper).
     * @param newWeights New target weights after rebalance.
     */
    event Rebalanced(address indexed caller, uint256[] newWeights);

    /**
     * @notice Emitted when a user deposits assets and receives shares.
     * @param receiver Address receiving the minted shares.
     * @param assets   Assets deposited (ordered by getAssets()).
     * @param amounts  Amounts deposited per asset.
     * @param shares   Shares minted to the receiver.
     */
    event Deposited(address indexed receiver, address[] assets, uint256[] amounts, uint256 shares);

    /**
     * @notice Emitted when a user withdraws assets by burning shares.
     * @param owner    Address whose shares are burned.
     * @param receiver Address receiving the withdrawn assets.
     * @param assets   Assets withdrawn.
     * @param amounts  Amounts withdrawn per asset.
     * @param shares   Shares burned from the owner.
     */
    event Withdrawn(
        address indexed owner,
        address indexed receiver,
        address[] assets,
        uint256[] amounts,
        uint256 shares
    );

    /**
     * @notice Emitted when the vault manager is updated.
     * @param oldManager Previous manager address.
     * @param newManager New manager address.
     */
    event ManagerUpdated(address indexed oldManager, address indexed newManager);

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /**
     * @notice Initialization parameters for a newly deployed DemeterVault.
     * @dev Intended to be passed via the Beacon proxy initialization.
     */
    struct InitializeParams {
        address baseAsset;        // Optional base asset used for accounting (e.g. USDC); can be address(0) for pure index.
        address manager;          // Address with portfolio management permissions (may be address(0) for immutable vaults).
        address[] assets;         // Underlying portfolio assets (e.g. WBTC, WETH).
        uint256[] weights;        // Target weights in basis points; must sum to 10_000.
        address addressProvider;  // Global address registry (oracle, whitelist, etc).
        string name;              // ERC-20 name for the share token.
        string symbol;            // ERC-20 symbol for the share token.
        bool isMutable;           // Whether assets/weights are allowed to change after initialization.
        address circuitBreaker;   // Optional ERC-7265 circuit breaker module (address(0) to disable).
    }

    /**
     * @notice Describes a single swap leg during rebalancing.
     * @dev Used by keepers to specify explicit swap routes through Uniswap V3.
     */
    struct RebalanceSwap {
        address tokenIn;       // Asset being sold.
        address tokenOut;      // Asset being bought.
        uint24  fee;           // Uniswap V3 pool fee tier (e.g. 500 = 0.05%, 3000 = 0.3%).
        uint256 amountIn;      // Exact input amount to swap.
        uint256 minAmountOut;  // Keeper-supplied minimum output (dual slippage guard with Chainlink).
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the current manager address.
     */
    function manager() external view returns (address);

    /**
     * @notice Returns whether the vault configuration (assets/weights) is mutable.
     */
    function isMutable() external view returns (bool);

    /**
     * @notice Returns the configured base asset used for accounting (if any).
     */
    function baseAsset() external view returns (address);

    /**
     * @notice Returns the global protocol address provider used by this vault.
     */
    function addressProvider() external view returns (address);

    /**
     * @notice Returns the list of underlying portfolio assets.
     * @dev The order of the assets array is aligned with the weights array.
     */
    function getAssets() external view returns (address[] memory);

    /**
     * @notice Returns the target weights of the portfolio in basis points.
     * @dev The sum of all weights SHOULD equal 10_000 (i.e. 100%).
     */
    function getWeights() external view returns (uint256[] memory);

    /**
     * @notice Returns the strategy adapter address for a given asset.
     * @param asset Underlying asset address.
     * @return adapter Address of the adapter responsible for deploying the asset into external protocols.
     */
    function getStrategy(address asset) external view returns (address adapter);

    /**
     * @notice Returns the cached total assets under management (AUM), denominated in the vault's base asset.
     * @dev Implementations may use this as a gas-optimized cache, not as a source of absolute truth.
     */
    function totalAUM() external view returns (uint256);

    /**
     * @notice Returns the current NAV per share, in the same units as {totalAUM}.
     * @dev Returns 0 if totalSupply is 0.
     */
    function navPerShare() external view returns (uint256);

    /**
     * @notice Returns the performance fee rate in basis points (1e4 = 100%).
     */
    function performanceFeeBps() external view returns (uint16);

    /**
     * @notice Returns the management fee rate in basis points (1e4 = 100% annualized).
     */
    function managementFeeBps() external view returns (uint16);

    /**
     * @notice Returns the address receiving protocol fees (e.g. treasury).
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Returns the total balance of `asset` held by the vault (idle + adapter).
     * @param asset Portfolio asset to query.
     * @return total Combined idle vault balance and adapter-deployed balance.
     */
    function getTotalBalance(address asset) external view returns (uint256 total);

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes a newly deployed DemeterVault behind a Beacon proxy.
     * @dev
     * - MUST be callable only once.
     * - SHOULD be protected against re-initialization (e.g. using OpenZeppelin Initializable).
     * - Implementations are expected to perform input validation (length checks, weight sum, etc).
     *
     * @param params Struct containing all initialization parameters.
     */
    function initialize(InitializeParams calldata params) external;

    // -------------------------------------------------------------------------
    // Management functions
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the vault manager.
     * @dev Typically callable only by an owner/governance entity.
     *
     * @param newManager New manager address.
     */
    function setManager(address newManager) external;

    /**
     * @notice Updates the target portfolio weights.
     * @dev
     * - Typically callable only by the manager or a governance timelock.
     * - Implementations SHOULD validate that `newWeights.length == assets.length`.
     * - Implementations SHOULD validate that the sum of weights is equal to 10_000.
     *
     * @param newWeights New target weights in basis points.
     */
    function setWeights(uint256[] calldata newWeights) external;

    /**
     * @notice Updates the strategy adapter for a specific asset.
     * @dev
     * - Strategy adapters are designed to be immutable contracts.
     * - Changing the strategy is equivalent to swapping the implementation address.
     *
     * @param asset Underlying asset whose strategy adapter is being updated.
     * @param newAdapter New adapter address.
     */
    function setStrategy(address asset, address newAdapter) external;

    /**
     * @notice Triggers a portfolio rebalance via explicit swap instructions.
     * @dev
     * - Implementations are expected to perform:
     *   - Cooldown check (minimum time since last rebalance).
     *   - Deviation check (portfolio must be out of balance OR weights are changing).
     *   - Withdraws from adapters for assets being sold.
     *   - Executes swaps via Uniswap V3 with dual slippage protection:
     *     * Chainlink-derived minimum output (oracle floor).
     *     * Keeper-supplied minimum output (keeper's own calculation).
     *   - Deploys purchased assets to adapters respecting bufferRatio.
     *   - Mints keeper reward shares.
     *
     * @param newWeights New target weights in basis points (must sum to 10_000).
     * @param swaps      Array of swap instructions to execute.
     */
    function rebalance(uint256[] calldata newWeights, RebalanceSwap[] calldata swaps) external;

    // -------------------------------------------------------------------------
    // In-kind multi-asset deposit / withdraw
    // -------------------------------------------------------------------------

    /**
     * @notice Deposits a proportional basket of assets and mints shares to the receiver.
     *
     * @dev
     * Two paths:
     *
     * Bootstrap (`totalSupply() == 0`):
     * - All `maxAmountsIn[i]` are pulled from `msg.sender`.
     * - Shares are computed via oracle pricing (VaultMath.calcSharesToMint).
     * - `sharesOut` acts as `minSharesOut` — reverts if oracle-computed shares < sharesOut.
     * - Returns `actualAmounts = maxAmountsIn`.
     *
     * Normal (`totalSupply() > 0`):
     * - Computes `actualAmounts[i] = sharesOut * totalBalance[i] / totalSupply()` for each asset.
     * - Reverts with `SlippageExceeded` if `actualAmounts[i] > maxAmountsIn[i]`.
     * - Pulls exactly `actualAmounts[i]` from `msg.sender`.
     * - Mints exactly `sharesOut` shares to `receiver`.
     *
     * @param sharesOut      Bootstrap: minimum shares acceptable (slippage guard).
     *                       Normal: exact number of shares to mint.
     * @param maxAmountsIn   Maximum amount per asset the caller is willing to supply.
     *                       Ordered identically to `getAssets()`. Length must equal asset count.
     * @param receiver       Address that will receive the minted vault shares.
     * @return actualAmounts Actual amount of each asset pulled from `msg.sender`.
     */
    function depositMulti(
        uint256            sharesOut,
        uint256[] calldata maxAmountsIn,
        address            receiver
    ) external returns (uint256[] memory actualAmounts);

    /**
     * @notice Burns vault shares and withdraws a basket of underlying assets.
     * @dev
     * - Core primitive for in-kind withdrawals.
     * - Exact asset composition is implementation-defined but SHOULD be proportional
     *   to current holdings when possible.
     *
     * @param params See {DataTypes.MultiAssetWithdrawParams}.
     * @return amounts Actual amounts of each asset transferred to the receiver.
     */
    function withdrawMulti(
        DataTypes.MultiAssetWithdrawParams calldata params
    ) external returns (uint256[] memory amounts);
}
