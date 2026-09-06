// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CircuitBreaker} from "../../../src/modules/circuit-breaker/CircuitBreaker.sol";
import {ICircuitBreaker} from "../../../src/interfaces/modules/ICircuitBreaker.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

/**
 * @title CircuitBreakerTest
 * @notice Comprehensive unit and fuzz tests for {CircuitBreaker}.
 *
 * @dev
 * Test model:
 * - VAULT acts as the protected vault (sole authorised caller of checkAndRecordOutflow).
 * - OWNER is the DAO multisig that manages limits and emergency overrides.
 * - All time manipulation uses vm.warp to advance block.timestamp.
 *
 * USD precision: 8-decimal, consistent with Chainlink / VaultMath convention.
 *
 * Coverage matrix:
 *   Constructor          — storage, events, zero-address guards, zero-period guard
 *   checkAndRecordOutflow — onlyVault, accumulation, exact limit, over limit, event
 *   Window rolling       — expiry resets accumulator, boundary (t == windowStart+period)
 *   remainingOutflowCapacity — live window, expired window (view-only, no mutation)
 *   setLimit             — owner-only, updates state, zero-period guard, event
 *   setVault             — owner-only, updates vault, resets window, event
 *   resetWindow          — owner-only, clears accumulator, updates windowStart
 *   Ownable2Step         — two-step ownership transfer
 *   ETH guard            — receive() reverts
 *   Fuzz                 — cumulative outflow never exceeds limit within window
 */
