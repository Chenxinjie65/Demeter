// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "@forge-std/Script.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {AuctionRebalance} from "src/core/AuctionRebalance.sol";
import {DemeterBasketRouter} from "src/core/DemeterBasketRouter.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {UniswapV3TwapOracle} from "src/oracle/UniswapV3TwapOracle.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

/**
 * @title DeployV2Core
 * @notice Deploys the immutable Demeter V2 core against an existing timelock.
 * @dev This script deliberately does not bypass governance to wire the manager.
 * Use `WireV2Core.s.sol` to schedule and later execute the one-time links.
 */
contract DeployV2Core is Script {
    struct Deployment {
        address registry;
        address manager;
        address policy;
        address twapOracle;
        address auction;
        address router;
    }

    function run() external returns (Deployment memory deployed) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address timelock = vm.envAddress("V2_TIMELOCK");
        address guardian = vm.envAddress("V2_GUARDIAN");
        address commonQuote = vm.envAddress("V2_COMMON_QUOTE_ASSET");
        require(timelock.code.length != 0, "V2: timelock must be a contract");
        require(commonQuote.code.length != 0, "V2: quote asset must be a contract");

        vm.startBroadcast(deployerKey);
        AssetRegistry registry = new AssetRegistry(timelock, guardian, commonQuote, _poolBounds());
        DemeterManager manager = new DemeterManager(address(registry), timelock);
        IndexPolicy policy = new IndexPolicy(timelock, address(manager), _policyBounds());
        UniswapV3TwapOracle twapOracle = new UniswapV3TwapOracle();
        AuctionRebalance auction =
            new AuctionRebalance(address(manager), address(policy), address(registry), address(twapOracle));
        DemeterBasketRouter router = new DemeterBasketRouter(address(manager));
        vm.stopBroadcast();

        deployed = Deployment({
            registry: address(registry),
            manager: address(manager),
            policy: address(policy),
            twapOracle: address(twapOracle),
            auction: address(auction),
            router: address(router)
        });
        _assertLinks(deployed, timelock, guardian, commonQuote);
        _log(deployed);
    }

    function _assertLinks(Deployment memory deployed, address timelock, address guardian, address commonQuote)
        private
        view
    {
        AssetRegistry registry = AssetRegistry(deployed.registry);
        DemeterManager manager = DemeterManager(deployed.manager);
        AuctionRebalance auction = AuctionRebalance(deployed.auction);
        require(registry.timelock() == timelock, "V2: registry timelock");
        require(registry.guardian() == guardian, "V2: registry guardian");
        require(registry.twapQuoteAsset() == commonQuote, "V2: common quote");
        require(address(manager.registry()) == deployed.registry, "V2: manager registry");
        require(manager.timelock() == timelock, "V2: manager timelock");
        IIndexPolicy policy = IIndexPolicy(deployed.policy);
        require(address(policy.manager()) == deployed.manager, "V2: policy manager");
        require(policy.timelock() == timelock, "V2: policy timelock");
        require(address(auction.manager()) == deployed.manager, "V2: auction manager");
        require(address(auction.policy()) == deployed.policy, "V2: auction policy");
        require(address(auction.registry()) == deployed.registry, "V2: auction registry");
        require(address(auction.twapOracle()) == deployed.twapOracle, "V2: auction oracle");
        require(address(DemeterBasketRouter(deployed.router).manager()) == deployed.manager, "V2: router manager");
        require(manager.indexPolicy() == address(0), "V2: policy unexpectedly wired");
        require(manager.auctionRebalance() == address(0), "V2: auction unexpectedly wired");
    }

    function _log(Deployment memory deployed) private pure {
        console2.log("Demeter V2 AssetRegistry:", deployed.registry);
        console2.log("Demeter V2 Manager:", deployed.manager);
        console2.log("Demeter V2 IndexPolicy:", deployed.policy);
        console2.log("Demeter V2 TWAP oracle:", deployed.twapOracle);
        console2.log("Demeter V2 Auction:", deployed.auction);
        console2.log("Demeter V2 BasketRouter:", deployed.router);
    }

    function _poolBounds() private pure returns (PoolTypes.GlobalPoolBounds memory bounds) {
        bounds.minAssets = 2;
        bounds.maxAssets = 16;
        bounds.maxNameBytes = 64;
        bounds.maxSymbolBytes = 16;
        bounds.minInitialShareSupply = 1e18;
        bounds.maxInitialShareSupply = 1e30;
        bounds.minBootstrapDuration = 1 hours;
        bounds.maxBootstrapDuration = 30 days;
    }

    function _policyBounds() private pure returns (RebalanceTypes.GlobalPolicyBounds memory bounds) {
        bounds.minAssets = 2;
        bounds.maxAssets = 16;
        bounds.minWeightBps = 100;
        bounds.maxWeightBps = 9_000;
        bounds.minPolicyDelay = 1 days;
        bounds.maxPolicyDelay = 30 days;
        bounds.minPlanInterval = 1 days;
        bounds.maxPlanDuration = 14 days;
        bounds.maxTurnoverBps = 2_000;
        bounds.maxAssetAdjustmentBps = 1_000;
        bounds.maxStartPremiumBps = 200;
        bounds.maxDiscountBps = 500;
        bounds.minAuctionDuration = 30 minutes;
        bounds.maxAuctionDuration = 12 hours;
        bounds.maxOracleDeviationBps = 300;
        bounds.maxReferenceMoveBps = 500;
    }
}
