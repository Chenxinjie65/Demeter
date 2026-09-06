// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Config}                  from "./helpers/Config.sol";
import {DemeterVault}            from "../src/core/DemeterVault.sol";
import {DemeterFactory}          from "../src/core/DemeterFactory.sol";
import {DemeterRouter}           from "../src/core/DemeterRouter.sol";
import {ProtocolAddressProvider} from "../src/core/ProtocolAddressProvider.sol";
import {ChainlinkOracle}         from "../src/modules/oracle/ChainlinkOracle.sol";
import {AssetWhitelist}          from "../src/modules/governance/AssetWhitelist.sol";

/**
 * @title Deploy
 * @notice Foundry deployment script for the full Demeter protocol.
 *
 * @dev
 * ─── DEPLOYMENT ORDER ────────────────────────────────────────────────────────
 *  1. DemeterVault implementation  — logic contract (never called directly)
 *  2. UpgradeableBeacon            — points to vault impl; factory reads this
 *  3. ProtocolAddressProvider      — global registry; required by oracle + whitelist
 *  4. ChainlinkOracle              — price source; reads addressProvider for riskAdmin
 *  5. AssetWhitelist               — asset gating; reads addressProvider for riskAdmin
 *  6. DemeterFactory               — creates vaults + circuit breakers
 *  7. DemeterRouter                — stateless zap router
 *
 * ─── WIRING ORDER ────────────────────────────────────────────────────────────
 *  All wiring calls use the deployer key, which must hold the following roles
 *  on the ProtocolAddressProvider for the duration of this script:
 *    • Owner     → set oracle, whitelist, factory, beacon, guardian, riskAdmin, treasury
 *    • RiskAdmin → setAssetSources on oracle, addAssets on whitelist
 *  By default the deployer is assigned to all roles; rotate via governance post-deploy.
 *
 * ─── USAGE ───────────────────────────────────────────────────────────────────
 *  # Dry-run (no broadcast, no gas)
 *  forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL -vvvv
 *
 *  # Broadcast + verify on Sepolia
 *  forge script script/Deploy.s.sol \
 *    --rpc-url $SEPOLIA_RPC_URL \
 *    --broadcast \
 *    --verify \
 *    --etherscan-api-key $ETHERSCAN_API_KEY \
 *    -vvvv
 *
 *  Deployed addresses are saved to deployments/<chainId>.json.
 * ─────────────────────────────────────────────────────────────────────────────
 */