contract CircuitBreakerTest is Test {
    // =========================================================================
    // Actors
    // =========================================================================

    address internal constant OWNER   = address(0x1111);
    address internal constant VAULT   = address(0x2222);
    address internal constant VAULT2  = address(0x3333);
    address internal constant STRANGER = address(0x4444);

    // =========================================================================
    // Default configuration
    // =========================================================================

    uint256 internal constant DEFAULT_PERIOD    = 24 hours;
    uint256 internal constant DEFAULT_LIMIT_USD = 1_000_000e8; // $1,000,000

    // =========================================================================
    // Contract under test
    // =========================================================================

    CircuitBreaker internal cb;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        cb = new CircuitBreaker(OWNER, VAULT, DEFAULT_PERIOD, DEFAULT_LIMIT_USD);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_Constructor_StoresParameters() public view {
        assertEq(cb.owner(),            OWNER);
        assertEq(cb.vault(),            VAULT);
        assertEq(cb.period(),           DEFAULT_PERIOD);
        assertEq(cb.limitUsd(),         DEFAULT_LIMIT_USD);
        assertEq(cb.cumulativeOutflow(), 0);
        assertEq(cb.windowStart(),      block.timestamp);
    }

    function test_Constructor_EmitsVaultUpdated() public {
        vm.expectEmit(true, true, false, false);
        emit CircuitBreaker.VaultUpdated(address(0), VAULT);
        new CircuitBreaker(OWNER, VAULT, DEFAULT_PERIOD, DEFAULT_LIMIT_USD);
    }

    function test_Constructor_EmitsLimitUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.LimitUpdated(DEFAULT_PERIOD, DEFAULT_LIMIT_USD);
        new CircuitBreaker(OWNER, VAULT, DEFAULT_PERIOD, DEFAULT_LIMIT_USD);
    }

    function test_Constructor_RevertsOnZeroVault() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, bytes32("vault")));
        new CircuitBreaker(OWNER, address(0), DEFAULT_PERIOD, DEFAULT_LIMIT_USD);
    }

    function test_Constructor_RevertsOnZeroPeriod() public {
        // Reuses Errors.InvalidWeight as the "invalid param" sentinel.
        vm.expectRevert(Errors.InvalidWeight.selector);
        new CircuitBreaker(OWNER, VAULT, 0, DEFAULT_LIMIT_USD);
    }

    function test_Constructor_AllowsZeroLimitUsd() public {
        // A zero limit means every withdrawal is blocked — valid configuration.
        CircuitBreaker zeroCb = new CircuitBreaker(OWNER, VAULT, DEFAULT_PERIOD, 0);
        assertEq(zeroCb.limitUsd(), 0);
    }

    // =========================================================================
    // checkAndRecordOutflow — access control
    // =========================================================================

    function test_CheckAndRecord_RevertsForNonVault() public {
        vm.prank(STRANGER);
        vm.expectRevert(Errors.NotManager.selector);
        cb.checkAndRecordOutflow(1e8);
    }

    function test_CheckAndRecord_RevertsForOwner() public {
        // Owner is not the vault; must not bypass onlyVault.
        vm.prank(OWNER);
        vm.expectRevert(Errors.NotManager.selector);
        cb.checkAndRecordOutflow(1e8);
    }

    // =========================================================================
    // checkAndRecordOutflow — accumulation
    // =========================================================================

    function test_CheckAndRecord_AccumulatesOutflow() public {
        vm.startPrank(VAULT);
        cb.checkAndRecordOutflow(100e8);
        assertEq(cb.cumulativeOutflow(), 100e8);

        cb.checkAndRecordOutflow(250e8);
        assertEq(cb.cumulativeOutflow(), 350e8);
        vm.stopPrank();
    }

    function test_CheckAndRecord_EmitsOutflowRecorded() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.OutflowRecorded(500e8, 500e8);

        vm.prank(VAULT);
        cb.checkAndRecordOutflow(500e8);
    }

    function test_CheckAndRecord_EmitsCumulativeCorrectly() public {
        vm.startPrank(VAULT);
        cb.checkAndRecordOutflow(300e8);

        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.OutflowRecorded(200e8, 500e8); // cumulative = 300+200
        cb.checkAndRecordOutflow(200e8);
        vm.stopPrank();
    }

    function test_CheckAndRecord_PassesAtExactLimit() public {
        // usdValue == limitUsd should succeed (not exceed).
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD);
        assertEq(cb.cumulativeOutflow(), DEFAULT_LIMIT_USD);
    }

    function test_CheckAndRecord_RevertsOneWeiOverLimit() public {
        vm.startPrank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD - 1); // fill to limit - 1

        // Next 2 wei would push over limit; only 1 wei remaining.
        vm.expectRevert(
            abi.encodeWithSelector(Errors.CircuitBreakerTripped.selector, 2, 1)
        );
        cb.checkAndRecordOutflow(2);
        vm.stopPrank();
    }

    function test_CheckAndRecord_RevertsWhenFullyExhausted() public {
        vm.startPrank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD); // exhaust

        vm.expectRevert(
            abi.encodeWithSelector(Errors.CircuitBreakerTripped.selector, 1, 0)
        );
        cb.checkAndRecordOutflow(1);
        vm.stopPrank();
    }

    function test_CheckAndRecord_RevertsWhenSingleCallExceedsLimit() public {
        uint256 overLimit = DEFAULT_LIMIT_USD + 1;
        vm.prank(VAULT);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.CircuitBreakerTripped.selector, overLimit, DEFAULT_LIMIT_USD)
        );
        cb.checkAndRecordOutflow(overLimit);
    }

    // =========================================================================
    // Window rolling
    // =========================================================================

    function test_Window_ResetsAccumulatorAfterPeriod() public {
        // Fill to near limit.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD - 1);
        assertEq(cb.cumulativeOutflow(), DEFAULT_LIMIT_USD - 1);

        // Advance time past the full window.
        vm.warp(block.timestamp + DEFAULT_PERIOD);

        // New window: accumulator resets — a fresh full-limit outflow is allowed.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD);
        assertEq(cb.cumulativeOutflow(), DEFAULT_LIMIT_USD);
    }

    function test_Window_UpdatesWindowStartOnReset() public {
        uint256 startBefore = cb.windowStart();
        vm.warp(block.timestamp + DEFAULT_PERIOD);

        vm.prank(VAULT);
        cb.checkAndRecordOutflow(1e8);

        assertEq(cb.windowStart(), startBefore + DEFAULT_PERIOD, "windowStart must advance to warp time");
    }

    function test_Window_BoundaryAtExactPeriod_Resets() public {
        // At t = windowStart + period, _refreshWindow should trigger.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD); // exhaust

        vm.warp(cb.windowStart() + DEFAULT_PERIOD); // exactly at boundary

        // Should succeed (new window).
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(1e8);
        assertEq(cb.cumulativeOutflow(), 1e8);
    }

    function test_Window_NoResetBeforePeriodElapses() public {
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD); // exhaust

        vm.warp(block.timestamp + DEFAULT_PERIOD - 1); // 1 second before reset

        vm.prank(VAULT);
        vm.expectRevert(); // still tripped
        cb.checkAndRecordOutflow(1e8);
    }

    function test_Window_MultipleWindowsAccumulate() public {
        // Each window allows exactly limitUsd; validate across 3 consecutive windows.
        //
        // NOTE: `block.timestamp` read directly inside a test function returns the
        // timestamp captured at test-entry, NOT the one set by a preceding vm.warp
        // (Forge limitation — only external calls see the updated timestamp).
        // We therefore keep an explicit accumulator `t` rather than re-reading
        // `block.timestamp` after each warp.
        uint256 t = block.timestamp;

        for (uint256 w; w < 3; ) {
            vm.prank(VAULT);
            cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD);

            unchecked { t += DEFAULT_PERIOD; w++; }
            vm.warp(t);
        }
        // Passes without revert is the assertion.
    }

    // =========================================================================
    // remainingOutflowCapacity
    // =========================================================================

    function test_RemainingCapacity_FullAtStart() public view {
        assertEq(cb.remainingOutflowCapacity(), DEFAULT_LIMIT_USD);
    }

    function test_RemainingCapacity_DecreasesAfterOutflow() public {
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(400_000e8);
        assertEq(cb.remainingOutflowCapacity(), DEFAULT_LIMIT_USD - 400_000e8);
    }

    function test_RemainingCapacity_ZeroWhenExhausted() public {
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD);
        assertEq(cb.remainingOutflowCapacity(), 0);
    }

    function test_RemainingCapacity_ReturnsFullLimitAfterWindowExpiry_ViewOnly() public {
        // Exhaust the window.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD);
        assertEq(cb.cumulativeOutflow(), DEFAULT_LIMIT_USD);

        // Advance time past the window — view function sees full capacity.
        vm.warp(block.timestamp + DEFAULT_PERIOD);
        assertEq(cb.remainingOutflowCapacity(), DEFAULT_LIMIT_USD);

        // State is NOT mutated by the view call.
        assertEq(cb.cumulativeOutflow(), DEFAULT_LIMIT_USD, "View must not mutate state");
    }

    // =========================================================================
    // setLimit
    // =========================================================================

    function test_SetLimit_UpdatesParameters() public {
        vm.prank(OWNER);
        cb.setLimit(48 hours, 5_000_000e8);

        assertEq(cb.period(),    48 hours);
        assertEq(cb.limitUsd(), 5_000_000e8);
    }

    function test_SetLimit_EmitsLimitUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit CircuitBreaker.LimitUpdated(12 hours, 500_000e8);

        vm.prank(OWNER);
        cb.setLimit(12 hours, 500_000e8);
    }

    function test_SetLimit_RevertsOnZeroPeriod() public {
        vm.prank(OWNER);
        vm.expectRevert(Errors.InvalidWeight.selector);
        cb.setLimit(0, DEFAULT_LIMIT_USD);
    }

    function test_SetLimit_NonOwnerReverts() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        cb.setLimit(1 hours, 1e8);
    }

    function test_SetLimit_ReducingLimitBelowCumulative_BlocksNextOutflow() public {
        // Accumulate some outflow.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(500_000e8);

        // Owner reduces limit to below the current cumulative.
        vm.prank(OWNER);
        cb.setLimit(DEFAULT_PERIOD, 100_000e8); // new limit < cumulative

        // Any new outflow is now blocked (remaining = 0).
        vm.prank(VAULT);
        vm.expectRevert();
        cb.checkAndRecordOutflow(1e8);
    }

    function test_SetLimit_AllowsZeroLimitUsd() public {
        vm.prank(OWNER);
        cb.setLimit(DEFAULT_PERIOD, 0);
        assertEq(cb.limitUsd(), 0);

        // All outflows blocked.
        vm.prank(VAULT);
        vm.expectRevert();
        cb.checkAndRecordOutflow(1e8);
    }

    // =========================================================================
    // setVault
    // =========================================================================

    function test_SetVault_UpdatesVaultAddress() public {
        vm.prank(OWNER);
        cb.setVault(VAULT2);
        assertEq(cb.vault(), VAULT2);
    }

    function test_SetVault_EmitsVaultUpdated() public {
        vm.expectEmit(true, true, false, false);
        emit CircuitBreaker.VaultUpdated(VAULT, VAULT2);

        vm.prank(OWNER);
        cb.setVault(VAULT2);
    }

    function test_SetVault_ResetsWindow() public {
        // Accumulate outflow in old vault.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(500_000e8);
        assertEq(cb.cumulativeOutflow(), 500_000e8);

        uint256 newTimestamp = block.timestamp + 1 hours;
        vm.warp(newTimestamp);

        vm.prank(OWNER);
        cb.setVault(VAULT2);

        assertEq(cb.cumulativeOutflow(), 0,            "cumulativeOutflow must reset to 0");
        assertEq(cb.windowStart(),       newTimestamp,  "windowStart must update to current time");
    }

    function test_SetVault_OldVaultCanNoLongerCall() public {
        vm.prank(OWNER);
        cb.setVault(VAULT2);

        vm.prank(VAULT); // old vault
        vm.expectRevert(Errors.NotManager.selector);
        cb.checkAndRecordOutflow(1e8);
    }

    function test_SetVault_NewVaultCanCall() public {
        vm.prank(OWNER);
        cb.setVault(VAULT2);

        vm.prank(VAULT2);
        cb.checkAndRecordOutflow(1e8);
        assertEq(cb.cumulativeOutflow(), 1e8);
    }

    function test_SetVault_RevertsOnZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, bytes32("vault")));
        cb.setVault(address(0));
    }

    function test_SetVault_NonOwnerReverts() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        cb.setVault(VAULT2);
    }

    // =========================================================================
    // resetWindow
    // =========================================================================

    function test_ResetWindow_ClearsAccumulator() public {
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD); // exhaust

        vm.prank(OWNER);
        cb.resetWindow();

        assertEq(cb.cumulativeOutflow(), 0);
    }

    function test_ResetWindow_UpdatesWindowStart() public {
        uint256 t = block.timestamp + 7 hours;
        vm.warp(t);

        vm.prank(OWNER);
        cb.resetWindow();

        assertEq(cb.windowStart(), t);
    }

    function test_ResetWindow_AllowsOutflowAfterExhaustion() public {
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD); // exhaust

        vm.prank(OWNER);
        cb.resetWindow();

        // Should succeed after reset.
        vm.prank(VAULT);
        cb.checkAndRecordOutflow(DEFAULT_LIMIT_USD);
        assertEq(cb.cumulativeOutflow(), DEFAULT_LIMIT_USD);
    }

    function test_ResetWindow_NonOwnerReverts() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        cb.resetWindow();
    }

    // =========================================================================
    // Ownable2Step
    // =========================================================================

    function test_Ownable2Step_PendingOwner() public {
        vm.prank(OWNER);
        cb.transferOwnership(STRANGER);

        // Ownership has NOT transferred yet.
        assertEq(cb.owner(),          OWNER);
        assertEq(cb.pendingOwner(),   STRANGER);
    }

    function test_Ownable2Step_AcceptOwnership() public {
        vm.prank(OWNER);
        cb.transferOwnership(STRANGER);

        vm.prank(STRANGER);
        cb.acceptOwnership();

        assertEq(cb.owner(), STRANGER);
    }

    function test_Ownable2Step_NonPendingCannotAccept() public {
        vm.prank(OWNER);
        cb.transferOwnership(STRANGER);

        vm.prank(OWNER); // OWNER is not the pending owner
        vm.expectRevert();
        cb.acceptOwnership();
    }

    // =========================================================================
    // ETH guard
    // =========================================================================

    function test_Receive_RevertsOnETHTransfer() public {
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        (bool success,) = address(cb).call{value: 1 ether}("");
        assertFalse(success, "ETH transfer to CircuitBreaker must revert");
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    /**
     * @dev Invariant: the sum of accepted outflows never exceeds limitUsd within a window.
     */
    function testFuzz_CumulativeNeverExceedsLimit(
        uint64 limit,
        uint64 outflow1,
        uint64 outflow2
    ) public {
        uint256 lim = uint256(limit) + 1; // avoid zero limit
        CircuitBreaker fcb = new CircuitBreaker(OWNER, VAULT, DEFAULT_PERIOD, lim);

        uint256 total;

        // First outflow.
        vm.prank(VAULT);
        try fcb.checkAndRecordOutflow(outflow1) {
            total += outflow1;
        } catch {}

        // Second outflow.
        vm.prank(VAULT);
        try fcb.checkAndRecordOutflow(outflow2) {
            total += outflow2;
        } catch {}

        // Invariant: cumulative state must equal sum of accepted outflows
        // and must not exceed the limit.
        assertEq(fcb.cumulativeOutflow(), total);
        assertLe(fcb.cumulativeOutflow(), lim, "cumulative must never exceed limit");
    }

    /**
     * @dev remainingOutflowCapacity must always equal limitUsd - cumulativeOutflow
     *      within the same window.
     */
    function testFuzz_RemainingCapacityConsistency(uint64 rawOutflow) public {
        uint256 outflow = bound(rawOutflow, 0, DEFAULT_LIMIT_USD);

        vm.prank(VAULT);
        if (outflow > 0) cb.checkAndRecordOutflow(outflow);

        uint256 expectedRemaining = DEFAULT_LIMIT_USD - outflow;
        assertEq(cb.remainingOutflowCapacity(), expectedRemaining);
    }
}
