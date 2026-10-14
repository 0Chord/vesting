// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Adversarial test token that burns the deposit plus one token from its recipient.
/// @dev Requires an existing recipient balance. Used only to reach the balanceAfter < balanceBefore branch.
contract DecreasingBalanceERC20 is ERC20 {
    bool public decreaseOnDeposit;

    constructor() ERC20("Decreasing Balance Token", "DBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDecreaseOnDeposit(bool enabled) external {
        decreaseOnDeposit = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        if (decreaseOnDeposit) _burn(to, amount + 1 ether);
        return success;
    }
}
