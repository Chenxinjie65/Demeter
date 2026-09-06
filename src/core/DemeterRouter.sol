// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDemeterRouter} from "../interfaces/core/IDemeterRouter.sol";
import {IDemeterVault} from "../interfaces/core/IDemeterVault.sol";
import {IUniswapV3SwapRouter} from "../interfaces/external/IUniswapV3.sol";
import {IWETH} from "../interfaces/external/IWETH.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @title DemeterRouter
 * @notice Stateless zap router for Demeter vaults.
 *
 * @dev
 * Architecture:
 * - This contract is entirely stateless. It does not hold user funds between
 *   transactions; all balances acquired during a call are fully disbursed before
 *   the call returns.
 * - It sits on top of {DemeterVault}'s strict in-kind primitives and provides
 *   a single-asset UX for retail users.
 *
 * Zap-in mechanics:
 * 1. User supplies `inputToken` (or native ETH, automatically wrapped to WETH).
 * 2. Router executes caller-specified Uniswap V3 multi-hop swap legs to convert portions
 *    of `inputToken` into each non-matching portfolio asset.
 * 3. Router computes `sharesOut` from current balances vs. vault state, then calls
 *    {depositMulti} with exact pro-rata amounts.
 * 4. Vault shares are forwarded to the caller-specified receiver.
 * 5. Any unused input token or portfolio asset remainder is refunded to the caller.
 *
 * Zap-out mechanics:
 * 1. Router redeems caller's vault shares via {withdrawMulti} (caller approves router).
 * 2. Received basket of portfolio assets is aggregated.
 * 3. Non-outputToken assets are swapped to `outputToken` per caller-specified routes.
 * 4. Portfolio assets without a matching route are swept directly to the receiver.
 * 5. Total `outputToken` is validated against `minOutputAmount` then forwarded.
 *
 * Security:
 * - {ReentrancyGuard} on all external entry points.
 * - Deadline enforcement on every call.
 * - ETH delivery uses `call{value}` to avoid the 2300-gas stipend DoS vector.
 * - Permit call is wrapped in try/catch to prevent griefing via frontrunning.
 * - No admin/owner — fully permissionless.
 *
 * Slippage model:
 * - Per-leg minimum (`ZapInRoute.minAmountOut`, `ZapOutRoute.minAmountOut`) enforced
 *   by the Uniswap router via `exactInput`.
 * - Aggregate minimum (`minSharesOut` for zap-in, `minOutputAmount` for zap-out)
 *   enforced by this contract.
 */
