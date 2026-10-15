// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Vesting} from "../src/Vesting.sol";
import {CallbackERC20} from "./mocks/CallbackERC20.sol";
import {ReentrantActor} from "./helpers/ReentrantActor.sol";

contract VestingReentrancyTest is Test {
    uint64 internal constant START_TIME = 1_700_000_000;
    uint64 internal constant CLIFF_DURATION = 20 days;
    uint64 internal constant DURATION = 100 days;
    uint256 internal constant TOTAL_AMOUNT = 1_000 ether;

    CallbackERC20 internal token;
    ReentrantActor internal actor;
    Vesting internal vesting;

    struct StateSnapshot {
        Vesting.Schedule schedule;
        uint256 nextId;
        uint256 actorBalance;
        uint256 vestingBalance;
        uint256 allowance;
        uint256 supply;
        address owner;
        bytes tokenState;
        bytes actorState;
    }

    function setUp() public {
        vm.warp(START_TIME);
        token = new CallbackERC20();
        actor = new ReentrantActor(token);
        vesting = new Vesting(token, address(actor));
        actor.bindVesting(vesting);
        token.configureCallback(address(vesting), actor, false);
    }

    /// @notice 콜백이 없으면 시험용 계약이 유효한 관리자로 일정을 만들고 수령자로 300토큰을 청구한다.
    function test_ActorCanCreateAndClaimWithoutCallback() public {
        _prepareSchedule(false);
        _moveToDay(30);

        assertEq(actor.claim(0), 300 ether);
        assertEq(vesting.getSchedule(0).claimedAmount, 300 ether);
        assertEq(token.balanceOf(address(actor)), 300 ether);
        assertEq(token.balanceOf(address(vesting)), 700 ether);
        assertEq(vesting.releasableAmount(0), 0);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
        assertEq(token.allowance(address(actor), address(vesting)), 0);
        assertEq(token.callbackCount(), 0);
        assertEq(actor.getCallbackRecord().attempts, 0);
    }

    /// @notice 콜백이 없으면 남은 잔고와 승인량 100으로 새 일정을 정상 생성할 수 있다.
    function test_ActorCanCreateAdditionalScheduleWithoutCallback() public {
        _prepareSchedule(true);
        _moveToDay(30);

        assertEq(_createSchedule(100 ether), 1);
        _assertAdditionalScheduleCreated();
        assertEq(token.callbackCount(), 0);
        assertEq(actor.getCallbackRecord().attempts, 0);
    }

    /// @notice 콜백이 없으면 유효한 관리자가 취소하고 수령자로 남은 확정 금액을 청구할 수 있다.
    function test_ActorCanRevokeWithoutCallback() public {
        _prepareRevocation();
        actor.revoke(0);
        _assertRevocationAndFinalClaim();
        assertEq(token.callbackCount(), 0);
        assertEq(actor.getCallbackRecord().attempts, 0);
    }

    /// @notice 같은 청구의 중첩 오류를 잡으면 최초 300토큰만 지급되고 중복 청구는 거절된다.
    function test_ClaimCatchesNestedClaimFailure() public {
        _prepareSchedule(false);
        _moveToDay(30);
        _enableAttempt(abi.encodeCall(Vesting.claim, (0)), false);

        assertEq(actor.claim(0), 300 ether);

        _assertClaimResult(0);
        _assertCaughtAttempt();
        _assertDuplicateClaimRejected();
    }

    /// @notice 같은 청구의 중첩 오류를 전파하면 모든 상태가 복원되고 콜백 해제 후 재시도할 수 있다.
    function test_ClaimPropagatesNestedClaimFailureAndRetries() public {
        _prepareSchedule(false);
        _moveToDay(30);
        _enableAttempt(abi.encodeCall(Vesting.claim, (0)), true);
        StateSnapshot memory beforeState = _snapshot();

        _expectPropagatedFailure();
        actor.claim(0);

        _assertStatePreserved(beforeState);
        _assertScheduleMissing(1);
        token.setCallbackEnabled(false);
        assertEq(actor.claim(0), 300 ether);
        _assertClaimResult(0);
        _assertRetryDidNotCallBack();
        _assertDuplicateClaimRejected();
    }

    /// @notice 청구 중 자금과 권한이 유효한 중첩 생성은 잠금으로 차단되고 최초 청구만 성공한다.
    function test_ClaimCatchesNestedCreationFailure() public {
        _prepareSchedule(true);
        _moveToDay(30);
        _enableAttempt(_nestedCreation(), false);

        assertEq(actor.claim(0), 300 ether);

        _assertClaimResult(100 ether);
        _assertCaughtAttempt();
        _assertScheduleMissing(1);
        _assertDuplicateClaimRejected();
    }

    /// @notice 청구 중 중첩 생성 오류를 전파하면 잔고와 승인량을 보존하고 최초 청구를 재시도한다.
    function test_ClaimPropagatesNestedCreationFailureAndRetries() public {
        _prepareSchedule(true);
        _moveToDay(30);
        _enableAttempt(_nestedCreation(), true);
        StateSnapshot memory beforeState = _snapshot();

        _expectPropagatedFailure();
        actor.claim(0);

        _assertStatePreserved(beforeState);
        _assertScheduleMissing(1);
        token.setCallbackEnabled(false);
        assertEq(actor.claim(0), 300 ether);
        _assertClaimResult(100 ether);
        _assertRetryDidNotCallBack();
        _assertDuplicateClaimRejected();
    }

    /// @notice 생성 중 기존 일정의 청구 오류를 잡으면 새 일정 하나만 생성되고 기존 일정은 보존된다.
    function test_CreateCatchesNestedClaimFailure() public {
        _prepareSchedule(true);
        _moveToDay(30);
        _enableAttempt(abi.encodeCall(Vesting.claim, (0)), false);

        assertEq(_createSchedule(100 ether), 1);

        _assertAdditionalScheduleCreated();
        _assertCaughtAttempt();
    }

    /// @notice 생성 중 청구 오류를 전파하면 전송과 승인량 소비가 복원되고 같은 ID로 재시도한다.
    function test_CreatePropagatesNestedClaimFailureAndRetries() public {
        _prepareSchedule(true);
        _moveToDay(30);
        _enableAttempt(abi.encodeCall(Vesting.claim, (0)), true);
        StateSnapshot memory beforeState = _snapshot();

        _expectPropagatedFailure();
        _createSchedule(100 ether);

        _assertStatePreserved(beforeState);
        _assertScheduleMissing(1);
        token.setCallbackEnabled(false);
        assertEq(_createSchedule(100 ether), 1);
        _assertAdditionalScheduleCreated();
        _assertRetryDidNotCallBack();
    }

    /// @notice 취소 중 남은 확정 금액의 청구는 잠금으로 막히고 최초 취소 반환만 성공한다.
    function test_RevokeCatchesNestedClaimFailure() public {
        _prepareRevocation();
        _enableAttempt(abi.encodeCall(Vesting.claim, (0)), false);

        actor.revoke(0);

        _assertCaughtAttempt();
        assertEq(actor.getCallbackRecord().observedReleasable, 200 ether);
        _assertRevocationAndFinalClaim();
        assertEq(token.callbackCount(), 1);
        assertEq(actor.getCallbackRecord().attempts, 1);
    }

    /// @notice 취소 중 청구 오류를 전파하면 취소 시각과 반환이 복원되고 같은 시점에 재취소할 수 있다.
    function test_RevokePropagatesNestedClaimFailureAndRetries() public {
        _prepareRevocation();
        _enableAttempt(abi.encodeCall(Vesting.claim, (0)), true);
        StateSnapshot memory beforeState = _snapshot();

        _expectPropagatedFailure();
        actor.revoke(0);

        _assertStatePreserved(beforeState);
        _assertScheduleMissing(1);
        token.setCallbackEnabled(false);
        actor.revoke(0);
        _assertRevocationAndFinalClaim();
        _assertRetryDidNotCallBack();
    }

    /// @notice 토큰이 아닌 호출자의 콜백은 관찰 기록이나 일정 상태를 바꾸기 전에 거절된다.
    function test_CallbackRejectsCallerOtherThanToken() public {
        _prepareSchedule(false);
        StateSnapshot memory beforeState = _snapshot();

        vm.expectRevert(abi.encodeWithSelector(ReentrantActor.UnexpectedCallbackCaller.selector, address(this)));
        actor.onTokenTransfer();

        _assertStatePreserved(beforeState);
    }

    function _enableAttempt(bytes memory nestedCall, bool propagate) internal {
        actor.configureAttempt(nestedCall, propagate);
        token.setCallbackEnabled(true);
        assertEq(actor.nestedCall(), nestedCall);
        assertEq(actor.propagateError(), propagate);
        assertEq(token.callbackCount(), 0);
        assertEq(actor.getCallbackRecord().attempts, 0);
    }

    function _nestedCreation() internal view returns (bytes memory) {
        return abi.encodeCall(Vesting.createSchedule, (address(actor), 100 ether, uint64(0), CLIFF_DURATION, DURATION));
    }

    function _expectPropagatedFailure() internal {
        // 관찰값도 되돌아가므로 실행 도구의 호출 기대 검사로 콜백 진입을 따로 확인한다.
        vm.expectCall(address(actor), abi.encodeCall(ReentrantActor.onTokenTransfer, ()), uint64(1));
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _assertCaughtAttempt() internal view {
        ReentrantActor.CallbackRecord memory observed = actor.getCallbackRecord();
        assertEq(observed.attempts, 1);
        assertEq(observed.caller, address(token));
        assertFalse(observed.nestedSucceeded);
        assertEq(observed.nestedResult, abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(abi.encode(observed.observedSchedule), abi.encode(vesting.getSchedule(0)));
        assertEq(observed.observedReleasable, vesting.releasableAmount(0));
        assertEq(observed.observedNextId, 1);
        assertEq(token.callbackCount(), 1);
        assertFalse(token.inCallback());
        assertTrue(token.callbackEnabled());
    }

    function _assertClaimResult(uint256 reserve) internal view {
        assertEq(abi.encode(vesting.getSchedule(0)), abi.encode(_expectedSchedule(300 ether, false, 0)));
        assertEq(token.balanceOf(address(actor)), reserve + 300 ether);
        assertEq(token.balanceOf(address(vesting)), 700 ether);
        assertEq(token.allowance(address(actor), address(vesting)), reserve);
        assertEq(token.totalSupply(), TOTAL_AMOUNT + reserve);
        assertEq(vesting.vestedAmount(0), 300 ether);
        assertEq(vesting.releasableAmount(0), 0);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(vesting.owner(), address(actor));
    }

    function _assertAdditionalScheduleCreated() internal view {
        assertEq(abi.encode(vesting.getSchedule(0)), abi.encode(_expectedSchedule(0, false, 0)));
        assertEq(vesting.releasableAmount(0), 300 ether);
        assertEq(vesting.nextScheduleId(), 2);
        assertEq(token.balanceOf(address(actor)), 0);
        assertEq(token.balanceOf(address(vesting)), 1_100 ether);
        assertEq(token.allowance(address(actor), address(vesting)), 0);
        assertEq(token.totalSupply(), 1_100 ether);
        assertEq(vesting.owner(), address(actor));
        Vesting.Schedule memory expected = _expectedSchedule(0, false, 0);
        expected.totalAmount = 100 ether;
        expected.startTime = uint64(uint256(START_TIME) + 30 days);
        assertEq(abi.encode(vesting.getSchedule(1)), abi.encode(expected));
    }

    function _prepareRevocation() internal {
        _prepareSchedule(false);
        _moveToDay(40);
        assertEq(actor.claim(0), 400 ether);
        assertEq(vesting.getSchedule(0).claimedAmount, 400 ether);
        assertEq(token.balanceOf(address(actor)), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
        _moveToDay(60);
    }

    function _assertRevocationAndFinalClaim() internal {
        assertEq(block.timestamp, uint256(START_TIME) + 60 days);
        uint64 revokedAt = uint64(uint256(START_TIME) + 60 days);
        assertEq(abi.encode(vesting.getSchedule(0)), abi.encode(_expectedSchedule(400 ether, true, revokedAt)));
        // actor의 잔고 800은 청구 400과 반환 400의 합이며 claimedAmount는 400이다.
        assertEq(token.balanceOf(address(actor)), 800 ether);
        assertEq(token.balanceOf(address(vesting)), 200 ether);
        assertEq(vesting.vestedAmount(0), 600 ether);
        assertEq(vesting.releasableAmount(0), 200 ether);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
        assertEq(token.allowance(address(actor), address(vesting)), 0);
        assertEq(vesting.owner(), address(actor));
        token.setCallbackEnabled(false);
        _moveToDay(100);
        assertEq(vesting.vestedAmount(0), 600 ether);
        assertEq(actor.claim(0), 200 ether);
        assertEq(abi.encode(vesting.getSchedule(0)), abi.encode(_expectedSchedule(600 ether, true, revokedAt)));
        assertEq(token.balanceOf(address(actor)), TOTAL_AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.releasableAmount(0), 0);
        _assertDuplicateClaimRejected();
    }

    function _assertDuplicateClaimRejected() internal {
        StateSnapshot memory beforeState = _snapshot();
        vm.expectRevert(Vesting.NothingToClaim.selector);
        actor.claim(0);
        _assertStatePreserved(beforeState);
    }

    function _assertScheduleMissing(uint256 id) internal {
        vm.expectRevert(abi.encodeWithSelector(Vesting.ScheduleNotFound.selector, id));
        vesting.getSchedule(id);
    }

    function _assertRetryDidNotCallBack() internal view {
        assertFalse(token.callbackEnabled());
        assertFalse(token.inCallback());
        assertEq(token.callbackCount(), 0);
        assertEq(actor.getCallbackRecord().attempts, 0);
        assertEq(actor.getCallbackRecord().nestedResult.length, 0);
    }

    function _expectedSchedule(uint256 claimed, bool revoked, uint64 revokedAt)
        internal
        view
        returns (Vesting.Schedule memory)
    {
        return Vesting.Schedule({
            beneficiary: address(actor),
            funder: address(actor),
            totalAmount: TOTAL_AMOUNT,
            claimedAmount: claimed,
            startTime: START_TIME,
            cliffDuration: CLIFF_DURATION,
            duration: DURATION,
            revokedAt: revokedAt,
            revoked: revoked
        });
    }

    function _snapshot() internal view returns (StateSnapshot memory state) {
        // 모든 실패 직전에는 기존 일정이 일정 0 하나뿐이다.
        state.schedule = vesting.getSchedule(0);
        state.nextId = vesting.nextScheduleId();
        state.actorBalance = token.balanceOf(address(actor));
        state.vestingBalance = token.balanceOf(address(vesting));
        state.allowance = token.allowance(address(actor), address(vesting));
        state.supply = token.totalSupply();
        state.owner = vesting.owner();
        state.tokenState = abi.encode(
            token.vestingCaller(),
            token.callbackReceiver(),
            token.callbackEnabled(),
            token.inCallback(),
            token.callbackCount()
        );
        state.actorState = abi.encode(
            actor.TOKEN(), actor.vesting(), actor.nestedCall(), actor.propagateError(), actor.getCallbackRecord()
        );
    }

    function _assertStatePreserved(StateSnapshot memory beforeState) internal view {
        StateSnapshot memory afterState = _snapshot();
        assertEq(abi.encode(afterState.schedule), abi.encode(beforeState.schedule));
        assertEq(afterState.nextId, beforeState.nextId);
        assertEq(afterState.actorBalance, beforeState.actorBalance);
        assertEq(afterState.vestingBalance, beforeState.vestingBalance);
        assertEq(afterState.allowance, beforeState.allowance);
        assertEq(afterState.supply, beforeState.supply);
        assertEq(afterState.owner, beforeState.owner);
        assertEq(afterState.tokenState, beforeState.tokenState);
        assertEq(afterState.actorState, beforeState.actorState);
    }

    function _prepareSchedule(bool reserveForCreation) internal {
        uint256 amount = reserveForCreation ? 1_100 ether : TOTAL_AMOUNT;
        token.mint(address(actor), amount);
        assertTrue(actor.approve(amount));
        assertEq(_createSchedule(TOTAL_AMOUNT), 0);
        assertEq(vesting.owner(), address(actor));
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(token.balanceOf(address(vesting)), TOTAL_AMOUNT);
        assertEq(token.balanceOf(address(actor)), amount - TOTAL_AMOUNT);
        assertEq(token.allowance(address(actor), address(vesting)), amount - TOTAL_AMOUNT);
        assertEq(token.totalSupply(), amount);

        Vesting.Schedule memory schedule = vesting.getSchedule(0);
        assertEq(schedule.beneficiary, address(actor));
        assertEq(schedule.funder, address(actor));
        assertEq(schedule.totalAmount, TOTAL_AMOUNT);
        assertEq(schedule.claimedAmount, 0);
        assertEq(schedule.startTime, START_TIME);
        assertEq(schedule.cliffDuration, CLIFF_DURATION);
        assertEq(schedule.duration, DURATION);
        assertFalse(schedule.revoked);
        assertEq(schedule.revokedAt, 0);
        assertEq(token.callbackCount(), 0);
        assertEq(actor.getCallbackRecord().attempts, 0);
    }

    function _createSchedule(uint256 amount) internal returns (uint256) {
        return actor.createSchedule(amount, 0, CLIFF_DURATION, DURATION);
    }

    function _moveToDay(uint256 day) internal {
        vm.warp(uint256(START_TIME) + day * 1 days);
    }
}
