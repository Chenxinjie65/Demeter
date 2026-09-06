// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only ERC-20 that invokes a configured hook after transferFrom.
contract MockV2CallbackERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;
    address public hookTarget;
    bytes public hookData;
    bool public bubbleFailure = true;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferFromHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function setBubbleFailure(bool bubble) external {
        bubbleFailure = bubble;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool result = super.transferFrom(from, to, value);
        _runHook();
        return result;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool result = super.transfer(to, value);
        _runHook();
        return result;
    }

    function _runHook() private {
        address target = hookTarget;
        if (target != address(0)) {
            (bool ok, bytes memory reason) = target.call(hookData);
            if (!ok && bubbleFailure) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }
}
