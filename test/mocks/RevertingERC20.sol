// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token that can revert after updating transfer balances.
contract RevertingERC20 is ERC20 {
    error TransferRevertedForTest();

    bool public revertTransfers;

    constructor() ERC20("Reverting Token", "RVT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRevertTransfers(bool enabled) external {
        revertTransfers = enabled;
    }

    /// @dev Only direct transfers are controlled; mint and transferFrom remain normal.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);

        // Reverting here also rolls back the token balances updated above.
        if (revertTransfers) {
            revert TransferRevertedForTest();
        }

        return success;
    }
}
