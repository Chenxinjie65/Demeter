// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title TransientReentrancyGuard
 * @notice Abstract contract providing a transient-storage-based reentrancy guard (EIP-1153).
 *
 * @dev
 * Semantics:
 * - 0 stored in the slot (default) = NOT_ENTERED
 * - 1 stored in the slot = ENTERED
 */
abstract contract TransientReentrancyGuard {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 private constant ENTERED_SLOT =
        0x6325455a59c6b575f9e35d6d111183b7862e69f351655848508239db9458ce4d;

    uint256 private constant NOT_ENTERED = 0;
    uint256 private constant ENTERED = 1;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when a nonReentrant function is re-entered.
    error ReentrancyGuard__Reentrant();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        bool isEntered;
        assembly {
            isEntered := tload(ENTERED_SLOT)
        }

        if (isEntered) {
            revert ReentrancyGuard__Reentrant();
        }

        assembly {
            tstore(ENTERED_SLOT, ENTERED)
        }

        _;

        assembly {
            tstore(ENTERED_SLOT, NOT_ENTERED)
        }
    }

    /**
     * @dev Prevents read-only reentrancy attacks.
     * Use this on view functions like `totalAUM()` or `navPerShare()`
     * so external protocols cannot read a manipulated intermediate state.
     */
    modifier nonReentrantView() {
        bool isEntered;
        assembly {
            isEntered := tload(ENTERED_SLOT)
        }

        if (isEntered) {
            revert ReentrancyGuard__Reentrant();
        }

        _;
    }
}
