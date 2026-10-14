// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice transferFrom 입금액의 1%를 수수료 수령처로 보내도록 설정할 수 있는 테스트 토큰이다.
/// @dev 직접 전송과 발행은 정상 동작하며, 출금 수수료는 재현하지 않는다.
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
