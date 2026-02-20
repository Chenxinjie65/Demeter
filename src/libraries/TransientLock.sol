// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title TransientLock
 * @notice Reentrancy lock implemented with EIP-1153 transient storage (tstore/tload).
 *
 * @dev
 * This is an Uniswap v4-inspired pattern:
 * - The lock state lives in transient storage, so it is cleared automatically at the end
 *   of each transaction.
 * - Useful for "unlock -> callback -> invariant checks -> lock" workflows where you want
 *   a controlled reentrancy window.
 *
 * Semantics:
 * - "locked"   = false stored in the slot (default for a new transaction)
 * - "unlocked" = true  stored in the slot
 *
 * Typical usage:
 * - At the start of an entrypoint:
 *     TransientLock.requireLocked();
 *     TransientLock.unlock();
 *     // external callback(s)
 *     // invariant checks
 *     TransientLock.lock();
 *
 * - For functions only callable during the unlock window:
 *     TransientLock.requireUnlocked();
 */
library TransientLock {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when trying to unlock while already unlocked.
    error AlreadyUnlocked();

    /// @dev Thrown when trying to lock while already locked.
    error AlreadyLocked();

    /// @dev Thrown when a function requires the contract to be unlocked.
    error NotUnlocked();

    /// @dev Thrown when a function requires the contract to be locked.
    error NotLocked();

    // -------------------------------------------------------------------------
    // Transient slot
    // -------------------------------------------------------------------------

    /**
     * @dev Slot holding the unlocked state, transiently.
     * bytes32(uint256(keccak256("demeter.transient.lock.unlocked")) - 1)
     */
    bytes32 internal constant IS_UNLOCKED_SLOT =
        0x6325455a59c6b575f9e35d6d111183b7862e69f351655848508239db9458ce4d;

    // -------------------------------------------------------------------------
    // Core operations
    // -------------------------------------------------------------------------

    function unlock() internal {
        if (isUnlocked()) revert AlreadyUnlocked();
        assembly ("memory-safe") {
            tstore(IS_UNLOCKED_SLOT, 1)
        }
    }

    function lock() internal {
        if (!isUnlocked()) revert AlreadyLocked();
        assembly ("memory-safe") {
            tstore(IS_UNLOCKED_SLOT, 0)
        }
    }

    function isUnlocked() internal view returns (bool unlocked) {
        assembly ("memory-safe") {
            unlocked := tload(IS_UNLOCKED_SLOT)
        }
    }

    // -------------------------------------------------------------------------
    // Preconditions
    // -------------------------------------------------------------------------

    function requireUnlocked() internal view {
        if (!isUnlocked()) revert NotUnlocked();
    }

    function requireLocked() internal view {
        if (isUnlocked()) revert NotLocked();
    }
}


