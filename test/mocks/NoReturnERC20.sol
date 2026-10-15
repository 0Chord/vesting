// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice transfer, transferFrom, approve의 ABI에 반환값이 없는 최소한의 테스트용 토큰 원장이다.
/// @dev Solidity에서는 bool 반환 함수를 반환값 없이 재정의할 수 없어 ERC20 상속과 분리했다.
contract NoReturnERC20 is IERC20Errors {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert ERC20InsufficientAllowance(msg.sender, approved, amount);
            allowance[from][msg.sender] = approved - amount;
        }
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 balance = balanceOf[from];
        if (balance < amount) revert ERC20InsufficientBalance(from, balance, amount);
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
