// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vesting} from "../../src/Vesting.sol";
import {ITokenCallback} from "../mocks/CallbackERC20.sol";

/// @notice 관리자·제공자·수령자를 맡아 유효한 권한으로 중첩 호출을 시도하는 시험용 계약이다.
contract ReentrantActor is ITokenCallback {
    /// @notice 지정한 토큰 이외의 주소가 콜백 함수를 호출했을 때 발생한다.
    /// @param caller 콜백을 직접 호출한 주소.
    error UnexpectedCallbackCaller(address caller);

    /// @notice 이미 Vesting 주소가 연결된 actor에 다시 연결하려 할 때 발생한다.
    error VestingAlreadyBound();

    /// @notice 이 actor가 승인·예치하고 콜백 호출자로 인정하는 테스트용 토큰.
    IERC20 public immutable TOKEN;
    /// @notice 정상 호출과 중첩 호출의 대상인 Vesting 계약.
    Vesting public vesting;
    /// @notice 중첩 호출할 Vesting 함수의 선택자와 인자를 ABI로 인코딩한 데이터.
    bytes public nestedCall;
    /// @notice true이면 중첩 실패를 전파하고, false이면 실패를 기록한 뒤 최초 작업을 계속한다.
    bool public propagateError;

    /// @notice 콜백 진입 횟수와 가장 최근 콜백에서 관찰한 상태·중첩 호출 결과.
    struct CallbackRecord {
        /// @dev 성공한 실행에 남은 콜백 진입 누적 횟수. 전체 실행이 revert하면 증가도 되돌아간다.
        uint256 attempts;
        /// @dev 콜백을 직접 호출한 주소로, 유효한 호출에서는 TOKEN 주소다.
        address caller;
        /// @dev 중첩 Vesting 호출이 revert 없이 끝났는지 여부이며 최초 작업의 성공 여부와 다르다.
        bool nestedSucceeded;
        /// @dev 중첩 호출이 반환한 원본 데이터. 실패하면 오류의 선택자와 인자를 담는다.
        bytes nestedResult;
        /// @dev 중첩 호출 직전에 읽은 기존 일정 0의 전체 상태.
        Vesting.Schedule observedSchedule;
        /// @dev 같은 시점에 일정 0에서 추가로 청구할 수 있던 금액.
        uint256 observedReleasable;
        /// @dev 콜백 시점의 다음 일정 ID. 최초 생성이 끝난 후의 값과 다를 수 있다.
        uint256 observedNextId;
    }

    CallbackRecord internal record;

    /// @notice actor가 사용할 토큰을 정한다. Vesting 주소는 배포 후 별도로 연결한다.
    /// @param token_ 승인·예치·청구에 사용하고 콜백 호출자로 인정할 토큰.
    constructor(IERC20 token_) {
        TOKEN = token_;
    }

    /// @notice 배포된 Vesting 주소를 이 시험용 actor에 연결한다.
    /// @dev 현재 연결 주소가 0이 아니면 VestingAlreadyBound로 거절하여 덮어쓰기를 막는다.
    /// @param vesting_ 정상 호출과 중첩 호출을 보낼 Vesting 계약.
    function bindVesting(Vesting vesting_) external {
        if (address(vesting) != address(0)) revert VestingAlreadyBound();
        vesting = vesting_;
    }

    /// @notice Vesting이 이 actor의 토큰을 가져갈 수 있도록 승인한다.
    /// @dev 승인만 수행하며 토큰을 실제로 예치하지는 않는다.
    /// @param amount 승인할 토큰 수량의 최소 단위.
    /// @return 토큰의 approve 호출이 반환한 성공 여부.
    function approve(uint256 amount) external returns (bool) {
        return TOKEN.approve(address(vesting), amount);
    }

    /// @notice 이 actor를 제공자·수령자로 하는 일정을 생성하고 토큰을 예치한다.
    /// @dev actor가 Vesting의 owner여야 하며 충분한 잔고와 사전 승인이 필요하다.
    /// @param amount 일정에 예치할 토큰 수량의 최소 단위.
    /// @param startTime 지급 시작 시각. 0이면 Vesting이 현재 블록 시각을 사용한다.
    /// @param cliff 최초 청구가 허용될 때까지 시작 시각부터 기다릴 초 단위 기간.
    /// @param duration 시작 시각부터 전체 지급이 끝날 때까지의 초 단위 기간.
    /// @return 생성된 일정의 ID.
    function createSchedule(uint256 amount, uint64 startTime, uint64 cliff, uint64 duration)
        external
        returns (uint256)
    {
        return vesting.createSchedule(address(this), amount, startTime, cliff, duration);
    }

    /// @notice 이 actor를 호출자로 하여 일정의 현재 미수령 확정 금액을 청구한다.
    /// @dev Vesting에서 발생한 권한·청구액·전송 오류는 호출자에게 그대로 전파된다.
    /// @param scheduleId 청구할 일정 ID.
    /// @return 이번 청구로 지급된 토큰 수량의 최소 단위.
    function claim(uint256 scheduleId) external returns (uint256) {
        return vesting.claim(scheduleId);
    }

    /// @notice 관리자 역할의 actor가 일정을 취소하고 미확정 토큰을 반환받는다.
    /// @dev 이 실험에서는 actor가 최초 제공자도 겸한다. 확정됐지만 미수령인 몫은 계약에 남는다.
    /// @param scheduleId 취소할 일정 ID.
    function revoke(uint256 scheduleId) external {
        vesting.revoke(scheduleId);
    }

    /// @notice 다음 콜백에서 시도할 중첩 호출과 오류 처리 방식을 정한다.
    /// @dev 이 설정 자체가 중첩 호출을 실행하거나 토큰의 콜백을 활성화하지는 않는다.
    /// @param callData Vesting 함수의 선택자와 인자를 ABI로 인코딩한 데이터.
    /// @param propagate true이면 중첩 실패를 원본 오류로 전파하고, false이면 기록한 뒤 계속한다.
    function configureAttempt(bytes calldata callData, bool propagate) external {
        nestedCall = callData;
        propagateError = propagate;
    }

    /// @notice 콜백 횟수와 가장 최근 관찰값·중첩 호출 결과를 조회한다.
    /// @return 전체 실행의 되돌림 이후에도 저장소에 남아 있는 콜백 기록.
    function getCallbackRecord() external view returns (CallbackRecord memory) {
        return record;
    }

    /// @notice 토큰 전송 중 콜백을 받아 일정 0을 관찰하고 설정된 Vesting 중첩 호출을 시도한다.
    /// @dev CallbackERC20이 명시적으로 호출하는 시험용 진입점이며 ERC20 표준의 자동 훅이 아니다.
    /// @dev TOKEN 이외의 호출자는 UnexpectedCallbackCaller로 거절한다.
    /// @dev 중첩 실패는 기록 후 계속하거나 propagateError에 따라 원본 오류 그대로 전파한다.
    /// @dev 오류가 최초 작업까지 전파되면 여기서 쓴 관찰 기록과 횟수도 함께 되돌아간다.
    function onTokenTransfer() external {
        if (msg.sender != address(TOKEN)) revert UnexpectedCallbackCaller(msg.sender);

        record.attempts += 1;
        record.caller = msg.sender;
        // Vesting이 토큰 전송 전에 반영한 일정 0의 상태를 관찰한다.
        record.observedSchedule = vesting.getSchedule(0);
        record.observedReleasable = vesting.releasableAmount(0);
        record.observedNextId = vesting.nextScheduleId();

        // 토큰 주소가 아니라 이 actor가 Vesting을 다시 호출해야 권한이 유효하다.
        (bool success, bytes memory result) = address(vesting).call(nestedCall);
        record.nestedSucceeded = success;
        record.nestedResult = result;

        if (!success && propagateError) {
            // 중첩 호출이 낸 오류를 바꾸지 않고 최초 호출까지 그대로 전파한다.
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
