// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDemeterRouter
 * @notice Interface for the Demeter zap router.
 *
 * @dev
 * The router is a stateless helper contract that provides single-asset entry/exit
 * ("zap") on top of the core {DemeterVault} which only supports in-kind basket
 * deposits and withdrawals.
 *
 * Zap-in flow:
 *   inputToken → (Uniswap V3 exactInput swaps) → basket of portfolio assets → vault.depositMulti
 *
 * Zap-out flow:
 *   vault.withdrawMulti → basket of portfolio assets → (Uniswap V3 exactInput swaps) → outputToken
 *
 * ETH is transparently wrapped to WETH for zap-in and unwrapped from WETH for zap-out
 * when address(0) is used as the token address.
 *
 * Security invariants:
 * - The router is stateless. It never retains user funds between calls.
 * - Swap routes use ABI-packed Uniswap V3 paths, supporting multi-hop routing.
 * - All swap parameters (amountIn, minAmountOut) are caller-supplied; the router
 *   trusts the caller to compute correct values off-chain.
 * - Dust (leftover tokens after operations) is always refunded to the caller.
 * - ETH delivery uses `call{value}` to avoid the 2300-gas stipend DoS vector.
 */
interface IDemeterRouter {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /**
     * @notice Describes a single Uniswap V3 swap leg for zap-in.
     * @dev
     * One route per portfolio asset that must be purchased from the input token.
     * If the input token is already a portfolio asset, no route is needed for it —
     * the router deposits any remaining balance of the input token directly.
     *
     * `path` is an ABI-packed Uniswap V3 route: `abi.encodePacked(tokenIn, fee0, ..., tokenOut)`.
     * For a single-hop: `abi.encodePacked(inputToken, fee, tokenOut)`.
     */
    struct ZapInRoute {
        bytes   path;         // ABI-packed Uniswap V3 path (inputToken → ... → tokenOut).
        address tokenOut;     // Last token in path — the portfolio asset to acquire.
        uint256 amountIn;     // Amount of the first token in the path to allocate to this leg.
        uint256 minAmountOut; // Per-leg slippage floor (minimum acceptable tokenOut amount).
    }

    /**
     * @notice Describes a single Uniswap V3 swap leg for zap-out.
     * @dev
     * One route per portfolio asset that must be swapped to the output token.
     * Portfolio assets that already equal the output token do not need a route.
     *
     * `path` is an ABI-packed Uniswap V3 route: `abi.encodePacked(tokenIn, fee0, ..., tokenOut)`.
     * For a single-hop: `abi.encodePacked(portfolioAsset, fee, outputToken)`.
     */
    struct ZapOutRoute {
        bytes   path;         // ABI-packed path (portfolio asset → ... → outputToken).
        address tokenIn;      // First token in path — must be a portfolio asset.
        uint256 minAmountOut; // Per-leg slippage floor.
    }

    /**
     * @notice Parameters for a zap-in operation.
     */
    struct ZapInParams {
        address vault;          // Target DemeterVault proxy.
        address inputToken;     // Token to deposit; use address(0) for native ETH.
        uint256 inputAmount;    // Total amount of inputToken (or msg.value for ETH).
        ZapInRoute[] routes;    // Swap routes: one per non-inputToken portfolio asset.
        uint256 minSharesOut;   // Minimum vault shares to receive (total slippage guard).
        address receiver;       // Address that will receive the minted vault shares.
        uint256 deadline;       // Unix timestamp after which the transaction reverts.
    }

    /**
     * @notice Parameters for a zap-out operation.
     */
    struct ZapOutParams {
        address vault;           // Source DemeterVault proxy.
        uint256 shares;          // Amount of vault shares to redeem.
        address outputToken;     // Token to receive; use address(0) for native ETH.
        ZapOutRoute[] routes;    // Swap routes: one per non-outputToken portfolio asset.
        uint256 minOutputAmount; // Minimum total output amount (aggregate slippage guard).
        address receiver;        // Address that will receive the output token.
        uint256 deadline;        // Unix timestamp after which the transaction reverts.
    }

    /**
     * @notice EIP-2612 permit parameters for gasless token approvals.
     * @dev Used only for zap-in; the vault's custom ERC-20 does not support permit.
     */
    struct PermitParams {
        uint256 value;      // Amount approved via permit (must be >= inputAmount).
        uint256 deadline;   // Permit expiry timestamp.
        uint8   v;          // ECDSA signature component.
        bytes32 r;          // ECDSA signature component.
        bytes32 s;          // ECDSA signature component.
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted on a successful zap-in.
     * @param vault        Target vault.
     * @param sender       Caller who supplied the input token.
     * @param receiver     Address that received the vault shares.
     * @param inputToken   Token supplied (address(0) for ETH).
     * @param inputAmount  Amount of inputToken consumed.
     * @param shares       Vault shares minted to the receiver.
     */
    event ZappedIn(
        address indexed vault,
        address indexed sender,
        address indexed receiver,
        address inputToken,
        uint256 inputAmount,
        uint256 shares
    );

