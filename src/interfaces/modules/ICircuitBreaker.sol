// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICircuitBreaker
 * @notice Minimal interface for ERC-7265-inspired circuit breaker modules.
 *
 * @dev
 * Each DemeterVault may optionally be protected by a CircuitBreaker instance
 * that enforces rate-limited outflow constraints. The circuit breaker is
 * deployed per-vault by the factory and configured with vault-specific parameters.
 *
 * Design goals:
 * - Prevent catastrophic TVL drain in the event of a vault compromise.
 * - Allow normal operations (deposits, withdrawals, rebalancing) within safe limits.
 * - Revert when the per-period outflow cap is exceeded.
 *
 * The vault calls {checkAndRecordOutflow} before every withdrawal to validate
 * that the USD value being withdrawn does not exceed the configured rate limit.
 */
interface ICircuitBreaker {
    /**
     * @notice Validates and records an outflow from the protected vault.
     *
     * @dev
     * - Implementations SHOULD track cumulative outflows within a rolling time window.
     * - If `usdValue` would push the cumulative outflow above the configured limit,
     *   the call MUST revert.
     * - If the check passes, the outflow is recorded and the call succeeds.
     *
     * @param usdValue USD value of the withdrawal (8-decimal precision, matching AUM units).
     */
    function checkAndRecordOutflow(uint256 usdValue) external;

    /**
     * @notice Returns the maximum USD value that can be withdrawn in the current period.
     *
     * @dev
     * Useful for UX: frontends can query this to show users their immediately
     * withdrawable balance without triggering a revert.
     *
     * @return allowed Maximum USD value (8-decimal) that can be withdrawn now.
     */
    function remainingOutflowCapacity() external view returns (uint256 allowed);
}
