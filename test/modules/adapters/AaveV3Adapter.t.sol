// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AaveV3Adapter}         from "../../../src/modules/adapters/AaveV3Adapter.sol";
import {MockERC20}             from "../../mocks/MockERC20.sol";
import {MockAaveV3Pool, MockAToken, MockRewardsController}
                                from "../../mocks/MockAaveV3Pool.sol";

/**
 * @title AaveV3AdapterTest
 * @notice Unit tests for {AaveV3Adapter}.
 *
 * @dev
 * Test architecture:
 * - MockAaveV3Pool simulates the Aave V3 Pool (supply / withdraw / getReserveData).
 * - MockAToken is a simple ERC-20 representing the aToken issued for USDC.
 * - One adapter per test deployment; VAULT is the simulated vault caller (msg.sender
 *   for deposit / withdraw calls).
 *
 * Key invariants validated:
 * - deposit pulls underlying from vault, approves pool, calls pool.supply (onBehalfOf=adapter).
 * - After deposit, aTokens are held by the adapter (not the vault).
 * - withdraw calls pool.withdraw from the adapter; pool burns adapter's aTokens and
 *   sends underlying to the specified recipient.
 * - getBalance returns the adapter's current aToken balance (ignores `owner` param).
 * - claimRewards returns (address(0), 0) when no controller is set; otherwise delegates.
 *
 * Coverage matrix:
 *   Constructor         — immutables, zero-pool guard, zero-rewards accepted
 *   deposit             — pull, approve, supply, return amount, post-state
 *   withdraw            — burn aTokens, deliver underlying, return amount, failure path
 *   getBalance          — aToken balance of adapter, unknown asset returns 0
 *   claimRewards        — no-op without controller, delegates with controller
 *   Fuzz                — deposit-withdraw round-trip invariant
 */
