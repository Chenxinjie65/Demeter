// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ICircuitBreaker} from "../../interfaces/modules/ICircuitBreaker.sol";
import {Errors} from "../../libraries/Errors.sol";

/**
 * @title CircuitBreaker
 * @notice Per-vault ERC-7265-inspired rate-limited outflow guard.
 *
 * @dev
 * Architecture:
 * - One CircuitBreaker instance is deployed per vault by {DemeterFactory}.
 * - The vault is the sole authorised caller of {checkAndRecordOutflow}.
 * - The owner (factory governance / DAO multisig) may reconfigure limits or
 *   override the breaker in an emergency.
 *
 * Rate-limiting model:
 * - A rolling time window of {period} seconds is used.
 * - The cumulative USD outflow within the current window is tracked.
 * - If adding `usdValue` would exceed {limitUsd}, the call reverts with
 *   {Errors.CircuitBreakerTripped}.
 * - When a new window begins the accumulator resets automatically.
 *
 * USD precision:
 * - All USD values are expressed in 8-decimal precision (same as AUM units)
 *   to remain consistent with Chainlink oracle output and {VaultMath}.
 *
 * Security:
 * - `onlyVault` restricts {checkAndRecordOutflow} to the protected vault.
 * - Ownable2Step prevents accidental ownership transfer.
 * - No fallback / receive — prevents ether accumulation.
 */
