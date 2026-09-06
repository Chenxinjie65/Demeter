// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VaultStorage
 * @notice Shared storage layout for the Demeter multi-asset vault.
 *
 * @dev
 * - All state for the vault implementation MUST be stored in this layout
 *   to keep upgrades safe and predictable.
 * - Do NOT add regular state variables in the vault implementation contract;
 *   always extend this Layout struct at the end.
 * - When adding new fields in the future, only append them to the bottom of
 *   the Layout struct to preserve storage compatibility.
 *
 * Storage slot pattern:
 * - We use a fixed slot derived from a unique string (ERC-7201 style).
 * - This allows the vault to be used behind proxies (e.g. BeaconProxy)
 *   without risking storage collisions.
 */
library VaultStorage {
    // -------------------------------------------------------------------------
    // Storage slot
    // -------------------------------------------------------------------------

    // keccak256(abi.encode(uint256(keccak256("demeter.storage.Vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT =
        0xdf27235d02fb88098fea0c0a950185ddba5904dc9fa49d60b2efadca100a3300;

    // -------------------------------------------------------------------------
    // Layout
    // -------------------------------------------------------------------------

    /**
     * @dev
     * Layout of all persistent vault state.
     *
     * High-level grouping:
     *
     * - Configuration (Slot 0-2):
     *   - baseAsset:        base asset used for ERC4626-style accounting (e.g. USDC)
     *   - manager:          portfolio manager address
     *   - addressProvider:  global protocol address provider (oracle, whitelist, etc.)
     *
     * - Portfolio Data (Dynamic):
     *   - assets[]:         underlying portfolio assets (e.g. WETH, WBTC, USDC)
     *   - weights[]:        target weights in bps (1e4 = 100%), aligned with assets[]
     *   - assetIndex:       reverse index, assetIndex[asset] = i + 1 (0 means not present)
     *   - strategyAdapter:  mapping asset => external strategy/adapter (e.g. Aave)
     *
     * - ERC20 share token state (Slot-friendly where possible):
     *   - name:               ERC20 name
     *   - symbol:             ERC20 symbol
     *   - totalShares:        total supply of vault shares
     *   - balances:           share balances per account
     *   - allowances:         allowances per (owner, spender)
     *
     * - Accounting & Fees (Slot packing friendly):
     *   - feeRecipient:         address receiving protocol fees (e.g. treasury)
     *   - performanceFeeBps:    performance fee in bps (1e4 = 100%)
     *   - managementFeeBps:     management fee in bps (annualized)
     *   - paused:               global pause flag for the vault
     *   - highWaterMark:        per-share historical max NAV used for performance fee
     *   - lastAUMSnapshot:      AUM snapshot at last management fee collection
     *   - lastFeeCollectionTime:timestamp of last management fee collection
     *   - maxDriftBps:          maximum allowed per-asset drift before rebalance is recommended
     *   - lastRebalanceTime:    timestamp of last successful rebalance
     *   - initialized:          one-time initialization flag (per proxy instance)
     *
     * - __gap: reserved storage for future upgrades.
     *
     * NOTE: When adding new fields, only append them to the bottom of this struct.
     */
    struct Layout {
        // --- Configuration (Slot 0-2) ---
        address baseAsset;
        address manager;
        address addressProvider;

        // --- Portfolio Data (Dynamic) ---
        address[] assets;
        uint256[] weights;
        // asset => index (1-based, 0 means not exists)
        mapping(address => uint256) assetIndex;
        // asset => external strategy (e.g., Aave)
        mapping(address => address) strategyAdapter;

        // --- ERC20 share token state ---
        string name;
        string symbol;
        uint256 totalShares;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;

        // --- Accounting & Fees (Slot Packing Magic) ---
        // [Slot X]
        address feeRecipient;        // 20 bytes
        uint16 performanceFeeBps;    // 2 bytes
        uint16 managementFeeBps;     // 2 bytes
        bool paused;                 // 1 byte
        // remaining 7 bytes reserved for future flags

        // [Slot X+1]
        uint256 highWaterMark;       // historical max NAV per share (for performance fee)

        // [Slot X+2]
        uint256 lastAUMSnapshot;     // AUM at last management fee collection
        uint256 lastFeeCollectionTime; // timestamp of last management fee collection

        // [Slot X+3]
        uint256 maxDriftBps;         // per-asset drift threshold (in bps) used to decide when to rebalance
        uint256 lastRebalanceTime;   // timestamp of last successful rebalance
        bool initialized;            // once-only initialize() guard

        // --- Extended configuration (appended; DO NOT reorder above fields) ---
        bool isMutable;              // whether assets/weights may be changed after initialization
        address circuitBreaker;      // ERC-7265 circuit breaker module (address(0) = disabled)
        address swapRouter;          // Uniswap V3 swap router used during rebalancing
        uint16 bufferRatioBps;       // idle liquidity buffer fraction (e.g. 1000 = 10%)
        uint16 maxSlippageBps;       // maximum swap slippage tolerance during rebalancing
        uint256 rebalanceCooldown;   // minimum seconds between successive rebalances

        // --- Upgradeability ---
        // NOTE: reduce gap by 3 when the 6 new fields above consume ~3 storage slots.
        uint256[37] __gap;
    }

    // -------------------------------------------------------------------------
    // Accessor
    // -------------------------------------------------------------------------

    /**
     * @dev Returns a pointer to the vault storage layout.
     *
     * Usage:
     * - VaultStorage.Layout storage l = VaultStorage.layout();
     * - l.baseAsset = newAsset;
     */
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}