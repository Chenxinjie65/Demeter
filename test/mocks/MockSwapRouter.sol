// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapRouter} from "../../src/interfaces/external/IUniswapV3.sol";

/**
 * @title MockSwapRouter
 * @notice Minimal IUniswapV3SwapRouter mock for rebalance and zap testing.
 *
 * @dev
 * Behaviour:
 * - Pulls `amountIn` of tokenIn from the caller (caller must have approved).
 * - Returns a pre-configured fixed `amountOut` of tokenOut to the recipient.
 * - If `shouldRevert` is set, every swap call reverts.
 *
 * Supports both `exactInputSingle` (used by DemeterVault rebalance) and
 * `exactInput` (used by DemeterRouter zaps).
 *
 * For `exactInput`, tokenIn and tokenOut are decoded from the ABI-packed path:
 * - tokenIn: first 20 bytes of path.
 * - tokenOut: last 20 bytes of path.
 *
 * Test setup:
 * 1. Fund the MockSwapRouter with sufficient tokenOut before each test.
 * 2. Call `setAmountOut(tokenOut, amount)` to configure the expected output.
 *
 * The fixed-output model avoids floating-point decimal arithmetic in tests,
 * letting the test author set an exact and predictable output.
 */
contract MockSwapRouter is IUniswapV3SwapRouter {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice When true, every swap call reverts.
    bool public shouldRevert;

    /// @notice Fixed output amounts per tokenOut address.
    mapping(address => uint256) private _amountOuts;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    /// @notice Pre-configure how many tokens are returned for a given tokenOut.
    function setAmountOut(address tokenOut, uint256 amount) external {
        _amountOuts[tokenOut] = amount;
    }

    // -------------------------------------------------------------------------
    // IUniswapV3SwapRouter — exactInputSingle
    // -------------------------------------------------------------------------

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        if (shouldRevert) revert("MockSwapRouter: swap reverted");

        // Pull tokenIn from caller.
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Use pre-configured fixed output.
        amountOut = _amountOuts[params.tokenOut];
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: insufficient output amount");

        // Send tokenOut to recipient.
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }

    // -------------------------------------------------------------------------
    // IUniswapV3SwapRouter — exactInput (multi-hop)
    // -------------------------------------------------------------------------

    function exactInput(ExactInputParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        if (shouldRevert) revert("MockSwapRouter: swap reverted");

        // Decode tokenIn from the first 20 bytes of the path.
        address tokenIn;
        bytes memory path = params.path;
        assembly { tokenIn := shr(96, mload(add(path, 0x20))) }

        // Decode tokenOut from the last 20 bytes of the path.
        address tokenOut;
        uint256 pathLen = path.length;
        assembly { tokenOut := shr(96, mload(add(add(path, 0x20), sub(pathLen, 20)))) }

        // Pull tokenIn from caller.
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Use pre-configured fixed output.
        amountOut = _amountOuts[tokenOut];
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: insufficient output amount");

        // Send tokenOut to recipient.
        IERC20(tokenOut).transfer(params.recipient, amountOut);
    }
}