contract CircuitBreaker is Ownable2Step, ICircuitBreaker {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when the rate-limit parameters are updated.
     * @param period New window length in seconds.
     * @param limitUsd New maximum outflow (8-decimal USD) per window.
     */
    event LimitUpdated(uint256 period, uint256 limitUsd);

    /**
     * @notice Emitted when the authorised vault address is changed.
     * @param oldVault Previous vault address.
     * @param newVault New vault address.
     */
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /**
     * @notice Emitted when a successful outflow is recorded.
     * @param usdValue USD value of the outflow (8-decimal).
     * @param cumulativeUsd Total cumulative outflow in the current window after this call.
     */
    event OutflowRecorded(uint256 usdValue, uint256 cumulativeUsd);

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Address of the factory that deployed this contract.
    ///         Allowed to call {finalizeVault} exactly once for bootstrap.
    address public immutable deployer;

    /// @notice True once {finalizeVault} has been successfully called.
    bool public vaultFinalized;

    /// @notice The vault this circuit breaker protects.
    address public vault;

    /// @notice Window length in seconds for the rolling rate limit.
    uint256 public period;

    /// @notice Maximum cumulative USD outflow allowed per {period}.
    uint256 public limitUsd;

    /// @notice Cumulative USD outflow recorded within the current window.
    uint256 public cumulativeOutflow;

    /// @notice Unix timestamp marking the start of the current window.
    uint256 public windowStart;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Restricts to the protected vault.
    modifier onlyVault() {
        if (msg.sender != vault) revert Errors.NotManager(); // Reuse closest error; see note below.
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Deploys a new CircuitBreaker.
     *
     * @param owner_    Address that will own this contract (factory / DAO multisig).
     * @param vault_    The DemeterVault proxy this breaker protects.
     * @param period_   Rolling window length in seconds (e.g. 86400 = 24 hours).
     * @param limitUsd_ Maximum outflow per window in 8-decimal USD units.
     */
    constructor(address owner_, address vault_, uint256 period_, uint256 limitUsd_) Ownable(owner_) {
        if (vault_ == address(0)) revert Errors.ZeroAddress(bytes32("vault"));
        if (period_ == 0) revert Errors.InvalidWeight(); // reusing generic "invalid param" error
        deployer = msg.sender;
        vault = vault_;
        period = period_;
        limitUsd = limitUsd_;
        windowStart = block.timestamp;

        emit VaultUpdated(address(0), vault_);
        emit LimitUpdated(period_, limitUsd_);
    }

    // -------------------------------------------------------------------------
    // Bootstrap — factory-only vault finalization
    // -------------------------------------------------------------------------

    /**
     * @notice Called once by the deploying factory to wire the real vault address.
     *
     * @dev
     * Background: at the time the CircuitBreaker is deployed by {DemeterFactory},
     * the vault proxy address is not yet known (the vault is deployed in the
     * same transaction, after the CB). The factory therefore passes itself as a
     * temporary vault placeholder and calls this function immediately after the
     * vault proxy is deployed to update the reference.
     *
     * Security constraints:
     * - Only the original deployer (immutable) may call this function.
     * - It may be called EXACTLY ONCE; subsequent calls revert with {AlreadyInitialized}.
     * - After this call, `vault` points to the real proxy and `vaultFinalized = true`.
     *
     * @param vault_ Address of the newly deployed vault proxy.
     */
    function finalizeVault(address vault_) external {
        if (msg.sender != deployer) revert Errors.NotManager();
        if (vaultFinalized) revert Errors.AlreadyInitialized();
        if (vault_ == address(0)) revert Errors.ZeroAddress(bytes32("vault"));

        vaultFinalized = true;

        address old = vault;
        vault = vault_;
        emit VaultUpdated(old, vault_);
    }

    // -------------------------------------------------------------------------
    // ICircuitBreaker — Core logic
    // -------------------------------------------------------------------------

    /// @inheritdoc ICircuitBreaker
    function checkAndRecordOutflow(uint256 usdValue) external override onlyVault {
        _refreshWindow();

        uint256 newCumulative = cumulativeOutflow + usdValue;
        uint256 remaining = _remainingCapacity();

        if (usdValue > remaining) {
            revert Errors.CircuitBreakerTripped(usdValue, remaining);
        }

        cumulativeOutflow = newCumulative;
        emit OutflowRecorded(usdValue, newCumulative);
    }

    /// @inheritdoc ICircuitBreaker
    function remainingOutflowCapacity() external view override returns (uint256 allowed) {
        // Simulate window refresh without writing state.
        if (block.timestamp >= windowStart + period) {
            return limitUsd;
        }
        return _remainingCapacity();
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the rate-limit parameters.
     * @dev Can only be called by the owner. Does NOT reset the current window
     *      to avoid manipulation; the new limit applies from the next window onward
     *      (or immediately if the existing cumulative is already below the new limit).
     *
     * @param newPeriod   New window length in seconds.
     * @param newLimitUsd New maximum outflow per window (8-decimal USD).
     */
    function setLimit(uint256 newPeriod, uint256 newLimitUsd) external onlyOwner {
        if (newPeriod == 0) revert Errors.InvalidWeight();
        period = newPeriod;
        limitUsd = newLimitUsd;
        emit LimitUpdated(newPeriod, newLimitUsd);
    }

    /**
     * @notice Replaces the protected vault address.
     * @dev Intended for use when a vault is migrated to a new proxy.
     *      Resets the outflow window to prevent stale state.
     *
     * @param newVault New vault address.
     */
    function setVault(address newVault) external onlyOwner {
        if (newVault == address(0)) revert Errors.ZeroAddress(bytes32("vault"));
        address old = vault;
        vault = newVault;
        // Reset window so migrated vault starts fresh.
        cumulativeOutflow = 0;
        windowStart = block.timestamp;
        emit VaultUpdated(old, newVault);
    }

    /**
     * @notice Emergency override: forcibly resets the outflow accumulator.
     * @dev Use only in extreme circumstances (e.g. oracle manipulation post-mortem).
     *      Resets the window so the vault can resume normal operations.
     */
    function resetWindow() external onlyOwner {
        cumulativeOutflow = 0;
        windowStart = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Advances to a new window if the current one has expired.
     *      Safe to call repeatedly; only mutates state when needed.
     */
    function _refreshWindow() internal {
        if (block.timestamp >= windowStart + period) {
            cumulativeOutflow = 0;
            windowStart = block.timestamp;
        }
    }

    /**
     * @dev Returns the remaining capacity in the current window without refreshing.
     *      Callers must ensure the window is current before relying on this value.
     */
    function _remainingCapacity() internal view returns (uint256) {
        uint256 used = cumulativeOutflow;
        if (used >= limitUsd) return 0;
        return limitUsd - used;
    }

    // -------------------------------------------------------------------------
    // Ether guard
    // -------------------------------------------------------------------------

    receive() external payable {
        revert();
    }
}
