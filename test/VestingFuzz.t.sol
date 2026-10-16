// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vesting} from "../src/Vesting.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice 손으로 계산한 경계와 독립 계산 모델로 단일 일정의 금액·시간 규칙을 검증한다.
contract VestingFuzzTest is Test {
    uint64 internal constant START_TIME = 1_700_000_000;
    uint256 internal constant MAX_AMOUNT = 10 ** 30;
    uint256 internal constant MAX_DURATION = 10 * 365 days;

    /// @dev 실제 Schedule에서 읽어 복사하지 않고 테스트 입력으로 보관하는 약정이다.
    struct Terms {
        uint256 totalAmount;
        uint64 startTime;
        uint64 cliffDuration;
        uint64 duration;
    }

    MockERC20 internal token;
    Vesting internal vesting;
    address internal owner;
    address internal beneficiary;
    Terms internal terms;

    /// @dev 실제 claim 반환값이나 Schedule 기록 대신 기대값으로만 갱신한다.
    uint256 internal modelClaimed;
    bool internal modelRevoked;
    uint64 internal modelRevokedAt;
    uint256 internal modelFrozenVested;

    /// @notice 각 사례마다 잔고가 빈 정상 토큰과 Vesting을 배포하고 시작 전 시각으로 맞춘다.
    function setUp() public {
        vm.warp(START_TIME - 1);
        owner = makeAddr("fuzz-owner");
        beneficiary = makeAddr("fuzz-beneficiary");
        token = new MockERC20();
        vesting = new Vesting(token, owner);
    }

    /// @notice 10 최소 단위를 3초 동안 지급하면 차례로 3·3·4를 받아 나머지도 남지 않는다.
    function test_RoundingClaimsThreeThreeFour() public {
        _createSchedule(Terms({totalAmount: 10, startTime: START_TIME, cliffDuration: 0, duration: 3}));

        _claimAt(START_TIME + 1, 3);
        _claimAt(START_TIME + 2, 6);
        _claimAt(START_TIME + 3, 10);

        assertEq(modelClaimed, 10);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /// @notice 2초에 스케줄을 취소하면 제공자에게 4를 반환하고 수령자는 나중에 3만 더 받는다.
    function test_RevokeAtTwoSecondsFreezesSixUnits() public {
        _createSchedule(Terms({totalAmount: 10, startTime: START_TIME, cliffDuration: 0, duration: 3}));
        _claimAt(START_TIME + 1, 3);

        _revokeAt(START_TIME + 2, 6);
        assertEq(token.balanceOf(owner), 4);
        assertEq(vesting.releasableAmount(0), 3);

        _claimAt(START_TIME + 3, 6);
        assertEq(token.balanceOf(beneficiary), 6);
        assertEq(token.balanceOf(owner), 4);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /// @notice 미래에 시작하는 cliff 0 일정도 시작 직전·정각에는 0이고 1초 뒤부터 증가한다.
    function test_FutureStartWithZeroCliff() public {
        _createSchedule(Terms({totalAmount: 100, startTime: START_TIME, cliffDuration: 0, duration: 10}));

        _claimAt(START_TIME - 1, 0);
        _claimAt(START_TIME, 0);
        _claimAt(START_TIME + 1, 10);
    }

    /// @notice cliff가 기간과 같으면 종료 직전까지 0이고 종료 정각부터 총량이 확정된다.
    function test_CliffEqualToDurationUnlocksAtEnd() public {
        _createSchedule(Terms({totalAmount: 10, startTime: START_TIME, cliffDuration: 3, duration: 3}));

        _claimAt(START_TIME + 2, 0);
        _claimAt(START_TIME + 3, 10);
        _claimAt(START_TIME + 4, 10);
    }

    /// @notice 일반 곱셈의 중간값이 넘치는 2^255 총량도 절반과 종료 시점에 정확히 지급된다.
    /// @dev 이 사례는 일반 fuzz 모델에 넣지 않고 수동으로 아는 2^254 절반을 기대값으로 사용한다.
    function test_LargeAmountClaimsExactHalves() public {
        uint256 total = uint256(1) << 255;
        uint256 half = uint256(1) << 254;
        _createSchedule(Terms({totalAmount: total, startTime: START_TIME, cliffDuration: 0, duration: 4}));

        _claimAt(START_TIME + 2, half);
        _claimAt(START_TIME + 4, total);

        assertEq(token.balanceOf(beneficiary), total);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /// @notice 총량 1은 1·2초에 내림되어 청구가 거절돼도 종료 시 온전히 받을 수 있다.
    function test_ZeroRoundedClaimsDoNotLoseFinalUnit() public {
        _createSchedule(Terms({totalAmount: 1, startTime: START_TIME, cliffDuration: 0, duration: 3}));

        _claimAt(START_TIME + 1, 0);
        _claimAt(START_TIME + 2, 0);
        _claimAt(START_TIME + 3, 1);
    }

    /// @notice 종료 시 취소는 반환액 0으로 거절되며 이미 받은 3 외에 7을 정상 청구한다.
    function test_RevokeAtEndRejectsButRemainingSevenCanBeClaimed() public {
        _createSchedule(Terms({totalAmount: 10, startTime: START_TIME, cliffDuration: 0, duration: 3}));
        _claimAt(START_TIME + 1, 3);

        _revokeAt(START_TIME + 3, 10);
        _claimAt(START_TIME + 3, 10);

        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(beneficiary), 10);
    }

    /// @notice 시작 전 취소는 전액을 반환하며 원래 종료 시점이 지나도 수령자 몫이 생기지 않는다.
    function test_RevokeBeforeStartRefundsEverything() public {
        _createSchedule(Terms({totalAmount: 10, startTime: START_TIME, cliffDuration: 0, duration: 3}));

        _revokeAt(START_TIME - 1, 0);
        _claimAt(START_TIME + 3, 0);

        assertEq(token.balanceOf(owner), 10);
    }

    /// @notice 시작 후라도 cliff 직전에 취소하면 누적 몫은 0으로 고정되고 전액 반환된다.
    function test_RevokeBeforeCliffRefundsEverything() public {
        _createSchedule(Terms({totalAmount: 100, startTime: START_TIME, cliffDuration: 4, duration: 10}));

        _revokeAt(START_TIME + 3, 0);
        _claimAt(START_TIME + 10, 0);

        assertEq(token.balanceOf(owner), 100);
    }

    /// @notice cliff 정각 취소는 cliff부터가 아니라 시작일부터 쌓인 몫 40을 보존한다.
    function test_RevokeAtCliffPreservesAccruedAmount() public {
        _createSchedule(Terms({totalAmount: 100, startTime: START_TIME, cliffDuration: 4, duration: 10}));
        _claimAt(START_TIME + 3, 0);

        _revokeAt(START_TIME + 4, 40);
        _claimAt(START_TIME + 10, 40);

        assertEq(token.balanceOf(owner), 60);
        assertEq(token.balanceOf(beneficiary), 40);
    }

    /// @notice 금액·시간을 바꿔도 조회값이 독립 계산과 같고 시간이 갈수록 감소하지 않는다.
    /// @param rawTerms 총량·시작 시각·기간·cliff로 제한할 원시 입력 네 개다.
    /// @param rawTimes 시작 전부터 종료 이후 사이의 관찰 시각 세 개를 만들 입력이다.
    function testFuzz_ViewsMatchIndependentModel(uint256[4] memory rawTerms, uint256[3] memory rawTimes) public {
        _createSchedule(_boundedTerms(rawTerms));
        uint256[3] memory times = _orderedTimes(rawTimes);
        uint256 previousVested;

        for (uint256 i; i < times.length; ++i) {
            assertGe(times[i], block.timestamp);
            vm.warp(times[i]);
            _assertState(_expectedVested(times[i]));

            uint256 actualVested = vesting.vestedAmount(0);
            assertGe(actualVested, previousVested, "vested must not decrease");
            assertLe(actualVested, terms.totalAmount, "vested must not exceed total");
            previousVested = actualVested;
        }

        vm.warp(_observationEnd());
        _assertState(terms.totalAmount);
    }

    /// @notice 여러 시각의 청구·중복 거절·종료 청구가 독립 누적 기록과 정확한 잔고를 유지한다.
    /// @param rawTerms 유효한 총량·시작 시각·기간·cliff를 만들 원시 입력이다.
    /// @param rawTimes 비감소 순서로 청구할 시각 세 개를 만들 입력이다.
    function testFuzz_RepeatedClaimsMatchIndependentModel(uint256[4] memory rawTerms, uint256[3] memory rawTimes)
        public
    {
        _createSchedule(_boundedTerms(rawTerms));
        uint256[3] memory times = _orderedTimes(rawTimes);

        for (uint256 i; i < times.length; ++i) {
            _claimAt(times[i], _expectedVested(times[i]));
        }

        _claimAt(_observationEnd(), terms.totalAmount);
        assertEq(modelClaimed, terms.totalAmount);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /// @notice 취소는 당시 몫을 고정하며, 이미 전액 확정됐다면 취소 거절 후 정상 청구를 유지한다.
    /// @param rawTerms 유효한 총량·시작 시각·기간·cliff를 만들 원시 입력이다.
    /// @param rawTimes 취소 전 청구·취소·취소 후 청구 순서의 시각을 만들 입력이다.
    function testFuzz_RevocationMatchesIndependentModel(uint256[4] memory rawTerms, uint256[3] memory rawTimes) public {
        _createSchedule(_boundedTerms(rawTerms));
        uint256[3] memory times = _orderedTimes(rawTimes);
        _claimAt(times[0], _expectedVested(times[0]));

        uint256 vestedAtRevocation = _expectedVested(times[1]);
        _revokeAt(times[1], vestedAtRevocation);

        uint256 expectedLater = modelRevoked ? modelFrozenVested : _expectedVested(times[2]);
        _claimAt(times[2], expectedLater);
        uint256 finalVested = modelRevoked ? modelFrozenVested : terms.totalAmount;
        _claimAt(_observationEnd(), finalVested);

        assertEq(modelClaimed, finalVested);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /// @notice 청구·취소할 금액이 있는 일정에서도 권한 없는 주소의 호출은 정확한 오류로 거절된다.
    /// @param caller 관리자·수령자를 제외하고 그대로 사용하는 임의 호출자다.
    function testFuzz_UnauthorizedCallsPreserveState(address caller) public {
        vm.assume(caller != owner && caller != beneficiary);
        _createSchedule(Terms({totalAmount: 1_000, startTime: START_TIME, cliffDuration: 0, duration: 100}));
        vm.warp(START_TIME + 30);
        _assertState(300);
        uint256 callerBalance = token.balanceOf(caller);

        vm.expectRevert(Vesting.NotBeneficiary.selector);
        vm.prank(caller);
        vesting.claim(0);
        _assertState(300);
        assertEq(token.balanceOf(caller), callerBalance);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        vesting.revoke(0);
        _assertState(300);
        assertEq(token.balanceOf(caller), callerBalance);
    }

    /// @notice 원시 입력을 약정 범위로 제한하여 일반 곱셈·시각 변환이 안전한 유효 일정을 만든다.
    /// @param raw 총량·시작·기간·cliff 순서로 사용할 네 값이다.
    /// @return input 운영 계산 결과와 독립적으로 준비한 테스트 입력이다.
    function _boundedTerms(uint256[4] memory raw) internal pure returns (Terms memory input) {
        uint256 start = bound(raw[1], START_TIME, START_TIME + 365 days);
        uint256 duration = bound(raw[2], 1, MAX_DURATION);
        uint256 cliff = bound(raw[3], 0, duration);
        assertLe(start + 2 * duration + 1, type(uint64).max, "bounded timestamps fit uint64");

        // 좁은 타입으로 바꿀 때 범위를 다시 검사하여 초과 값이 조용히 잘리는 것을 막는다.
        input = Terms({
            totalAmount: bound(raw[0], 1, MAX_AMOUNT),
            startTime: SafeCast.toUint64(start),
            cliffDuration: SafeCast.toUint64(cliff),
            duration: SafeCast.toUint64(duration)
        });
    }

    /// @notice 시작 직전부터 종료 이후까지 시각 세 개를 뽑고 실제 시간이 뒤로 가지 않도록 정렬한다.
    /// @param raw 제한 전 시각 입력 세 개다.
    /// @return times 같은 시각도 허용하는 비감소 순서의 관찰 시각이다.
    function _orderedTimes(uint256[3] memory raw) internal view returns (uint256[3] memory times) {
        for (uint256 i; i < times.length; ++i) {
            times[i] = bound(raw[i], uint256(terms.startTime) - 1, _observationEnd());
        }

        for (uint256 i; i < times.length; ++i) {
            for (uint256 j = i + 1; j < times.length; ++j) {
                if (times[j] < times[i]) {
                    (times[i], times[j]) = (times[j], times[i]);
                }
            }
        }
    }

    /// @notice 생성한 관찰 시각보다 이르지 않으면서 원래 지급 종료를 지난 최종 시각을 구한다.
    /// @return timestamp start + 2 × duration + 1초다. 덧셈·곱셈은 uint256에서 수행한다.
    function _observationEnd() internal view returns (uint256 timestamp) {
        return uint256(terms.startTime) + 2 * uint256(terms.duration) + 1;
    }

    /// @notice 일반 fuzz의 안전한 범위에서 취소 전 누적 몫을 단순 정수 곱셈·나눗셈으로 계산한다.
    /// @dev 운영 조회·Math.mulDiv를 호출하지 않는다. 취소 후 기대값은 별도 저장한 고정액을 쓴다.
    /// @param timestamp 누적 몫을 구할 시각이다.
    /// @return expectedVested cliff 전 0이며, 경과 초를 기간으로 제한한 뒤 계산한 정수 몫이다.
    function _expectedVested(uint256 timestamp) internal view returns (uint256 expectedVested) {
        uint256 elapsed = timestamp > terms.startTime ? timestamp - terms.startTime : 0;
        if (elapsed < terms.cliffDuration) return 0;
        if (elapsed > terms.duration) elapsed = terms.duration;

        return (terms.totalAmount * elapsed) / terms.duration;
    }

    /// @notice 제공자에게 약정액만 준비하여 정확한 승인·예치 후 일정 하나의 초기 상태를 검사한다.
    /// @param input 실제 저장 상태와 독립적으로 정한 총량·시작·cliff·기간이다.
    function _createSchedule(Terms memory input) internal {
        terms = input;
        token.mint(owner, input.totalAmount);
        vm.startPrank(owner);
        token.approve(address(vesting), input.totalAmount);
        uint256 id = vesting.createSchedule(
            beneficiary, input.totalAmount, input.startTime, input.cliffDuration, input.duration
        );
        vm.stopPrank();

        assertEq(id, 0);
        _assertState(0);
    }

    /// @notice 지정 시점에 기대 차액을 청구하고, 같은 시점의 중복 청구가 상태를 보존하며 거절되는지 확인한다.
    /// @dev 기대 차액 0도 건너뛰지 않는다. 별도 누적 기록은 실제 반환값이 아닌 기대 차액으로만 갱신한다.
    /// @param timestamp 앞으로 이동할 시각이다. 같은 시각의 반복도 허용한다.
    /// @param expectedVested 수동 예시 또는 독립 모델에서 구한 누적 몫이다.
    function _claimAt(uint256 timestamp, uint256 expectedVested) internal {
        assertGe(timestamp, block.timestamp, "time must not move backwards");
        vm.warp(timestamp);
        _assertState(expectedVested);

        uint256 expectedAmount = expectedVested - modelClaimed;
        if (expectedAmount > 0) {
            vm.prank(beneficiary);
            uint256 received = vesting.claim(0);
            assertEq(received, expectedAmount, "claim delta");
            modelClaimed += expectedAmount;
            _assertState(expectedVested);
        }

        // 최초 차액이 0이거나 방금 전액 청구했다면 추가 지급과 상태 변화 모두 없어야 한다.
        vm.expectRevert(Vesting.NothingToClaim.selector);
        vm.prank(beneficiary);
        vesting.claim(0);
        _assertState(expectedVested);
    }

    /// @notice 취소 시 몫을 고정하거나, 반환액이 0이면 정확한 오류와 미취소 상태 보존을 확인한다.
    /// @param timestamp 취소를 시도할 시각이다.
    /// @param expectedVested 취소 직전에 독립적으로 계산한 수령자의 누적 몫이다.
    function _revokeAt(uint256 timestamp, uint256 expectedVested) internal {
        assertGe(timestamp, block.timestamp, "time must not move backwards");
        assertLe(timestamp, type(uint64).max, "stored revocation time");
        vm.warp(timestamp);
        _assertState(expectedVested);

        if (expectedVested == terms.totalAmount) {
            vm.expectRevert(Vesting.NothingToRevoke.selector);
            vm.prank(owner);
            vesting.revoke(0);
        } else {
            vm.prank(owner);
            vesting.revoke(0);
            modelRevoked = true;
            modelRevokedAt = SafeCast.toUint64(timestamp);
            modelFrozenVested = expectedVested;
        }

        _assertState(expectedVested);
    }

    /// @notice 독립 약정·누적 수령 기록에 맞춰 일정 전체·잔고·공급량·승인량을 비교한다.
    /// @param expectedVested 이 시점까지 수령자에게 확정된 누적 몫이다.
    function _assertState(uint256 expectedVested) internal view {
        Vesting.Schedule memory actual = vesting.getSchedule(0);
        assertEq(actual.beneficiary, beneficiary);
        assertEq(actual.funder, owner);
        assertEq(actual.totalAmount, terms.totalAmount);
        assertEq(actual.claimedAmount, modelClaimed);
        assertEq(actual.startTime, terms.startTime);
        assertEq(actual.cliffDuration, terms.cliffDuration);
        assertEq(actual.duration, terms.duration);
        assertEq(actual.revoked, modelRevoked);
        assertEq(actual.revokedAt, modelRevokedAt);

        assertLe(expectedVested, terms.totalAmount);
        assertLe(modelClaimed, expectedVested);
        assertEq(vesting.vestedAmount(0), expectedVested, "vested");
        assertEq(vesting.releasableAmount(0), expectedVested - modelClaimed, "releasable");

        uint256 refund = modelRevoked ? terms.totalAmount - modelFrozenVested : 0;
        assertEq(token.balanceOf(owner), refund);
        assertEq(token.balanceOf(beneficiary), modelClaimed);
        assertEq(token.balanceOf(address(vesting)), terms.totalAmount - refund - modelClaimed);
        assertEq(
            token.balanceOf(owner) + token.balanceOf(beneficiary) + token.balanceOf(address(vesting)), terms.totalAmount
        );
        assertEq(token.totalSupply(), terms.totalAmount);
        assertEq(token.allowance(owner, address(vesting)), 0);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(vesting.owner(), owner);
        assertEq(address(vesting.TOKEN()), address(token));
    }
}
