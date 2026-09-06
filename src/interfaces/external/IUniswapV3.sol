// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IUniswapV3SwapRouter
 * @notice Minimal subset of the Uniswap V3 swap router interface used by Demeter.
 *
 * @dev
 * Includes both single-hop (`exactInputSingle`) and multi-hop (`exactInput`) swap
 * primitives. The DemeterRouter uses `exactInput` with ABI-packed paths to support
 * arbitrary routing through multiple pools in a single call.
 */
interface IUniswapV3SwapRouter {
    /// @notice Parameters for exactInputSingle (single-hop).
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice Parameters for exactInput (multi-hop).
     * @param path            ABI-packed sequence of (tokenIn, fee, tokenOut) for each hop.
     *                        Single-hop: abi.encodePacked(tokenIn, fee, tokenOut).
     * @param recipient       Address that receives the output tokens.
     * @param deadline        Unix timestamp after which the transaction reverts.
     * @param amountIn        Exact amount of `path[0]` to sell.
     * @param amountOutMinimum Minimum acceptable amount of the last token in the path.
     */
    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /**
     * @notice Swaps `amountIn` of one token for as much as possible along a single pool.
     *
     * @param params Struct containing all swap parameters.
     * @return amountOut The amount of `tokenOut` received.
     */
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    /**
     * @notice Swaps `amountIn` of the first token along an arbitrary hop sequence.
     *
     * @param params Struct containing the encoded path and all swap parameters.
     * @return amountOut The amount of the final token in the path received.
     */
    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
