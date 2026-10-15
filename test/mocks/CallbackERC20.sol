// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenCallback {
    /// @notice 테스트용 토큰이 전송 도중 수신 계약으로 제어를 넘길 때 호출하는 함수다.
    /// @dev ERC20 표준의 자동 호출 규칙이 아니라 CallbackERC20이 명시적으로 호출하는 약속이다.
    function onTokenTransfer() external;
}

/// @notice 전송을 마친 뒤 지정한 시험용 계약을 호출하여 재진입 상황을 만드는 토큰이다.
contract CallbackERC20 is ERC20 {
    /// @notice 콜백을 유발할 수 있는 토큰 전송 호출자인 Vesting 주소.
    address public vestingCaller;
    /// @notice 전송 중 다시 호출할 시험용 계약.
    ITokenCallback public callbackReceiver;
    /// @notice 콜백 실행 활성 여부. 별도 설정 호출로 켜고 끈다.
    bool public callbackEnabled;
    /// @notice 콜백이 실행 중인지 표시하여 중첩 전송의 무한 콜백을 막는다.
    bool public inCallback;
    /// @notice 성공한 실행에 남은 콜백 진입 횟수. 전파 실패 시 해당 증가도 되돌아간다.
    uint256 public callbackCount;

    /// @notice 기본 18자리 소수점을 사용하는 테스트 토큰의 이름과 기호를 정한다.
    constructor() ERC20("Callback Token", "CBT") {}

    /// @notice 테스트 준비용 토큰을 발행한다. 콜백은 실행하지 않는다.
    /// @param to 발행한 토큰을 받을 주소.
    /// @param amount 발행할 토큰 수량의 최소 단위.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice 콜백을 유발할 Vesting과 호출받을 계약, 활성 여부를 지정한다.
    /// @dev 설정만 바꾸며 기존 콜백 횟수를 초기화하거나 콜백을 즉시 실행하지 않는다.
    /// @param vesting_ transfer 또는 transferFrom을 호출할 때 콜백을 허용할 주소.
    /// @param receiver_ onTokenTransfer를 호출할 시험용 계약.
    /// @param enabled 콜백을 활성화할지 여부.
    function configureCallback(address vesting_, ITokenCallback receiver_, bool enabled) external {
        vestingCaller = vesting_;
        callbackReceiver = receiver_;
        callbackEnabled = enabled;
    }

    /// @notice 콜백을 켜거나 끈다. 실패 후 재시도에서는 명시적으로 false로 설정한다.
    /// @param enabled true이면 조건을 만족하는 전송에서 콜백을 실행한다.
    function setCallbackEnabled(bool enabled) external {
        callbackEnabled = enabled;
    }

    /// @notice 잔고를 전송한 뒤 콜백 조건을 확인하고, 필요하면 수신 계약을 호출한다.
    /// @dev 콜백 오류가 전파되면 앞서 수행한 토큰 이동도 함께 되돌아간다.
    /// @param to 토큰을 받을 주소.
    /// @param amount 전송할 토큰 수량의 최소 단위.
    /// @return 전송과 필요한 콜백 처리가 끝나면 true.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _runCallback();
        return success;
    }

    /// @notice 승인량을 사용해 토큰을 전송한 뒤 조건에 따라 콜백을 실행한다.
    /// @dev 콜백 오류가 전파되면 잔고 이동과 유한 승인량 소비도 함께 되돌아간다.
    /// @param from 토큰을 보낼 주소.
    /// @param to 토큰을 받을 주소.
    /// @param amount 전송할 토큰 수량의 최소 단위.
    /// @return 전송과 필요한 콜백 처리가 끝나면 true.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _runCallback();
        return success;
    }

    /// @notice 활성 상태의 Vesting 전송에서 콜백을 실행하고 실행 중 재귀 호출을 막는다.
    /// @dev 비활성·다른 호출자·이미 콜백 실행 중인 경우에는 건너뛴다.
    /// @dev 정상 복귀 시 실행 중 표시를 해제하며, 콜백 오류는 이 전송 호출까지 전파한다.
    function _runCallback() internal {
        // 일반 전송·발행·승인에는 개입하지 않고, 중첩 전송의 무한 콜백도 막는다.
        if (!callbackEnabled || msg.sender != vestingCaller || inCallback) return;

        inCallback = true;
        callbackCount += 1;
        callbackReceiver.onTokenTransfer();
        inCallback = false;
    }
}
