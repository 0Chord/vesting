// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 수령 주소에서 입금액보다 1토큰 더 많이 소각하도록 설정할 수 있는 악의적 테스트 토큰이다.
/// @dev 수령 주소에 기존 잔고가 필요하며, 입금 후 잔고가 입금 전보다 감소하는 분기만 재현한다.
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
