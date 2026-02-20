// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FlashAccounting
 * @notice Transient (per-transaction) accounting helpers using EIP-1153 style storage.
 *
 * @dev
 * This library provides a minimal, Uniswap v4-inspired pattern for tracking expected
 * per-asset net deltas within a single transaction. It is designed to be used by
 * the core vault to:
 *
 * - Record expected inflows / outflows for each asset during a complex operation.
 * - Let external routers/adapters perform arbitrary logic (swaps, transfers, etc.).
 * - At the end of the operation, assert that all tracked deltas are zeroed out.
 *
 * Implementation notes:
 *
 * - We use EIP-1153 transient storage opcodes (TSTORE/TLOAD) via inline assembly.
 *   Transient storage is cleared automatically at the end of each transaction and
 *   is cheaper than regular storage for temporary data.
 *
 * - The API is stateless from the caller's perspective: there is no permanent
 *   storage struct, only transient slots keyed by a fixed salt + asset address.
 *
 * - Pattern:
 *   1) (optional) flashRequireAllSettled() to ensure clean state at entry
 *   2) flashAdd(asset, +amount) / flashSub(asset, amount) as you model expected flows
 *   3) external calls / callbacks
 *   4) flashRequireAllSettled() (or flashRequireZero(assetsInvolved)) at exit
 *
 * - This library intentionally does NOT maintain a separate "in use" flag.
 *   If you need a controlled reentrancy window, use {TransientLock} in the caller.
 *
 * WARNING:
 * - This library does NOT perform actual token transfers. It only tracks expected
 *   net deltas. You must ensure your vault logic and external components actually
 *   move tokens in a way that matches these deltas.
 */
library FlashAccounting {
    // -------------------------------------------------------------------------
    // Transient storage keys
    // -------------------------------------------------------------------------

    //bytes32(uint256(keccak256("demeter.flash.delta")) - 1)
    bytes32 internal constant FLASH_DELTA_SALT =
        0x31faa1f3f02878cfcb4a07611cceee3006a62f78be346007c64d05d7f49428b4;

    //bytes32(uint256(keccak256("demeter.flash.nonzero_delta_count")) - 1)
    bytes32 internal constant FLASH_NONZERO_DELTA_COUNT_SLOT =
        0x65d0e40dfa771e366815b3e3425f148a8eb771c7a015c2e87c47b3152f4cf011;

    // -------------------------------------------------------------------------
    // Internal helpers for transient storage
    // -------------------------------------------------------------------------

    function _tload(bytes32 slot) private view returns (bytes32 value) {
        assembly {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, bytes32 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _tloadU256(bytes32 slot) private view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }

    function _tstoreU256(bytes32 slot, uint256 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _tloadI256(bytes32 slot) private view returns (int256 value) {
        assembly {
            value := tload(slot)
        }
    }

    function _tstoreI256(bytes32 slot, int256 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _deltaSlot(address asset) private pure returns (bytes32) {
        // slot = keccak256(abi.encode(FLASH_DELTA_SALT, asset))
        return keccak256(abi.encode(FLASH_DELTA_SALT, asset));
    }

    function _nonzeroDeltaCount() private view returns (uint256) {
        return _tloadU256(FLASH_NONZERO_DELTA_COUNT_SLOT);
    }

    function _incNonzeroDeltaCount() private {
        _tstoreU256(FLASH_NONZERO_DELTA_COUNT_SLOT, _nonzeroDeltaCount() + 1);
    }

    function _decNonzeroDeltaCount() private {
        _tstoreU256(FLASH_NONZERO_DELTA_COUNT_SLOT, _nonzeroDeltaCount() - 1);
    }

    /**
     * @notice Returns the number of assets with a non-zero delta in the current flash scope.
     * @dev Useful to implement a Uniswap v4-like "all currencies settled" invariant check.
     */
    function flashNonzeroDeltaCount() internal view returns (uint256) {
        return _nonzeroDeltaCount();
    }

    /**
     * @notice Requires that all asset deltas are settled (i.e. nonzero delta count is zero).
     * @dev This avoids needing to pass a full list of assets to check.
     */
    function flashRequireAllSettled() internal view {
        require(_nonzeroDeltaCount() == 0, "FlashAccounting: currencies not settled");
    }

    // -------------------------------------------------------------------------
    // Delta recording
    // -------------------------------------------------------------------------

    /**
     * @notice Records a positive delta for an asset (expected net inflow into the vault).
     * @param asset  Asset address.
     * @param amount Amount expected to flow into the vault (unsigned).
     */
    function flashAdd(address asset, uint256 amount) internal {
        if (amount == 0) return;

        bytes32 slot = _deltaSlot(asset);
        int256 current = _tloadI256(slot);
        int256 delta = int256(amount);
        int256 next = current + delta;

        // Update nonzero delta count on transitions.
        if (current == 0 && next != 0) _incNonzeroDeltaCount();
        if (current != 0 && next == 0) _decNonzeroDeltaCount();

        _tstoreI256(slot, next);
    }

    /**
     * @notice Records a negative delta for an asset (expected net outflow from the vault).
     * @param asset  Asset address.
     * @param amount Amount expected to flow out of the vault (unsigned).
     */
    function flashSub(address asset, uint256 amount) internal {
        if (amount == 0) return;

        bytes32 slot = _deltaSlot(asset);
        int256 current = _tloadI256(slot);
        int256 delta = -int256(amount);
        int256 next = current + delta;

        // Update nonzero delta count on transitions.
        if (current == 0 && next != 0) _incNonzeroDeltaCount();
        if (current != 0 && next == 0) _decNonzeroDeltaCount();

        _tstoreI256(slot, next);
    }

    /**
     * @notice Returns the current tracked delta for an asset (for debugging / tests).
     */
    function flashGetDelta(address asset) internal view returns (int256) {
        bytes32 slot = _deltaSlot(asset);
        return _tloadI256(slot);
    }

    // -------------------------------------------------------------------------
    // Invariant checks
    // -------------------------------------------------------------------------

    /**
     * @notice Requires that all tracked deltas for the given assets are zero, then clears them.
     * @dev
     * - Intended to be called at the end of a high-level operation after all external
     *   calls have completed and actual token transfers are done.
     * - If any asset has a non-zero delta, the call will revert.
     */
    function flashRequireZero(address[] memory assets) internal {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            bytes32 slot = _deltaSlot(asset);
            int256 d = _tloadI256(slot);
            if (d != 0) {
                revert("FlashAccounting: non-zero delta");
            }
            // Explicitly clear (optional, but keeps semantics obvious).
            _tstoreI256(slot, 0);
        }
    }

    /**
     * @notice Clears deltas for the given assets without checking.
     * @dev Use with care; primarily intended for error recovery paths.
     */
    function flashClear(address[] memory assets) internal {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 slot = _deltaSlot(assets[i]);
            _tstoreI256(slot, 0);
        }
    }
}


