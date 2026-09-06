// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "../../src/interfaces/external/IWETH.sol";

/**
 * @title MockWETH
 * @notice Test double for Wrapped Ether (WETH9).
 *
 * @dev
 * Replicates canonical WETH9 behaviour:
 * - deposit(): accepts ETH, mints equal amount of WETH to caller.
 * - withdraw(): burns WETH from caller, returns equal amount of ETH.
 * - receive(): same as deposit().
 *
 * The contract holds ETH in custody between deposit and withdrawal,
 * so it is naturally self-funded in tests.
 */
contract MockWETH is ERC20, IWETH {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    /// @inheritdoc IWETH
    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    /// @inheritdoc IWETH
    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @dev Test helper: mint WETH without requiring ETH (for seeding test actors).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
