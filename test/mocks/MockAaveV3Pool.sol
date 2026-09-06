// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockAToken
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @dev Minimal rebasing aToken mock.  The pool mints to suppliers and burns
 *      from the caller of pool.withdraw.
 */
contract MockAToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @dev Called by MockAaveV3Pool.supply to credit aTokens.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Called by MockAaveV3Pool.withdraw to debit aTokens from msg.sender.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockRewardsController
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @dev Minimal mock for the Aave V3 RewardsController that returns a fixed
 *      (rewardToken, amount) pair and optionally transfers the reward token.
 */
contract MockRewardsController {
    address public rewardToken;
    uint256 public rewardAmount;

    constructor(address rewardToken_, uint256 rewardAmount_) {
        rewardToken  = rewardToken_;
        rewardAmount = rewardAmount_;
    }

    /**
     * @dev Mirrors the signature of `IRewardsController.claimAllRewards`.
     *      Transfers `rewardAmount` of `rewardToken` to `recipient` (if set).
     */
    function claimAllRewards(address[] calldata, address recipient)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
    {
        rewardsList     = new address[](1);
        claimedAmounts  = new uint256[](1);
        rewardsList[0]    = rewardToken;
        claimedAmounts[0] = rewardAmount;

        if (rewardToken != address(0) && rewardAmount > 0) {
            IERC20(rewardToken).transfer(recipient, rewardAmount);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockAaveV3Pool
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @dev Minimal Aave V3 Pool mock for AaveV3Adapter unit tests.
 *
 * Behaviour:
 * - supply:          pulls underlying from caller (adapter), mints aTokens to onBehalfOf.
 * - withdraw:        burns aTokens from caller (adapter), sends underlying to `to`.
 * - getReserveData:  returns a 9-word ABI-encoded tuple where word[8] = aToken address.
 *                    This matches the decoding logic in AaveV3Adapter._getAToken.
 *
 * The mock does NOT simulate interest accrual; balance ≡ deposited principal.
 */
contract MockAaveV3Pool {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @dev asset → aToken address.
    mapping(address => address) public aTokenFor;

    /// @dev Set to true to make withdraw revert (simulates 100% utilization).
    bool public withdrawReverts;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setAToken(address asset, address aToken) external {
        aTokenFor[asset] = aToken;
    }

    function setWithdrawReverts(bool flag) external {
        withdrawReverts = flag;
    }

    // -------------------------------------------------------------------------
    // Pool interface (minimal subset)
    // -------------------------------------------------------------------------

    /**
     * @dev Mirrors IAaveV3Pool.supply.
     *      Pulls `amount` of `asset` from msg.sender (the adapter), then mints
     *      the equivalent aToken amount to `onBehalfOf`.
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        // Pull underlying from adapter into the pool.
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        // Mint aTokens to the designated recipient (the adapter, in the fixed design).
        MockAToken(aTokenFor[asset]).mint(onBehalfOf, amount);
    }

    /**
     * @dev Mirrors IAaveV3Pool.withdraw.
     *      Burns `amount` aTokens from msg.sender (the adapter, which holds them).
     *      Sends `amount` of underlying to `to`.
     *      Returns `amount` (full-fill, no rounding in this mock).
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (withdrawReverts) revert("MockAaveV3Pool: 100% utilization");
        MockAToken(aTokenFor[asset]).burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    /**
     * @dev Returns a minimal ABI-encoded ReserveData tuple with 9 uint256-sized words.
     *      Word[8] (zero-indexed) contains the aToken address — matching the layout
     *      that AaveV3Adapter._getAToken decodes.
     *
     * Aave V3 ReserveData word layout (simplified, each field padded to 32 bytes):
     *   [0] configuration
     *   [1] liquidityIndex
     *   [2] currentLiquidityRate
     *   [3] variableBorrowIndex
     *   [4] currentVariableBorrowRate
     *   [5] currentStableBorrowRate
     *   [6] lastUpdateTimestamp
     *   [7] id
     *   [8] aTokenAddress   ← we set this
     */
    function getReserveData(address asset)
        external
        view
        returns (
            uint256, uint128, uint128, uint128, uint128, uint128, uint40, uint16, address
        )
    {
        return (0, 0, 0, 0, 0, 0, 0, 0, aTokenFor[asset]);
    }
}
