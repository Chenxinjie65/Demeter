// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {Config}         from "./helpers/Config.sol";
import {AaveV3Adapter}  from "../src/modules/adapters/AaveV3Adapter.sol";
import {IDemeterFactory} from "../src/interfaces/core/IDemeterFactory.sol";
import {IAaveV3PoolAddressesProvider} from "../src/interfaces/external/IAaveV3.sol";

/**
 * @title CreateFund
 * @notice Deploys a sample Demeter index vault via {DemeterFactory}.
 *
 * @dev
 * ─── WHAT THIS SCRIPT DOES ───────────────────────────────────────────────────
 *  1. Reads the deployed DemeterFactory address from `deployments/<chainId>.json`.
 *  2. Deploys an {AaveV3Adapter} for each asset in the basket.
 *     (One adapter per vault is the required design — the adapter holds the aTokens.)
 *  3. Calls {DemeterFactory.createFund} to deploy a new vault + circuit breaker.
 *  4. Wires each adapter to its corresponding asset slot on the vault via
 *     {DemeterVault.setStrategy}.
 *  5. Saves the vault and adapter addresses to `deployments/<chainId>.json`.
 *
 * ─── CONFIGURATION ───────────────────────────────────────────────────────────
 *  All configurable parameters are read from environment variables so this
 *  script can be reused for any asset basket without code changes.
 *
 *  Required env vars (set in .env):
 *    DEPLOYER_PRIVATE_KEY  — private key of the transaction signer
 *    FACTORY_ADDRESS       — address of the deployed DemeterFactory
 *                            (output by Deploy.s.sol; also in deployments/<chainId>.json)
 *
 *  Optional env vars (see defaults below):
 *    FUND_MANAGER_ADDRESS  — vault manager; defaults to deployer
 *    FUND_NAME             — ERC-20 name for the share token   (default: "Demeter Index")
 *    FUND_SYMBOL           — ERC-20 symbol for the share token (default: "DMT")
 *
 * ─── ASSET BASKET & WEIGHTS ──────────────────────────────────────────────────
 *  The basket is inherited from {Config.getConfig(block.chainid)}:
 *    • Sepolia  → 100% WETH (single-asset index for testing)
 *    • Mainnet  → 50% WETH / 50% WBTC
 *
 *  Weights are expressed in basis points (BPS) and must sum to 10 000.
 *  Override the per-chain defaults by editing {Config.sol}.
 *
 * ─── AAVE V3 REWARDS ─────────────────────────────────────────────────────────
 *  On Ethereum mainnet, Aave V3 does not currently distribute on-chain rewards
 *  (stkAAVE). The adapter is deployed with `rewardsController = address(0)`.
 *  To enable rewards on other networks (e.g. Polygon), set the
 *  `AAVE_REWARDS_CONTROLLER` env var to the network's RewardsController address.
 *
 * ─── USAGE ───────────────────────────────────────────────────────────────────
 *  # Dry-run
 *  forge script script/CreateFund.s.sol --rpc-url $SEPOLIA_RPC_URL -vvvv
 *
 *  # Broadcast + verify
 *  forge script script/CreateFund.s.sol \
 *    --rpc-url $SEPOLIA_RPC_URL \
 *    --broadcast \
 *    --verify \
 *    --etherscan-api-key $ETHERSCAN_API_KEY \
 *    -vvvv
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract CreateFund is Script {
    // =========================================================================
    // Entry point
    // =========================================================================

    function run() external {
        // ── 1. Load environment ───────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address factory = vm.envAddress("FACTORY_ADDRESS");

        address manager = vm.envOr("FUND_MANAGER_ADDRESS", deployer);
        string memory fundName   = vm.envOr("FUND_NAME",   string("Demeter Index"));
        string memory fundSymbol = vm.envOr("FUND_SYMBOL", string("DMT"));

        // Optional: Aave RewardsController (address(0) disables reward claiming).
        address rewardsController = vm.envOr(
            "AAVE_REWARDS_CONTROLLER",
            address(0)
        );

        // ── 2. Load chain config ──────────────────────────────────────────────
        Config.NetworkConfig memory cfg = Config.getConfig(block.chainid);

        uint256 numAssets = cfg.assets.length;

        console2.log("=== Demeter CreateFund ===");
        console2.log("Chain ID :", block.chainid);
        console2.log("Factory  :", factory);
        console2.log("Manager  :", manager);
        console2.log("Name     :", fundName);
        console2.log("Symbol   :", fundSymbol);
        console2.log("Assets   :", numAssets);
        console2.log("");

        // ── 3. Build asset weights ────────────────────────────────────────────
        // Distribute weight evenly across all assets in the basket.
        // For a non-uniform distribution, edit Config.sol or add a weight array env var.
        uint256[] memory weights = _evenWeights(numAssets);

        // ── 4. Resolve Aave V3 Pool from PoolAddressesProvider ────────────────
        address aavePool = IAaveV3PoolAddressesProvider(cfg.aaveV3PoolAddressProvider)
            .getPool();
        console2.log("Aave V3 Pool:", aavePool);

        // ── 5. Broadcast ──────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        // Deploy one AaveV3Adapter per asset.
        // NOTE: Adapters are deployed BEFORE the vault because the vault address
        // is not known yet. After createFund returns the vault address, adapters
        // are wired via setStrategy.
        address[] memory adapters = new address[](numAssets);
        for (uint256 i; i < numAssets; ++i) {
            AaveV3Adapter adapter = new AaveV3Adapter(aavePool, rewardsController);
            adapters[i] = address(adapter);
            console2.log("[adapter] asset=%s  adapter=%s", cfg.assets[i], adapters[i]);
        }

        // Create the vault via the factory.
        IDemeterFactory.CreateFundParams memory params = IDemeterFactory.CreateFundParams({
            manager: manager,
            assets:  cfg.assets,
            weights: weights,
            name:    fundName,
            symbol:  fundSymbol
        });

        address vault = IDemeterFactory(factory).createFund(params);
        console2.log("[vault] deployed:", vault);

        // Wire adapters to the vault (manager-gated call).
        // The script's deployer must be the vault manager (or the manager specified above).
        for (uint256 i; i < numAssets; ++i) {
            // IDemeterVault.setStrategy(asset, adapter)
            (bool ok,) = vault.call(
                abi.encodeWithSignature(
                    "setStrategy(address,address)",
                    cfg.assets[i],
                    adapters[i]
                )
            );
            require(ok, string.concat("CreateFund: setStrategy failed for asset index ", vm.toString(i)));
            console2.log("[wire] setStrategy: asset=%s  adapter=%s", cfg.assets[i], adapters[i]);
        }

        vm.stopBroadcast();

        // ── 6. Persist addresses ──────────────────────────────────────────────
        _saveDeployment(vault, cfg.assets, adapters);

        // ── 7. Summary ────────────────────────────────────────────────────────
        console2.log("");
        console2.log("======================================================");
        console2.log("  Demeter Fund - Created");
        console2.log("======================================================");
        console2.log("  Vault :", vault);
        for (uint256 i; i < numAssets; ++i) {
            console2.log("  Adapter[%d] (%s) :", i, cfg.assets[i]);
            console2.log("           ", adapters[i]);
        }
        console2.log("======================================================");
        console2.log("  Fund is ready. Deposit via DemeterVault.depositMulti");
        console2.log("  or single-asset via DemeterRouter.zapIn.");
        console2.log("======================================================");
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /**
     * @dev Returns an array of weights that distribute 10 000 BPS evenly.
     *      The remainder (from integer division) is added to the last weight
     *      so the sum always equals exactly 10 000.
     */
    function _evenWeights(uint256 n) internal pure returns (uint256[] memory w) {
        require(n > 0, "CreateFund: no assets");
        w = new uint256[](n);
        uint256 base      = 10_000 / n;
        uint256 remainder = 10_000 - base * n;
        for (uint256 i; i < n; ++i) {
            w[i] = base;
        }
        w[n - 1] += remainder; // absorb rounding into the last slot
    }

    /**
     * @dev Appends vault and adapter addresses to the existing deployment JSON.
     */
    function _saveDeployment(
        address vault,
        address[] memory assets,
        address[] memory adapters
    ) internal {
        string memory key = "fund";
        vm.serializeAddress(key, "Vault", vault);

        // Serialize each adapter keyed by its asset address.
        string memory json;
        for (uint256 i; i < assets.length; ++i) {
            string memory adapterKey = string.concat(
                "AaveV3Adapter_",
                vm.toString(assets[i])
            );
            if (i == assets.length - 1) {
                json = vm.serializeAddress(key, adapterKey, adapters[i]);
            } else {
                vm.serializeAddress(key, adapterKey, adapters[i]);
            }
        }

        string memory path = string.concat(
            "deployments/",
            vm.toString(block.chainid),
            "_fund.json"
        );
        vm.writeJson(json, path);
        console2.log("Fund deployment saved to:", path);
    }
}