    /**
     * @notice Emitted on a successful zap-out.
     * @param vault         Source vault.
     * @param sender        Caller who owned the vault shares.
     * @param receiver      Address that received the output token.
     * @param outputToken   Token received (address(0) for ETH).
     * @param shares        Vault shares burned.
     * @param outputAmount  Total output token received by the receiver.
     */
    event ZappedOut(
        address indexed vault,
        address indexed sender,
        address indexed receiver,
        address outputToken,
        uint256 shares,
        uint256 outputAmount
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when block.timestamp exceeds the caller-supplied deadline.
    error DeadlineExpired(uint256 deadline, uint256 blockTimestamp);

    /// @dev Thrown when msg.value does not match the expected ETH amount.
    error InvalidETHAmount(uint256 expected, uint256 received);

    /// @dev Thrown when msg.value is non-zero for a non-ETH zap.
    error UnexpectedETH();

    /// @dev Thrown when the final output is below the caller's minimum threshold.
    error InsufficientOutput(uint256 minimum, uint256 actual);

    /// @dev Thrown when the WETH address is zero.
    error ZeroWETH();

    /// @dev Thrown when the swap router address is zero.
    error ZeroSwapRouter();

    /// @dev Thrown when a native ETH transfer (via call{value}) fails.
    error ETHTransferFailed();

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the WETH address used by this router for ETH wrapping.
    function weth() external view returns (address);

    /// @notice Returns the Uniswap V3 swap router used for all zap swaps.
    function swapRouter() external view returns (address);

    // -------------------------------------------------------------------------
    // Zap-in
    // -------------------------------------------------------------------------

    /**
     * @notice Zaps a single token into a DemeterVault, receiving vault shares.
     *
     * @dev
     * - For ERC-20 input: the caller must approve this router to spend `params.inputAmount`
     *   of `params.inputToken` before calling.
     * - For ETH input: set `params.inputToken = address(0)` and send `params.inputAmount`
     *   as `msg.value`.
     * - The router swaps portions of the input token into each portfolio asset per `params.routes`,
     *   then calls {IDemeterVault.depositMulti} with the resulting balances.
     * - Any input token remainder (dust from rounding or a partial allocation) is returned to
     *   `msg.sender`.
     *
     * @param params Zap-in parameters.
     * @return shares Amount of vault shares minted to `params.receiver`.
     */
    function zapIn(ZapInParams calldata params) external payable returns (uint256 shares);

    /**
     * @notice Zaps a single ERC-20 token into a DemeterVault using an EIP-2612 permit.
     *
     * @dev
     * Identical to {zapIn} except that it calls `IERC20Permit.permit()` on `params.inputToken`
     * before pulling the tokens, enabling gasless approvals.
     *
     * The permit call is wrapped in a try/catch: if the permit is frontrun (i.e. the allowance
     * was already set by a frontrunner), the catch is silent and `safeTransferFrom` still succeeds
     * on the pre-existing allowance. This prevents griefing via permit frontrunning.
     *
     * `params.inputToken` MUST implement ERC-2612 (e.g. USDC, DAI, WETH).
     * This function is not applicable for ETH input (use {zapIn} with address(0) instead).
     *
     * @param params  Zap-in parameters (`inputToken` must not be address(0)).
     * @param permit  EIP-2612 permit signature.
     * @return shares Amount of vault shares minted to `params.receiver`.
     */
    function zapInWithPermit(
        ZapInParams calldata params,
        PermitParams calldata permit
    ) external returns (uint256 shares);

    // -------------------------------------------------------------------------
    // Zap-out
    // -------------------------------------------------------------------------

    /**
     * @notice Redeems vault shares and receives a single output token.
     *
     * @dev
     * - The caller must approve this router to spend `params.shares` of vault shares
     *   before calling (the vault does not support EIP-2612 permit).
     * - The router calls {IDemeterVault.withdrawMulti} using the caller as owner.
     *   The vault burns the caller's shares and delivers the full asset basket to the router.
     * - The router swaps non-outputToken assets into `params.outputToken` per `params.routes`.
     * - Any portfolio asset without a matching route is swept directly to `params.receiver`.
     * - For ETH output: set `params.outputToken = address(0)`; the router unwraps WETH and
     *   delivers ETH via `call{value}` to avoid 2300-gas DoS.
     *
     * @param params Zap-out parameters.
     * @return outputAmount Total amount of output token delivered to `params.receiver`.
     */
    function zapOut(ZapOutParams calldata params) external returns (uint256 outputAmount);
}
