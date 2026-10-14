// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token that reverts after transferFrom changes balances and allowance.
contract DepositRevertingERC20 is ERC20 {
    error DepositRevertedForTest();

    bool public revertDeposits;

    constructor() ERC20("Deposit Reverting Token", "DRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRevertDeposits(bool enabled) external {
        revertDeposits = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        if (revertDeposits) revert DepositRevertedForTest();
        return success;
    }
}
