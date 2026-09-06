// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "@forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IAuctionRebalance} from "src/interfaces/IAuctionRebalance.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";

library V2WiringValidation {
    function validate(
        address timelock,
        address managerAddress,
        address policyAddress,
        address auctionAddress,
        bool unwired
    ) internal view {
        require(timelock.code.length != 0, "V2: timelock has no code");
        require(managerAddress.code.length != 0, "V2: manager has no code");
        require(policyAddress.code.length != 0, "V2: policy has no code");
        require(auctionAddress.code.length != 0, "V2: auction has no code");
        IDemeterManager manager = IDemeterManager(managerAddress);
        IIndexPolicy policy = IIndexPolicy(policyAddress);
        IAuctionRebalance auction = IAuctionRebalance(auctionAddress);
        require(manager.timelock() == timelock, "V2: manager timelock mismatch");
        require(manager.registry().timelock() == timelock, "V2: registry timelock mismatch");
        require(address(policy.manager()) == managerAddress, "V2: policy manager mismatch");
        require(policy.timelock() == timelock, "V2: policy timelock mismatch");
        require(address(auction.manager()) == managerAddress, "V2: auction manager mismatch");
        require(address(auction.policy()) == policyAddress, "V2: auction policy mismatch");
        require(address(auction.registry()) == address(manager.registry()), "V2: auction registry mismatch");
        require(address(auction.twapOracle()).code.length != 0, "V2: auction oracle has no code");
        if (unwired) {
            require(manager.indexPolicy() == address(0), "V2: manager policy already wired");
            require(manager.auctionRebalance() == address(0), "V2: manager auction already wired");
        } else {
            require(manager.indexPolicy() == policyAddress, "V2: policy wiring failed");
            require(manager.auctionRebalance() == auctionAddress, "V2: auction wiring failed");
        }
    }
}

/**
 * @title ScheduleV2CoreWiring
 * @notice Schedules the Manager's two one-time dependency writes as one batch.
 */
contract ScheduleV2CoreWiring is Script {
    function run() external {
        uint256 proposerKey = vm.envUint("TIMELOCK_PROPOSER_PRIVATE_KEY");
        TimelockController timelock = TimelockController(payable(vm.envAddress("V2_TIMELOCK")));
        address manager = vm.envAddress("V2_MANAGER");
        address policy = vm.envAddress("V2_INDEX_POLICY");
        address auction = vm.envAddress("V2_AUCTION_REBALANCE");
        bytes32 predecessor = bytes32(0);
        bytes32 salt = vm.envBytes32("V2_WIRING_SALT");
        V2WiringValidation.validate(address(timelock), manager, policy, auction, true);
        uint256 delay = timelock.getMinDelay();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch(manager, policy, auction);
        vm.startBroadcast(proposerKey);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        vm.stopBroadcast();
    }

    function _batch(address manager, address policy, address auction)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = manager;
        targets[1] = manager;
        payloads[0] = abi.encodeCall(IDemeterManager.setIndexPolicy, (policy));
        payloads[1] = abi.encodeCall(IDemeterManager.setAuctionRebalance, (auction));
    }
}

/**
 * @title ExecuteV2CoreWiring
 * @notice Executes the scheduled batch after the timelock delay and verifies it.
 */
contract ExecuteV2CoreWiring is Script {
    function run() external {
        uint256 executorKey = vm.envUint("TIMELOCK_EXECUTOR_PRIVATE_KEY");
        TimelockController timelock = TimelockController(payable(vm.envAddress("V2_TIMELOCK")));
        IDemeterManager manager = IDemeterManager(vm.envAddress("V2_MANAGER"));
        address policy = vm.envAddress("V2_INDEX_POLICY");
        address auction = vm.envAddress("V2_AUCTION_REBALANCE");
        bytes32 predecessor = bytes32(0);
        bytes32 salt = vm.envBytes32("V2_WIRING_SALT");
        V2WiringValidation.validate(address(timelock), address(manager), policy, auction, true);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _batch(address(manager), policy, auction);
        vm.startBroadcast(executorKey);
        timelock.executeBatch(targets, values, payloads, predecessor, salt);
        vm.stopBroadcast();
        V2WiringValidation.validate(address(timelock), address(manager), policy, auction, false);
    }

    function _batch(address manager, address policy, address auction)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = manager;
        targets[1] = manager;
        payloads[0] = abi.encodeCall(IDemeterManager.setIndexPolicy, (policy));
        payloads[1] = abi.encodeCall(IDemeterManager.setAuctionRebalance, (auction));
    }
}
