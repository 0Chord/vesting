// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vesting} from "../../src/Vesting.sol";
import {ITokenCallback} from "../mocks/CallbackERC20.sol";

/// @notice 관리자·제공자·수령자를 맡아 유효한 권한으로 중첩 호출을 시도하는 시험용 계약이다.
contract ReentrantActor is ITokenCallback {
    error UnexpectedCallbackCaller(address caller);
    error VestingAlreadyBound();

    IERC20 public immutable TOKEN;
    Vesting public vesting;
    bytes public nestedCall;
    bool public propagateError;

    struct CallbackRecord {
        uint256 attempts;
        address caller;
        bool nestedSucceeded;
        bytes nestedResult;
        Vesting.Schedule observedSchedule;
        uint256 observedReleasable;
        uint256 observedNextId;
    }

    CallbackRecord internal record;

    constructor(IERC20 token_) {
        TOKEN = token_;
    }

    function bindVesting(Vesting vesting_) external {
        if (address(vesting) != address(0)) revert VestingAlreadyBound();
        vesting = vesting_;
    }

    function approve(uint256 amount) external returns (bool) {
        return TOKEN.approve(address(vesting), amount);
    }

    function createSchedule(uint256 amount, uint64 startTime, uint64 cliff, uint64 duration)
        external
        returns (uint256)
    {
        return vesting.createSchedule(address(this), amount, startTime, cliff, duration);
    }

    function claim(uint256 scheduleId) external returns (uint256) {
        return vesting.claim(scheduleId);
    }

    function revoke(uint256 scheduleId) external {
        vesting.revoke(scheduleId);
    }

    function configureAttempt(bytes calldata callData, bool propagate) external {
        nestedCall = callData;
        propagateError = propagate;
    }

    function getCallbackRecord() external view returns (CallbackRecord memory) {
        return record;
    }

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
