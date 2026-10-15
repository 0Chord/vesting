// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenCallback {
    function onTokenTransfer() external;
}

/// @notice 전송을 마친 뒤 지정한 시험용 계약을 호출하여 재진입 상황을 만드는 토큰이다.
contract CallbackERC20 is ERC20 {
    address public vestingCaller;
    ITokenCallback public callbackReceiver;
    bool public callbackEnabled;
    bool public inCallback;
    uint256 public callbackCount;

    constructor() ERC20("Callback Token", "CBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureCallback(address vesting_, ITokenCallback receiver_, bool enabled) external {
        vestingCaller = vesting_;
        callbackReceiver = receiver_;
        callbackEnabled = enabled;
    }

    function setCallbackEnabled(bool enabled) external {
        callbackEnabled = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _runCallback();
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _runCallback();
        return success;
    }

    function _runCallback() internal {
        // 일반 전송·발행·승인에는 개입하지 않고, 중첩 전송의 무한 콜백도 막는다.
        if (!callbackEnabled || msg.sender != vestingCaller || inCallback) return;

        inCallback = true;
        callbackCount += 1;
        callbackReceiver.onTokenTransfer();
        inCallback = false;
    }
}
