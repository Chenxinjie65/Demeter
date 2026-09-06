// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";

/// @notice Test-only ERC-20 that can revert after mutating transfer state.
/// @dev The revert intentionally exercises transaction-wide rollback in the Manager.
contract MockV2FailingERC20 is MockV2ERC20 {
    bool public failAfterTransfer;
    bool public failAfterTransferFrom;

    error MockV2FailingERC20__TransferFailed();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockV2ERC20(name_, symbol_, decimals_) {}

    function setFailAfterTransfer(bool enabled) external {
        failAfterTransfer = enabled;
    }

    function setFailAfterTransferFrom(bool enabled) external {
        failAfterTransferFrom = enabled;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool result = super.transfer(to, value);
        if (failAfterTransfer) revert MockV2FailingERC20__TransferFailed();
        return result;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool result = super.transferFrom(from, to, value);
        if (failAfterTransferFrom) revert MockV2FailingERC20__TransferFailed();
        return result;
    }
}
