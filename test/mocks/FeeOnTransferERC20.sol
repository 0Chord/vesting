// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only deposit fee: transferFrom sends 1% of the received amount to a fee recipient.
/// @dev Direct transfer and mint remain normal; this does not model outbound fees.
contract FeeOnTransferERC20 is ERC20 {
    address public immutable FEE_RECIPIENT;
    bool public chargeDepositFee;

    constructor(address feeRecipient_) ERC20("Deposit Fee Token", "DFT") {
        FEE_RECIPIENT = feeRecipient_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setChargeDepositFee(bool enabled) external {
        chargeDepositFee = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        if (chargeDepositFee) _transfer(to, FEE_RECIPIENT, amount / 100);
        return success;
    }
}