contract Deploy is Script {
    // =========================================================================
    // Structs
    // =========================================================================

    /**
     * @dev Collects all deployed addresses so they can be serialized to JSON
     *      and logged in a single pass at the end of the script.
     */
    struct DeployedAddresses {
        address vaultImplementation;
        address vaultBeacon;
        address addressProvider;
        address oracle;
        address whitelist;
        address factory;
        address router;
    }

    // =========================================================================
    // Entry point
    // =========================================================================

    function run() external {
        // ── 1. Load environment ───────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // Role addresses — default to deployer for single-operator setups.
        // Rotate these to a multisig / DAO after deployment.
        address guardian  = vm.envOr("GUARDIAN_ADDRESS",   deployer);
        address riskAdmin = vm.envOr("RISK_ADMIN_ADDRESS", deployer);
        address treasury  = vm.envOr("TREASURY_ADDRESS",   deployer);

        // ── 2. Load chain config ──────────────────────────────────────────────
        Config.NetworkConfig memory cfg = Config.getConfig(block.chainid);

        console2.log("=== Demeter Protocol Deploy ===");
        console2.log("Chain ID  :", block.chainid);
        console2.log("Deployer  :", deployer);
        console2.log("Guardian  :", guardian);
        console2.log("Risk Admin:", riskAdmin);
        console2.log("Treasury  :", treasury);
        console2.log("");

        // ── 3. Deploy ─────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        DeployedAddresses memory d = _deploy(deployer, cfg);

        _wire(d, cfg, deployer, guardian, riskAdmin, treasury);

        vm.stopBroadcast();

        // ── 4. Persist addresses ──────────────────────────────────────────────
        _saveDeployment(d);

        // ── 5. Summary ────────────────────────────────────────────────────────
        _logSummary(d);
    }

    // =========================================================================
    // Internal — deployment
    // =========================================================================

    function _deploy(
        address deployer,
        Config.NetworkConfig memory cfg
    ) internal returns (DeployedAddresses memory d) {
        // ── Step 1: DemeterVault implementation ───────────────────────────────
        // This is the logic contract behind every BeaconProxy vault. It must
        // never be initialized directly — the constructor intentionally omits
        // any initialization logic.
        DemeterVault vaultImpl = new DemeterVault();
        d.vaultImplementation = address(vaultImpl);
        console2.log("[1/7] DemeterVault impl   :", d.vaultImplementation);

        // ── Step 2: UpgradeableBeacon ─────────────────────────────────────────
        // Owned by the deployer initially; transfer to governance after deploy.
        UpgradeableBeacon beacon = new UpgradeableBeacon(
            address(vaultImpl),
            deployer            // initial owner — rotate to DAO multisig post-deploy
        );
        d.vaultBeacon = address(beacon);
        console2.log("[2/7] UpgradeableBeacon   :", d.vaultBeacon);

        // ── Step 3: ProtocolAddressProvider ──────────────────────────────────
        ProtocolAddressProvider provider = new ProtocolAddressProvider(deployer);
        d.addressProvider = address(provider);
        console2.log("[3/7] AddressProvider     :", d.addressProvider);

        // ── Step 4: ChainlinkOracle ───────────────────────────────────────────
        ChainlinkOracle oracle = new ChainlinkOracle(
            d.addressProvider,
            cfg.maxStaleTime
        );
        d.oracle = address(oracle);
        console2.log("[4/7] ChainlinkOracle     :", d.oracle);

        // ── Step 5: AssetWhitelist ────────────────────────────────────────────
        AssetWhitelist whitelist = new AssetWhitelist(d.addressProvider);
        d.whitelist = address(whitelist);
        console2.log("[5/7] AssetWhitelist      :", d.whitelist);

        // ── Step 6: DemeterFactory ────────────────────────────────────────────
        DemeterFactory factory = new DemeterFactory(
            deployer,           // owner — rotate to DAO multisig post-deploy
            d.addressProvider,
            d.vaultBeacon
        );
        d.factory = address(factory);
        console2.log("[6/7] DemeterFactory      :", d.factory);

        // ── Step 7: DemeterRouter ─────────────────────────────────────────────
        DemeterRouter router = new DemeterRouter(cfg.weth, cfg.swapRouter);
        d.router = address(router);
        console2.log("[7/7] DemeterRouter       :", d.router);

        // Suppress unused local warning for cfg in this function scope.
        cfg;
    }

    // =========================================================================
    // Internal — wiring
    // =========================================================================

    /**
     * @dev Registers all deployed contracts in the ProtocolAddressProvider
     *      and configures the oracle and whitelist with the chain's asset basket.
     *
     * @param d         Deployed contract addresses.
     * @param cfg       Chain configuration (assets, feeds, roles).
     * @param deployer  Initial owner of the AddressProvider (also the broadcaster).
     * @param guardian  Address that can pause the protocol in emergencies.
     * @param riskAdmin Address that can manage oracle feeds and whitelist.
     * @param treasury  Address that receives protocol fees.
     */
    function _wire(
        DeployedAddresses memory d,
        Config.NetworkConfig memory cfg,
        address deployer,
        address guardian,
        address riskAdmin,
        address treasury
    ) internal {
        ProtocolAddressProvider provider = ProtocolAddressProvider(d.addressProvider);
        ChainlinkOracle         oracle   = ChainlinkOracle(d.oracle);
        AssetWhitelist          wl       = AssetWhitelist(d.whitelist);

        console2.log("");
        console2.log("=== Wiring ===");

        // ── Register contracts in AddressProvider ─────────────────────────────
        provider.setPriceOracle(d.oracle);
        provider.setAssetWhitelist(d.whitelist);
        provider.setFactory(d.factory);
        provider.setVaultBeacon(d.vaultBeacon);
        console2.log("[wire] AddressProvider registry populated");

        // ── Register roles ────────────────────────────────────────────────────
        // NOTE: If guardian/riskAdmin/treasury == deployer, these are no-ops
        // from a permissions perspective but are still required to populate the
        // registry so downstream contracts can read them.
        provider.setGuardian(guardian);
        provider.setRiskAdmin(riskAdmin);
        provider.setTreasury(treasury);
        console2.log("[wire] Roles: guardian=%s riskAdmin=%s treasury=%s", guardian, riskAdmin, treasury);

        // ── Register price feeds (onlyRiskAdmin — deployer at this point) ─────
        oracle.setAssetSources(cfg.assets, cfg.priceFeeds);
        console2.log("[wire] Price feeds registered for %d assets", cfg.assets.length);

        // ── Configure L2 sequencer uptime guard (L2 deployments only) ─────────
        if (cfg.l2Sequencer != address(0)) {
            oracle.setSequencerConfig(cfg.l2Sequencer, cfg.sequencerGracePeriod);
            console2.log("[wire] Sequencer guard configured:", cfg.l2Sequencer);
        }

        // ── Whitelist assets (onlyRiskAdmin) ───────────────────────────────────
        wl.addAssets(cfg.assets);
        console2.log("[wire] %d assets whitelisted", cfg.assets.length);

        // ── Suppress unused parameter warnings ────────────────────────────────
        deployer;
    }

    // =========================================================================
    // Internal — output
    // =========================================================================

    /**
     * @dev Serializes deployed addresses to `deployments/<chainId>.json`.
     *      The file is created (or overwritten) in the project root.
     */
    function _saveDeployment(DeployedAddresses memory d) internal {
        string memory key = "deployment";

        vm.serializeAddress(key, "VaultImplementation", d.vaultImplementation);
        vm.serializeAddress(key, "UpgradeableBeacon",   d.vaultBeacon);
        vm.serializeAddress(key, "AddressProvider",     d.addressProvider);
        vm.serializeAddress(key, "ChainlinkOracle",     d.oracle);
        vm.serializeAddress(key, "AssetWhitelist",      d.whitelist);
        vm.serializeAddress(key, "DemeterFactory",      d.factory);
        string memory json = vm.serializeAddress(key, "DemeterRouter", d.router);

        string memory path = string.concat(
            "deployments/",
            vm.toString(block.chainid),
            ".json"
        );
        vm.writeJson(json, path);
        console2.log("");
        console2.log("Deployment saved to:", path);
    }

    function _logSummary(DeployedAddresses memory d) internal pure {
        console2.log("");
        console2.log("======================================================");
        console2.log("  Demeter Protocol - Deployed Contracts");
        console2.log("======================================================");
        console2.log("  VaultImplementation :", d.vaultImplementation);
        console2.log("  UpgradeableBeacon   :", d.vaultBeacon);
        console2.log("  AddressProvider     :", d.addressProvider);
        console2.log("  ChainlinkOracle     :", d.oracle);
        console2.log("  AssetWhitelist      :", d.whitelist);
        console2.log("  DemeterFactory      :", d.factory);
        console2.log("  DemeterRouter       :", d.router);
        console2.log("======================================================");
        console2.log("  Next step: run script/CreateFund.s.sol to deploy");
        console2.log("  a sample index vault.");
        console2.log("======================================================");
    }
}