contract AaveV3AdapterTest is Test {
    // =========================================================================
    // Actors
    // =========================================================================

    address internal constant VAULT     = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    // =========================================================================
    // Contracts
    // =========================================================================

    MockERC20              internal usdc;
    MockAToken             internal aUsdc;
    MockAaveV3Pool         internal pool;
    AaveV3Adapter          internal adapter;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6; // 1 000 USDC

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        // Deploy token mocks.
        usdc  = new MockERC20("USD Coin",   "USDC",  6);
        aUsdc = new MockAToken("Aave USDC", "aUSDC");

        // Deploy and configure the Aave pool mock.
        pool = new MockAaveV3Pool();
        pool.setAToken(address(usdc), address(aUsdc));

        // Deploy the adapter (no rewards controller).
        adapter = new AaveV3Adapter(address(pool), address(0));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Funds VAULT with `amount` of USDC and approves the adapter to spend it.
    function _fundAndApprove(uint256 amount) internal {
        usdc.mint(VAULT, amount);
        vm.prank(VAULT);
        usdc.approve(address(adapter), amount);
    }

    /// @dev Executes a full deposit as VAULT.
    function _deposit(uint256 amount) internal returns (uint256) {
        _fundAndApprove(amount);
        vm.prank(VAULT);
        return adapter.deposit(address(usdc), amount);
    }

    /// @dev Executes a full deposit and withdrawal as VAULT, returning withdrawn amount.
    function _depositWithdraw(uint256 amount, address recipient) internal returns (uint256) {
        _deposit(amount);
        // Fund pool with underlying so it can send it on withdrawal.
        usdc.mint(address(pool), amount);
        vm.prank(VAULT);
        return adapter.withdraw(address(usdc), amount, recipient);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_Constructor_StoresPool() public view {
        assertEq(address(adapter.pool()), address(pool));
    }

    function test_Constructor_StoresRewardsController() public view {
        assertEq(adapter.rewardsController(), address(0));
    }

    function test_Constructor_StoresNonZeroRewardsController() public {
        AaveV3Adapter adapterWithRC = new AaveV3Adapter(address(pool), address(0x1234));
        assertEq(adapterWithRC.rewardsController(), address(0x1234));
    }

    function test_Constructor_RevertsOnZeroPool() public {
        vm.expectRevert(AaveV3Adapter.ZeroPool.selector);
        new AaveV3Adapter(address(0), address(0));
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_Deposit_PullsUnderlyingFromCaller() public {
        _fundAndApprove(DEPOSIT_AMOUNT);

        uint256 vaultBefore = usdc.balanceOf(VAULT);

        vm.prank(VAULT);
        adapter.deposit(address(usdc), DEPOSIT_AMOUNT);

        assertEq(usdc.balanceOf(VAULT), vaultBefore - DEPOSIT_AMOUNT,
            "vault USDC must decrease by deposit amount");
    }

    function test_Deposit_MintsATokensToAdapter() public {
        _deposit(DEPOSIT_AMOUNT);

        assertEq(aUsdc.balanceOf(address(adapter)), DEPOSIT_AMOUNT,
            "adapter must hold the minted aTokens");
    }

    function test_Deposit_DoesNotMintATokensToVault() public {
        _deposit(DEPOSIT_AMOUNT);
        assertEq(aUsdc.balanceOf(VAULT), 0, "vault must NOT receive aTokens");
    }

    function test_Deposit_ReturnsDepositAmount() public {
        uint256 returned = _deposit(DEPOSIT_AMOUNT);
        assertEq(returned, DEPOSIT_AMOUNT, "deposit must return the supplied amount");
    }

    function test_Deposit_RevokesPoolAllowanceAfterSupply() public {
        // After deposit, the adapter's allowance to the pool for USDC should be 0
        // (forceApprove sets exactly amount; pool.supply calls transferFrom which
        // uses it up entirely).
        _deposit(DEPOSIT_AMOUNT);
        assertEq(
            usdc.allowance(address(adapter), address(pool)),
            0,
            "adapter must not leave residual pool allowance after deposit"
        );
    }

    function test_Deposit_UnderlyingLandsInPool() public {
        _deposit(DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(address(pool)), DEPOSIT_AMOUNT,
            "pool must hold the deposited underlying");
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_Withdraw_BurnsAdapterATokens() public {
        _deposit(DEPOSIT_AMOUNT);
        // Fund pool for the return transfer.
        usdc.mint(address(pool), DEPOSIT_AMOUNT);

        uint256 aTokensBefore = aUsdc.balanceOf(address(adapter));

        vm.prank(VAULT);
        adapter.withdraw(address(usdc), DEPOSIT_AMOUNT, RECIPIENT);

        assertEq(aUsdc.balanceOf(address(adapter)), aTokensBefore - DEPOSIT_AMOUNT,
            "adapter aToken balance must decrease by withdrawn amount");
    }

    function test_Withdraw_DeliversUnderlyingToRecipient() public {
        _deposit(DEPOSIT_AMOUNT);
        usdc.mint(address(pool), DEPOSIT_AMOUNT);

        uint256 recipientBefore = usdc.balanceOf(RECIPIENT);

        vm.prank(VAULT);
        adapter.withdraw(address(usdc), DEPOSIT_AMOUNT, RECIPIENT);

        assertEq(usdc.balanceOf(RECIPIENT), recipientBefore + DEPOSIT_AMOUNT,
            "recipient must receive the full withdrawn amount");
    }

    function test_Withdraw_ReturnsWithdrawnAmount() public {
        _deposit(DEPOSIT_AMOUNT);
        usdc.mint(address(pool), DEPOSIT_AMOUNT);

        vm.prank(VAULT);
        uint256 withdrawn = adapter.withdraw(address(usdc), DEPOSIT_AMOUNT, RECIPIENT);

        assertEq(withdrawn, DEPOSIT_AMOUNT, "withdraw must return the actual withdrawn amount");
    }

    function test_Withdraw_PartialWithdraw() public {
        _deposit(DEPOSIT_AMOUNT);
        usdc.mint(address(pool), DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;

        vm.prank(VAULT);
        uint256 withdrawn = adapter.withdraw(address(usdc), half, RECIPIENT);

        assertEq(withdrawn, half);
        assertEq(aUsdc.balanceOf(address(adapter)), DEPOSIT_AMOUNT - half,
            "adapter must retain remaining aTokens");
    }

    function test_Withdraw_RevertsWhenPoolReverts() public {
        _deposit(DEPOSIT_AMOUNT);
        pool.setWithdrawReverts(true);

        vm.prank(VAULT);
        vm.expectRevert();
        adapter.withdraw(address(usdc), DEPOSIT_AMOUNT, RECIPIENT);
    }

    // =========================================================================
    // getBalance
    // =========================================================================

    function test_GetBalance_ZeroBeforeDeposit() public view {
        // `owner` parameter is unused; pass vault address for realism.
        assertEq(adapter.getBalance(address(usdc), VAULT), 0);
    }

    function test_GetBalance_ReturnsAdapterATokenBalance() public {
        _deposit(DEPOSIT_AMOUNT);
        assertEq(adapter.getBalance(address(usdc), VAULT), DEPOSIT_AMOUNT,
            "getBalance must reflect the adapter's aToken holdings");
    }

    function test_GetBalance_OwnerParamIsIgnored() public {
        // getBalance should return the same value regardless of the `owner` argument.
        _deposit(DEPOSIT_AMOUNT);

        uint256 withVault    = adapter.getBalance(address(usdc), VAULT);
        uint256 withStranger = adapter.getBalance(address(usdc), address(0xDEAD));

        assertEq(withVault, withStranger,
            "owner parameter must not affect the result");
    }

    function test_GetBalance_ZeroForUnregisteredAsset() public {
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 18);
        // pool has no aToken for `unknown`, so _getAToken returns address(0).
        assertEq(adapter.getBalance(address(unknown), VAULT), 0);
    }

    function test_GetBalance_ReflectsWithdrawalDecrease() public {
        _deposit(DEPOSIT_AMOUNT);
        usdc.mint(address(pool), DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(VAULT);
        adapter.withdraw(address(usdc), half, RECIPIENT);

        assertEq(adapter.getBalance(address(usdc), VAULT), DEPOSIT_AMOUNT - half);
    }

    // =========================================================================
    // claimRewards
    // =========================================================================

    function test_ClaimRewards_ReturnsZeroWhenNoController() public {
        (address token, uint256 amount) = adapter.claimRewards(RECIPIENT);
        assertEq(token,  address(0), "no controller: rewardToken must be address(0)");
        assertEq(amount, 0,          "no controller: amount must be 0");
    }

    function test_ClaimRewards_CallsControllerAndReturnsReward() public {
        // Deploy a reward token + controller.
        MockERC20 rewardToken = new MockERC20("AAVE", "AAVE", 18);
        uint256   rewardAmt   = 50e18;
        MockRewardsController rc = new MockRewardsController(address(rewardToken), rewardAmt);

        // Mint rewards to the controller so it can transfer them.
        rewardToken.mint(address(rc), rewardAmt);

        // Deploy adapter wired to the controller.
        AaveV3Adapter adapterWithRC = new AaveV3Adapter(address(pool), address(rc));

        (address retToken, uint256 retAmt) = adapterWithRC.claimRewards(RECIPIENT);

        assertEq(retToken, address(rewardToken), "claimRewards must return the reward token");
        assertEq(retAmt,   rewardAmt,            "claimRewards must return the reward amount");
        assertEq(rewardToken.balanceOf(RECIPIENT), rewardAmt,
            "reward token must be delivered to recipient");
    }

    function test_ClaimRewards_ReturnsZeroWhenControllerReturnsEmpty() public {
        // A rewards controller that returns empty arrays.
        address emptyController = address(new _EmptyRewardsController());

        AaveV3Adapter adapterWithRC = new AaveV3Adapter(address(pool), emptyController);
        (address retToken, uint256 retAmt) = adapterWithRC.claimRewards(RECIPIENT);

        assertEq(retToken, address(0));
        assertEq(retAmt,   0);
    }

    // =========================================================================
    // Fuzz — deposit ↔ withdraw round-trip
    // =========================================================================

    /**
     * @dev For any amount in [1, 1e18], the round-trip must be exact:
     *      deposit(amount) → getBalance == amount → withdraw(amount) → recipient gets amount.
     */
    function testFuzz_DepositWithdrawRoundTrip(uint128 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);

        // Deposit.
        _fundAndApprove(amount);
        vm.prank(VAULT);
        uint256 returned = adapter.deposit(address(usdc), amount);
        assertEq(returned, amount, "Fuzz: deposit must return supplied amount");

        // Balance check.
        assertEq(adapter.getBalance(address(usdc), VAULT), amount,
            "Fuzz: getBalance must equal deposited amount");

        // Withdraw.
        usdc.mint(address(pool), amount); // fund pool for the return transfer
        vm.prank(VAULT);
        uint256 withdrawn = adapter.withdraw(address(usdc), amount, RECIPIENT);
        assertEq(withdrawn, amount, "Fuzz: withdraw must return full amount");

        // Recipient received underlying.
        assertEq(usdc.balanceOf(RECIPIENT), amount, "Fuzz: recipient must receive full amount");

        // Adapter holds no residual aTokens.
        assertEq(aUsdc.balanceOf(address(adapter)), 0, "Fuzz: adapter must hold 0 aTokens after full withdrawal");
    }

    /**
     * @dev Partial withdrawal must leave the correct aToken residual.
     */
    function testFuzz_PartialWithdrawResidual(uint128 rawDeposit, uint128 rawWithdraw) public {
        uint256 depositAmt  = bound(uint256(rawDeposit),  1, 1e24);
        uint256 withdrawAmt = bound(uint256(rawWithdraw), 1, depositAmt);

        _fundAndApprove(depositAmt);
        vm.prank(VAULT);
        adapter.deposit(address(usdc), depositAmt);

        usdc.mint(address(pool), withdrawAmt);
        vm.prank(VAULT);
        adapter.withdraw(address(usdc), withdrawAmt, RECIPIENT);

        assertEq(
            adapter.getBalance(address(usdc), VAULT),
            depositAmt - withdrawAmt,
            "Fuzz: residual aToken balance must equal deposit minus withdrawal"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: rewards controller that returns empty arrays
// ─────────────────────────────────────────────────────────────────────────────

contract _EmptyRewardsController {
    function claimAllRewards(address[] calldata, address)
        external
        pure
        returns (address[] memory, uint256[] memory)
    {
        return (new address[](0), new uint256[](0));
    }
}
