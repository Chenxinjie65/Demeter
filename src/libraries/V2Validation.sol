// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2Errors} from "src/libraries/V2Errors.sol";

/**
 * @title V2Validation
 * @notice Pure calldata validation helpers shared by V2 entry points.
 * @custom:security-contact security@demeter.protocol
 */
library V2Validation {
    uint256 internal constant BPS = 10_000;

    function validateAssetList(address[] calldata assets) internal pure {
        if (assets.length == 0) revert V2Errors.V2Errors__EmptyArray("assets");

        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == address(0)) revert V2Errors.V2Errors__ZeroAddress("asset");
            for (uint256 j; j < i; ++j) {
                if (assets[i] == assets[j]) revert V2Errors.V2Errors__DuplicateAsset(assets[i]);
            }
            if (i != 0 && assets[i] < assets[i - 1]) {
                revert V2Errors.V2Errors__AssetsNotSorted(assets[i - 1], assets[i]);
            }
        }
    }

    function validateWeights(uint16[] calldata weights, uint256 expectedLength) internal pure {
        if (weights.length != expectedLength) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(expectedLength, weights.length);
        }

        uint256 sum;
        for (uint256 i; i < weights.length; ++i) {
            uint256 weight = weights[i];
            if (weight == 0) revert V2Errors.V2Errors__ZeroWeight(i);
            sum += weight;
        }
        if (sum != BPS) revert V2Errors.V2Errors__InvalidWeights(sum);
    }

    function validateDestination(uint16 triggerBps, uint16 destinationBps) internal pure {
        if (triggerBps == 0 || triggerBps > BPS) {
            revert V2Errors.V2Errors__InvalidBps("triggerBps", triggerBps);
        }
        if (destinationBps >= triggerBps) {
            revert V2Errors.V2Errors__InvalidBps("destinationBps", destinationBps);
        }
    }

    function validateBps(bytes32 field, uint256 value, uint256 maximum) internal pure {
        if (value > maximum) revert V2Errors.V2Errors__InvalidBps(field, value);
    }

    function validateFuture(uint64 timestamp, uint256 currentTime) internal pure {
        if (timestamp <= currentTime) {
            revert V2Errors.V2Errors__PolicyNotDelayed(timestamp, currentTime);
        }
    }
}