contract DemeterRouter is ReentrancyGuard, IDemeterRouter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @inheritdoc IDemeterRouter
    address public immutable override weth;

    /// @inheritdoc IDemeterRouter
    address public immutable override swapRouter;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Deploys the DemeterRouter.
     *
     * @param weth_       Canonical WETH address on the target network.
     *                    Ethereum mainnet: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
     * @param swapRouter_ Uniswap V3 SwapRouter address.
     *                    Ethereum mainnet: 0xE592427A0AEce92De3Edee1F18E0157C05861564
     */
    constructor(address weth_, address swapRouter_) {
        if (weth_ == address(0)) revert ZeroWETH();
        if (swapRouter_ == address(0)) revert ZeroSwapRouter();
        weth = weth_;
        swapRouter = swapRouter_;
    }

    // -------------------------------------------------------------------------
    // IDemeterRouter — Zap-in
    // -------------------------------------------------------------------------

    /// @inheritdoc IDemeterRouter
    function zapIn(ZapInParams calldata params)
        external
        payable
        override
        nonReentrant
        returns (uint256 shares)
    {
        shares = _zapIn(params, msg.sender);
    }

    /// @inheritdoc IDemeterRouter
    function zapInWithPermit(ZapInParams calldata params, PermitParams calldata permit)
        external
        override
        nonReentrant
        returns (uint256 shares)
    {
        // EIP-2612 permit on inputToken — enables gasless approval flow.
        // Wrapped in try/catch: if the permit was frontrun (allowance already set by a
        // frontrunner), the catch is silent and safeTransferFrom succeeds on the
        // pre-existing allowance, preventing permit frontrunning as a griefing vector.
        try IERC20Permit(params.inputToken).permit(
            msg.sender,
            address(this),
            permit.value,
            permit.deadline,
            permit.v,
            permit.r,
            permit.s
        ) {} catch {}

        shares = _zapIn(params, msg.sender);
    }

    // -------------------------------------------------------------------------
    // IDemeterRouter — Zap-out
    // -------------------------------------------------------------------------

    /// @inheritdoc IDemeterRouter
    function zapOut(ZapOutParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 outputAmount)
    {
        outputAmount = _zapOut(params, msg.sender);
    }

    // -------------------------------------------------------------------------
    // ETH receiver
    // -------------------------------------------------------------------------

    /**
     * @notice Accepts ETH exclusively from the WETH contract during unwrapping.
     * @dev Reverts if called by any address other than {weth} to prevent accidental
     *      ETH loss. Direct ETH transfers for zap-in are handled via `msg.value`
     *      in the payable {zapIn} function.
     */
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedETH();
    }

    // -------------------------------------------------------------------------
    // Internal — Zap-in
    // -------------------------------------------------------------------------

    /**
     * @dev Core zap-in logic. `sender` is the originating caller (msg.sender at the
     *      public entry point, preserved through internal calls).
     */
    function _zapIn(ZapInParams calldata params, address sender) internal returns (uint256 shares) {
        // 1. Deadline guard.
        if (block.timestamp > params.deadline) {
            revert DeadlineExpired(params.deadline, block.timestamp);
        }

        // 2. Acquire input token.
        address effectiveInput = _acquireInput(params.inputToken, params.inputAmount, sender);

        // 3. Execute swap routes: inputToken → each portfolio asset.
        uint256 numRoutes = params.routes.length;
        for (uint256 i; i < numRoutes; ) {
            ZapInRoute calldata r = params.routes[i];
            _swapExactInput(r.path, r.amountIn, r.minAmountOut, params.deadline);
            unchecked { i++; }
        }

        // 4. Compute sharesOut from current router balances vs. vault state.
        address[] memory vaultAssets = IDemeterVault(params.vault).getAssets();
        uint256 sharesOut = _computeSharesOut(params.vault, vaultAssets);

        // 5. Build maxAmountsIn and approve vault for each asset.
        uint256 n = vaultAssets.length;
        uint256[] memory maxAmountsIn = new uint256[](n);
        for (uint256 i; i < n; ) {
            maxAmountsIn[i] = IERC20(vaultAssets[i]).balanceOf(address(this));
            if (maxAmountsIn[i] > 0) {
                IERC20(vaultAssets[i]).forceApprove(params.vault, maxAmountsIn[i]);
            }
            unchecked { i++; }
        }

        // 6. Apply aggregate slippage guard for normal case (bootstrap checked after deposit).
        if (sharesOut > 0 && sharesOut < params.minSharesOut) {
            revert InsufficientOutput(params.minSharesOut, sharesOut);
        }

        // 7. Execute deposit. Record receiver balance before for bootstrap case.
        uint256 receiverBalBefore = IDemeterVault(params.vault).balanceOf(params.receiver);
        IDemeterVault(params.vault).depositMulti(sharesOut, maxAmountsIn, params.receiver);
        uint256 receiverBalAfter = IDemeterVault(params.vault).balanceOf(params.receiver);
        shares = receiverBalAfter - receiverBalBefore;

        // 8. Bootstrap case: check minSharesOut after oracle-computed shares are known.
        if (sharesOut == 0 && shares < params.minSharesOut) {
            revert InsufficientOutput(params.minSharesOut, shares);
        }

        // 9. Revoke any residual allowances (defence-in-depth).
        for (uint256 i; i < n; ) {
            uint256 residual = IERC20(vaultAssets[i]).allowance(address(this), params.vault);
            if (residual > 0) {
                IERC20(vaultAssets[i]).forceApprove(params.vault, 0);
            }
            unchecked { i++; }
        }

        // 10. Refund all dust (inputToken + any leftover portfolio assets) to sender.
        _refundDust(params.vault, effectiveInput, params.inputToken, sender);

        emit ZappedIn(params.vault, sender, params.receiver, params.inputToken, params.inputAmount, shares);
    }

    // -------------------------------------------------------------------------
    // Internal — Zap-out
    // -------------------------------------------------------------------------

    /**
     * @dev Core zap-out logic. `sender` is the originating caller.
     */
    function _zapOut(ZapOutParams calldata params, address sender) internal returns (uint256 outputAmount) {
        // 1. Deadline guard.
        if (block.timestamp > params.deadline) {
            revert DeadlineExpired(params.deadline, block.timestamp);
        }

        // 2. Determine effective output token (WETH when ETH is requested).
        address effectiveOutput = params.outputToken == address(0) ? weth : params.outputToken;

        // 3. Withdraw from vault into the router.
        //    The sender must have pre-approved the router to spend their vault shares.
        address[] memory vaultAssets = IDemeterVault(params.vault).getAssets();
        uint256 numAssets = vaultAssets.length;

        uint256[] memory minAmountsOut = new uint256[](numAssets);
        // Per-asset minimums are zero; aggregate is enforced via minOutputAmount.

        IDemeterVault(params.vault).withdrawMulti(
            DataTypes.MultiAssetWithdrawParams({
                owner:         sender,
                receiver:      address(this),   // assets land in the router
                shares:        params.shares,
                assets:        vaultAssets,
                minAmountsOut: minAmountsOut
            })
        );

        // 4. For each portfolio asset: swap to effectiveOutput, or sweep if no route exists.
        uint256 numRoutes = params.routes.length;

        for (uint256 i; i < numAssets; ) {
            address asset = vaultAssets[i];
            uint256 bal   = IERC20(asset).balanceOf(address(this));

            if (bal == 0) {
                unchecked { i++; }
                continue;
            }

            if (asset == effectiveOutput) {
                // Already the desired output — accumulate in place.
                unchecked { i++; }
                continue;
            }

            // Find a matching route.
            bool routed = false;
            for (uint256 j; j < numRoutes; ) {
                if (params.routes[j].tokenIn == asset) {
                    _swapExactInput(
                        params.routes[j].path,
                        bal,
                        params.routes[j].minAmountOut,
                        params.deadline
                    );
                    routed = true;
                    break;
                }
                unchecked { j++; }
            }

            if (!routed) {
                // No swap route supplied for this asset.
                // Sweep directly to the receiver rather than holding it hostage.
                IERC20(asset).safeTransfer(params.receiver, bal);
            }

            unchecked { i++; }
        }

        // 5. Aggregate total effectiveOutput held by router.
        outputAmount = IERC20(effectiveOutput).balanceOf(address(this));

        // 6. Enforce aggregate slippage guard.
        if (outputAmount < params.minOutputAmount) {
            revert InsufficientOutput(params.minOutputAmount, outputAmount);
        }

        // 7. Deliver output to receiver.
        if (params.outputToken == address(0)) {
            // Unwrap WETH → ETH and forward via call{value} (avoids 2300-gas DoS).
            IWETH(weth).withdraw(outputAmount);
            (bool ok,) = payable(params.receiver).call{value: outputAmount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(effectiveOutput).safeTransfer(params.receiver, outputAmount);
        }

        emit ZappedOut(
            params.vault, sender, params.receiver,
            params.outputToken, params.shares, outputAmount
        );
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Pulls the input token from `sender` into this contract, or wraps ETH.
     *      Returns the effective ERC-20 token address (WETH when ETH is supplied).
     */
    function _acquireInput(
        address inputToken,
        uint256 inputAmount,
        address sender
    ) internal returns (address effectiveToken) {
        if (inputToken == address(0)) {
            // ETH path: msg.value must exactly match the declared amount.
            if (msg.value != inputAmount) {
                revert InvalidETHAmount(inputAmount, msg.value);
            }
            IWETH(weth).deposit{value: inputAmount}();
            effectiveToken = weth;
        } else {
            // ERC-20 path: no ETH should accompany this call.
            if (msg.value != 0) revert UnexpectedETH();
            IERC20(inputToken).safeTransferFrom(sender, address(this), inputAmount);
            effectiveToken = inputToken;
        }
    }

    /**
     * @dev Computes the maximum shares the router can request from the vault given its
     *      current token balances. For bootstrap (totalShares == 0), returns 0 so that
     *      the vault uses oracle pricing.
     *
     * @param vault      Target DemeterVault address.
     * @param assets     Cached result of vault.getAssets() (avoid redundant external call).
     * @return sharesOut Maximum shares that can be minted proportionally, or 0 for bootstrap.
     */
    function _computeSharesOut(address vault, address[] memory assets)
        internal
        view
        returns (uint256 sharesOut)
    {
        uint256 totalShares = IDemeterVault(vault).totalSupply();
        if (totalShares == 0) return 0; // Bootstrap: vault uses oracle pricing.

        sharesOut = type(uint256).max;
        for (uint256 i; i < assets.length; ++i) {
            uint256 routerBal = IERC20(assets[i]).balanceOf(address(this));
            uint256 vaultBal  = IDemeterVault(vault).getTotalBalance(assets[i]);
            if (vaultBal == 0) continue;
            uint256 maxFromAsset = Math.mulDiv(routerBal, totalShares, vaultBal);
            if (maxFromAsset < sharesOut) sharesOut = maxFromAsset;
        }
        if (sharesOut == type(uint256).max) sharesOut = 0;
    }

    /**
     * @dev Executes a multi-hop exact-input swap via the Uniswap V3 router.
     *      Supports single-hop paths (`abi.encodePacked(tokenIn, fee, tokenOut)`) and
     *      multi-hop paths (`abi.encodePacked(tokenIn, fee0, mid, fee1, tokenOut)`).
     *
     * @param path         ABI-packed Uniswap V3 path.
     * @param amountIn     Exact amount of the first token in the path to sell.
     * @param minAmountOut Minimum acceptable amount of the last token (per-leg slippage guard).
     * @param deadline     Swap expiry timestamp.
     */
    function _swapExactInput(
        bytes memory path,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal {
        // Decode tokenIn from the first 20 bytes of the path.
        address tokenIn;
        assembly { tokenIn := shr(96, mload(add(path, 0x20))) }

        IERC20(tokenIn).forceApprove(swapRouter, amountIn);

        IUniswapV3SwapRouter(swapRouter).exactInput(
            IUniswapV3SwapRouter.ExactInputParams({
                path:             path,
                recipient:        address(this),
                deadline:         deadline,
                amountIn:         amountIn,
                amountOutMinimum: minAmountOut
            })
        );

        // Clear approval defensively — the router should have consumed exactly amountIn,
        // but we reset to prevent leftover allowances.
        IERC20(tokenIn).forceApprove(swapRouter, 0);
    }

    /**
     * @dev Refunds all dust held by this contract to `recipient`.
     *
     *      Dust can accumulate from:
     *      - Unused inputToken remainder (after routes consumed less than inputAmount).
     *      - Leftover portfolio assets after the vault's pro-rata depositMulti.
     *
     *      For ETH input (originalInput == address(0)), the effectiveInput (WETH) is
     *      unwrapped before sending. ETH delivery uses `call{value}` to avoid 2300-gas DoS.
     *
     * @param vault         Vault whose asset list to scan for leftover portfolio assets.
     * @param effectiveInput Effective ERC-20 token held (WETH if ETH was supplied).
     * @param originalInput  Original `params.inputToken` (address(0) = ETH).
     * @param recipient      Refund destination (the original msg.sender, not the receiver).
     */
    function _refundDust(
        address vault,
        address effectiveInput,
        address originalInput,
        address recipient
    ) internal {
        // Refund remaining effectiveInput balance.
        uint256 dust = IERC20(effectiveInput).balanceOf(address(this));
        if (dust > 0) {
            if (originalInput == address(0)) {
                // Unwrap WETH → ETH and send via call{value} (avoids 2300-gas DoS).
                IWETH(weth).withdraw(dust);
                (bool ok,) = payable(recipient).call{value: dust}("");
                if (!ok) revert ETHTransferFailed();
            } else {
                IERC20(effectiveInput).safeTransfer(recipient, dust);
            }
        }

        // Refund any remaining portfolio asset balances (dust from pro-rata deposit rounding).
        address[] memory assets = IDemeterVault(vault).getAssets();
        for (uint256 i; i < assets.length; ) {
            address asset = assets[i];
            if (asset != effectiveInput) {
                uint256 bal = IERC20(asset).balanceOf(address(this));
                if (bal > 0) {
                    IERC20(asset).safeTransfer(recipient, bal);
                }
            }
            unchecked { i++; }
        }
    }
}
