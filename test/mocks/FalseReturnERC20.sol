// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token that can return false AFTER moving tokens, without reverting itself.
contract FalseReturnERC20 is ERC20 {
    bool public falseTransfers;
    bool public falseTransferFrom;

    constructor() ERC20("False Return Token", "FRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFalseTransfers(bool enabled) external {
        falseTransfers = enabled;
    }

    function setFalseTransferFrom(bool enabled) external {
        falseTransferFrom = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        return falseTransfers ? false : success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        return falseTransferFrom ? false : success;
    }
}
