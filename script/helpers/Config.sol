// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Config
 * @notice Per-network deployment configuration for the Demeter protocol.
 *
 * @dev
 * ─── HOW TO ADD A NEW NETWORK ────────────────────────────────────────────────
 * 1. Add the chain ID constant (e.g. `CHAIN_ARBITRUM = 42161`).
 * 2. Implement a `_arbitrum()` private function returning a populated
 *    {NetworkConfig} struct.
 * 3. Add a `if (chainId == CHAIN_ARBITRUM) return _arbitrum();` branch
 *    in {getConfig}.
 * 4. Deploy: `forge script script/Deploy.s.sol --rpc-url arbitrum ...`
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * Supported chain IDs:
 *   1         — Ethereum Mainnet
 *   11155111  — Sepolia Testnet
 */
library Config {
    // =========================================================================
    // Types
    // =========================================================================

    struct NetworkConfig {
        // ── External protocol addresses ───────────────────────────────────────
        /// @dev Canonical WETH (wrapped native ETH) on this network.
        address weth;

        /// @dev Uniswap V3 SwapRouter02 (supports multi-hop & exact-input).
        address swapRouter;

        /// @dev Aave V3 PoolAddressesProvider; used to resolve the live Pool address.
        address aaveV3PoolAddressProvider;

        // ── Chainlink price feeds ─────────────────────────────────────────────
        /// @dev ERC-20 tokens to register in the oracle and whitelist.
        ///      assets[i] is priced by priceFeeds[i].
        address[] assets;

        /// @dev Chainlink AggregatorV3Interface feeds, parallel to {assets}.
        address[] priceFeeds;

        // ── Oracle configuration ──────────────────────────────────────────────
        /// @dev Maximum acceptable age of a price answer, in seconds.
        ///      Recommended: 3600 (mainnet) / 86400 (testnets).
        uint256 maxStaleTime;

        // ── L2 sequencer uptime guard (L1 deployments: set both to zero) ──────
        /// @dev Chainlink L2 sequencer uptime feed address, or address(0) on L1.
        address l2Sequencer;

        /// @dev Grace period in seconds after a sequencer restart before accepting prices.
        uint256 sequencerGracePeriod;
    }

    // =========================================================================
    // Chain ID constants
    // =========================================================================

    uint256 internal constant CHAIN_MAINNET = 1;
    uint256 internal constant CHAIN_SEPOLIA = 11_155_111;

    // =========================================================================
    // Public entry point
    // =========================================================================

    /**
     * @notice Returns the {NetworkConfig} for the given chain.
     * @dev Called by {Deploy.s.sol} with `block.chainid` at runtime.
     * @param chainId The chain ID of the target network.
     */
    function getConfig(uint256 chainId) internal pure returns (NetworkConfig memory) {
        if (chainId == CHAIN_MAINNET) return _mainnet();
        if (chainId == CHAIN_SEPOLIA) return _sepolia();

        revert(string.concat("Config: unsupported chainId ", _uint256ToString(chainId)));
    }

    // =========================================================================
    // Network-specific configurations
    // =========================================================================

    // ─────────────────────────────────────────────────────────────────────────
    // Ethereum Mainnet (chainId = 1)
    // ─────────────────────────────────────────────────────────────────────────
    function _mainnet() private pure returns (NetworkConfig memory cfg) {
        // Initial asset basket: WETH (50%) + WBTC (50%)
        cfg.assets    = new address[](2);
        cfg.priceFeeds = new address[](2);

        // WETH — Chainlink ETH/USD
        cfg.assets[0]    = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        cfg.priceFeeds[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        // WBTC — Chainlink BTC/USD
        cfg.assets[1]    = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        cfg.priceFeeds[1] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

        cfg.weth                      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        cfg.swapRouter                = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // SwapRouter02
        cfg.aaveV3PoolAddressProvider = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
        cfg.maxStaleTime              = 3_600;   // 1 hour — standard Chainlink heartbeat
        cfg.l2Sequencer               = address(0);
        cfg.sequencerGracePeriod      = 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sepolia Testnet (chainId = 11155111)
    // ─────────────────────────────────────────────────────────────────────────
    function _sepolia() private pure returns (NetworkConfig memory cfg) {
        // Single-asset basket: WETH only (100%)
        // To add more assets: extend both arrays and add the corresponding
        // Aave V3 Sepolia test token addresses.
        cfg.assets    = new address[](1);
        cfg.priceFeeds = new address[](1);

        // WETH (Sepolia) — Chainlink ETH/USD (Sepolia)
        cfg.assets[0]    = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        cfg.priceFeeds[0] = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

        cfg.weth                      = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        cfg.swapRouter                = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E; // SwapRouter02
        cfg.aaveV3PoolAddressProvider = 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A;
        cfg.maxStaleTime              = 86_400; // 24 hours — testnet feeds are infrequent
        cfg.l2Sequencer               = address(0);
        cfg.sequencerGracePeriod      = 0;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Converts a uint256 to its decimal string representation.
    function _uint256ToString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 tmp = v;
        while (tmp != 0) { tmp /= 10; ++digits; }
        bytes memory s = new bytes(digits);
        while (v != 0) { s[--digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(s);
    }
}
