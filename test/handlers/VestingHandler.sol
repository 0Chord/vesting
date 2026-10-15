// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Vesting} from "../../src/Vesting.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice 유효한 행동을 준비하고 실제 Vesting의 여러 일정·자금을 독립 장부와 비교하는 테스트용 계약이다.
contract VestingHandler is Test {
    uint64 public constant START = 1_700_000_000;
    uint256 public constant MAX_SCHEDULES = 8;
    uint256 public constant MAX_AMOUNT = 10 ** 30;
    uint256 public constant TIME_LIMIT = uint256(START) + 20 * 365 days;

    /// @notice 호출 선택 수와 실제 결과를 따로 집계할 여덟 행동이다.
    enum Action {
        Create,
        AdvanceTime,
        Claim,
        Revoke,
        TransferOwnership,
        RejectClaim,
        RejectRevoke,
        DirectDeposit
    }

    /// @notice 정상 행동을 실행할 조건이 없는 이유다. 오류를 이 사유로 숨기지 않는다.
    enum SkipReason {
        ScheduleLimit,
        TimeLimit,
        NoClaimableSchedule,
        NoRevocableSchedule
    }

    /// @notice 해당 run에서의 선택·성공·확인된 거절·건너뜀 횟수다. 초기 준비는 포함하지 않는다.
    struct ActionStats {
        uint256 attempts;
        uint256 succeeded;
        uint256 rejected;
        uint256 skipped;
    }

    /// @notice 한 계정의 잔고를 운영 조회와 독립적으로 계산하기 위한 입출금 합계다.
    struct AccountFlow {
        uint256 minted;
        uint256 deposited;
        uint256 claimed;
        uint256 refunded;
        uint256 donated;
    }

    /// @notice 직접 입금을 허용하지 않은 환경의 잘못된 호출을 실패로 드러낸다.
    error DirectDepositsDisabled();

    MockERC20 public immutable token;
    Vesting public immutable vesting;
    bool public immutable allowDirectDeposits;
    address[3] public owners;
    address[3] public beneficiaries;
    address public immutable donor;

    address public expectedOwner;
    uint256 public expectedTime;
    uint256 public totalDeposited;
    uint256 public totalClaimed;
    uint256 public totalRefunded;
    uint256 public totalDirectDeposits;
    uint256 public totalMinted;

    /// @dev Schedule 타입은 형태만 재사용한다. 실제 getSchedule 결과를 복사하지 않고 생성 입력으로 구성한다.
    Vesting.Schedule[] internal expectedSchedules;
    uint256[] internal frozenVested;
    mapping(address account => AccountFlow) internal flows;
    mapping(Action action => ActionStats) public actionStats;
    mapping(SkipReason reason => uint256) public skippedByReason;

    /// @notice 초기 A·B를 예치하고 30일로 이동하여 청구·취소 가능한 무작위 검증의 시작 상태를 만든다.
    /// @param token_ 기존 정상 테스트 토큰이다.
    /// @param vesting_ 실제 검증 대상이며 최초 owner는 ownerPool[0]이어야 한다.
    /// @param ownerPool 서로 다른 비영 관리자 후보 세 개다.
    /// @param beneficiaryPool 관리자와 겹치지 않는 비영 수령자 후보 세 개다.
    /// @param donor_ 다른 후보와 겹치지 않는 직접 입금자다.
    /// @param directDeposits 직접 입금 환경인지 정한다.
    constructor(
        MockERC20 token_,
        Vesting vesting_,
        address[3] memory ownerPool,
        address[3] memory beneficiaryPool,
        address donor_,
        bool directDeposits
    ) {
        token = token_;
        vesting = vesting_;
        owners = ownerPool;
        beneficiaries = beneficiaryPool;
        donor = donor_;
        allowDirectDeposits = directDeposits;
        expectedOwner = ownerPool[0];
        expectedTime = START;
        assertEq(block.timestamp, START, "fixture start");
        _assertDistinctAccounts();

        _create(beneficiaryPool[0], 1_000 ether, START, 20 days, 100 days);
        _create(beneficiaryPool[1], 600 ether, START, 0, 60 days);
        expectedTime = uint256(START) + 30 days;
        vm.warp(expectedTime);
        assertModel();
    }

    /// @notice 유효한 입력·현재 관리자·정확한 자금과 승인으로 새 일정을 만들고 예치를 기록한다.
    /// @param raw 총량·기간·cliff·시작 지연·수령자 선택에 쓸 원시 입력 다섯 개다.
    function createSchedule(uint256[5] memory raw) public {
        ++actionStats[Action.Create].attempts;
        if (expectedSchedules.length == MAX_SCHEDULES) {
            _skip(Action.Create, SkipReason.ScheduleLimit);
            return;
        }

        uint256 duration = bound(raw[1], 1, 365 days);
        _create(
            beneficiaries[bound(raw[4], 0, 2)],
            bound(raw[0], 1, MAX_AMOUNT),
            SafeCast.toUint64(expectedTime + bound(raw[3], 0, 7 days)),
            SafeCast.toUint64(bound(raw[2], 0, duration)),
            SafeCast.toUint64(duration)
        );
        ++actionStats[Action.Create].succeeded;
        assertModel();
    }

    /// @notice 저장된 약정은 유지하고 최대 30일씩 관찰 상한 안에서 시간을 앞으로 이동한다.
    /// @param rawStep 이동할 양수 초 간격을 만들 입력이다.
    function advanceTime(uint256 rawStep) public {
        ++actionStats[Action.AdvanceTime].attempts;
        if (expectedTime == TIME_LIMIT) {
            _skip(Action.AdvanceTime, SkipReason.TimeLimit);
            return;
        }

        uint256 remaining = TIME_LIMIT - expectedTime;
        expectedTime += bound(rawStep, 1, remaining < 30 days ? remaining : 30 days);
        vm.warp(expectedTime);
        ++actionStats[Action.AdvanceTime].succeeded;
        assertModel();
    }

    /// @notice 독립 모델상 받을 금액이 있는 일정의 수령자로 청구하고 기대 차액만 장부에 더한다.
    /// @param seed 청구 가능한 일정 목록에서 고를 입력이다.
    function claim(uint256 seed) public {
        ++actionStats[Action.Claim].attempts;
        (bool found, uint256 id) = _eligibleSchedule(seed, false);
        if (!found) {
            _skip(Action.Claim, SkipReason.NoClaimableSchedule);
            return;
        }

        Vesting.Schedule storage expected = expectedSchedules[id];
        uint256 amount = expectedVested(id) - expected.claimedAmount;
        vm.prank(expected.beneficiary);
        uint256 received = vesting.claim(id);
        assertEq(received, amount, "claim return must equal independent delta");
        expected.claimedAmount += amount;
        totalClaimed += amount;
        flows[expected.beneficiary].claimed += amount;
        ++actionStats[Action.Claim].succeeded;
        assertModel();
    }

    /// @notice 취소 가능한 일정을 현재 관리자로 취소하고 독립 지급액·원래 funder 반환을 기록한다.
    /// @param seed 미취소이며 반환액이 양수인 일정 중 고를 입력이다.
    function revoke(uint256 seed) public {
        ++actionStats[Action.Revoke].attempts;
        (bool found, uint256 id) = _eligibleSchedule(seed, true);
        if (!found) {
            _skip(Action.Revoke, SkipReason.NoRevocableSchedule);
            return;
        }

        Vesting.Schedule storage expected = expectedSchedules[id];
        uint256 vested = expectedVested(id);
        uint256 refund = expected.totalAmount - vested;
        vm.prank(expectedOwner);
        vesting.revoke(id);
        expected.revoked = true;
        expected.revokedAt = SafeCast.toUint64(expectedTime);
        frozenVested[id] = vested;
        totalRefunded += refund;
        flows[expected.funder].refunded += refund;
        ++actionStats[Action.Revoke].succeeded;
        assertModel();
    }

    /// @notice 다른 관리자 후보에게 권한만 넘기고 기존 일정·자금의 반환 대상이 유지되는지 비교한다.
    /// @param seed 새 관리자를 고를 입력이다. 현재 관리자와 같으면 다음 후보를 사용한다.
    function transferOwnership(uint256 seed) public {
        ++actionStats[Action.TransferOwnership].attempts;
        uint256 index = bound(seed, 0, 2);
        if (owners[index] == expectedOwner) index = (index + 1) % 3;
        vm.prank(expectedOwner);
        vesting.transferOwnership(owners[index]);
        expectedOwner = owners[index];
        ++actionStats[Action.TransferOwnership].succeeded;
        assertModel();
    }

    /// @notice 수령자가 아닌 관리자 후보의 청구가 정확한 오류로 거절되고 장부·상태가 보존되는지 확인한다.
    /// @param scheduleSeed 존재하는 일정 중 고를 입력이다.
    /// @param callerSeed 수령자들과 분리된 관리자 후보 중 호출자를 고를 입력이다.
    function rejectUnauthorizedClaim(uint256 scheduleSeed, uint256 callerSeed) public {
        ++actionStats[Action.RejectClaim].attempts;
        uint256 id = bound(scheduleSeed, 0, expectedSchedules.length - 1);
        _assertRejected(
            owners[bound(callerSeed, 0, 2)],
            abi.encodeCall(Vesting.claim, (id)),
            abi.encodeWithSelector(Vesting.NotBeneficiary.selector)
        );
        ++actionStats[Action.RejectClaim].rejected;
        assertModel();
    }

    /// @notice 현재 관리자가 아닌 후보의 취소가 실제 호출자를 담은 권한 오류로 거절되는지 확인한다.
    /// @param scheduleSeed 존재하는 일정 중 고를 입력이다.
    /// @param callerSeed 현재 관리자와 다른 호출자를 고를 입력이다.
    function rejectUnauthorizedRevoke(uint256 scheduleSeed, uint256 callerSeed) public {
        ++actionStats[Action.RejectRevoke].attempts;
        uint256 id = bound(scheduleSeed, 0, expectedSchedules.length - 1);
        uint256 index = bound(callerSeed, 0, 2);
        if (owners[index] == expectedOwner) index = (index + 1) % 3;
        address caller = owners[index];
        _assertRejected(
            caller,
            abi.encodeCall(Vesting.revoke, (id)),
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller)
        );
        ++actionStats[Action.RejectRevoke].rejected;
        assertModel();
    }

    /// @notice 약정 외 입금은 별도 계정의 실제 전송으로 만들며 E만 늘리고 기존 의무는 보존한다.
    /// @param rawAmount 1~10^30 최소 단위로 제한할 직접 입금액이다.
    function directDeposit(uint256 rawAmount) public {
        if (!allowDirectDeposits) revert DirectDepositsDisabled();
        ++actionStats[Action.DirectDeposit].attempts;
        uint256 amount = bound(rawAmount, 1, MAX_AMOUNT);
        _mintFor(donor, amount);
        vm.prank(donor);
        assertTrue(token.transfer(address(vesting), amount));
        totalDirectDeposits += amount;
        flows[donor].donated += amount;
        ++actionStats[Action.DirectDeposit].succeeded;
        assertModel();
    }

    /// @notice 전체 약정·독립 지급액·지급 의무·자금 장부·계정 잔고·실행 통계를 함께 확인한다.
    /// @dev 실제 반환값·Schedule을 기대값에 복사하지 않는다. getter는 무작위 호출 selector에서 제외한다.
    function assertModel() public view {
        assertEq(block.timestamp, expectedTime, "model time");
        assertEq(vesting.owner(), expectedOwner, "current owner");
        assertEq(address(vesting.TOKEN()), address(token));
        assertEq(vesting.nextScheduleId(), expectedSchedules.length, "next id");
        uint256 liabilities;
        for (uint256 id; id < expectedSchedules.length; ++id) {
            Vesting.Schedule memory expected = expectedSchedules[id];
            assertEq(abi.encode(vesting.getSchedule(id)), abi.encode(expected), "all schedule fields");
            uint256 vested = expectedVested(id);
            assertLe(expected.claimedAmount, vested);
            assertLe(vested, expected.totalAmount);
            assertEq(vesting.vestedAmount(id), vested, "independent vested");
            assertEq(vesting.releasableAmount(id), vested - expected.claimedAmount, "independent releasable");
            liabilities += (expected.revoked ? frozenVested[id] : expected.totalAmount) - expected.claimedAmount;
        }

        assertEq(liabilities, totalDeposited - totalClaimed - totalRefunded, "obligation ledger");
        assertEq(token.balanceOf(address(vesting)), liabilities + totalDirectDeposits, "assets and extra deposits");
        if (!allowDirectDeposits) assertEq(totalDirectDeposits, 0, "pure environment");

        uint256 accountBalances = _assertAccount(donor);
        for (uint256 i; i < 3; ++i) {
            accountBalances += _assertAccount(owners[i]) + _assertAccount(beneficiaries[i]);
            assertEq(token.allowance(owners[i], address(vesting)), 0, "exact approvals consumed");
        }
        assertEq(accountBalances + token.balanceOf(address(vesting)), totalMinted, "all holder balances");
        assertEq(token.totalSupply(), totalMinted, "mint ledger");
        _assertStats();
    }

    /// @notice 생성 입력·기대 시간·취소 고정액으로 누적 지급액을 독립 계산한다.
    /// @param id 모델에 존재하는 일정 ID다.
    /// @return amount 취소 전에는 내림된 선형 몫, 취소 후에는 저장한 기대 고정액이다.
    function expectedVested(uint256 id) public view returns (uint256 amount) {
        Vesting.Schedule memory expected = expectedSchedules[id];
        if (expected.revoked) return frozenVested[id];
        uint256 elapsed = expectedTime > expected.startTime ? expectedTime - expected.startTime : 0;
        if (elapsed < expected.cliffDuration) return 0;
        if (elapsed > expected.duration) elapsed = expected.duration;
        return expected.totalAmount * elapsed / expected.duration;
    }

    /// @notice 실제 nextScheduleId와 별도로 보관한 성공 생성 수를 반환한다.
    /// @return count 초기 준비 두 개와 이후 성공 생성의 합이다.
    function scheduleCount() public view returns (uint256 count) {
        return expectedSchedules.length;
    }

    /// @notice 실제 기록을 복사하지 않은 기대 Schedule을 조회한다.
    /// @param id 모델 일정 ID다.
    /// @return expected 독립 생성 입력·청구·취소 기록이다.
    function modelSchedule(uint256 id) public view returns (Vesting.Schedule memory expected) {
        return expectedSchedules[id];
    }

    /// @notice 현재 장부의 남은 의무를 구한다. 별도 직접 입금은 의무에 더하지 않는다.
    /// @return amount 성공 예치에서 청구·반환을 뺀 금액이다.
    function outstandingObligation() public view returns (uint256 amount) {
        return totalDeposited - totalClaimed - totalRefunded;
    }

    /// @notice 예상 관리자 자금·승인을 준비하여 예치하고 생성 입력으로만 기대 약정을 추가한다.
    /// @param receiver 선택한 수령자다.
    /// @param amount 정확히 예치할 최소 단위 총량이다.
    /// @param start 명시적인 양수 시작 시각이다.
    /// @param cliff 시작부터의 청구 제한 초다.
    /// @param duration 전체 지급 기간 초다.
    function _create(address receiver, uint256 amount, uint64 start, uint64 cliff, uint64 duration) internal {
        _mintFor(expectedOwner, amount);
        vm.startPrank(expectedOwner);
        token.approve(address(vesting), amount);
        uint256 id = vesting.createSchedule(receiver, amount, start, cliff, duration);
        vm.stopPrank();
        assertEq(id, expectedSchedules.length, "returned schedule id");
        expectedSchedules.push(
            Vesting.Schedule({
                beneficiary: receiver,
                funder: expectedOwner,
                totalAmount: amount,
                claimedAmount: 0,
                startTime: start,
                cliffDuration: cliff,
                duration: duration,
                revokedAt: 0,
                revoked: false
            })
        );
        frozenVested.push(0);
        totalDeposited += amount;
        flows[expectedOwner].deposited += amount;
    }

    /// @notice 외부 자금 준비용 mint를 총공급량·계정 장부에 함께 기록한다.
    /// @param account 자금을 받을 준비 계정이다. Vesting 자체에는 mint하지 않는다.
    /// @param amount 준비할 양수 금액이다.
    function _mintFor(address account, uint256 amount) internal {
        token.mint(account, amount);
        flows[account].minted += amount;
        totalMinted += amount;
    }

    /// @notice 정상 행동을 실행할 수 있는 일정만 독립 모델에서 골라 부적절한 revert를 피한다.
    /// @param seed 후보 중 하나를 선택할 입력이다.
    /// @param forRevoke 취소 후보인지, 청구 후보인지 정한다.
    /// @return found 가능한 일정이 존재하는지 나타낸다.
    /// @return selected 가능한 경우 선택한 ID다. 없으면 사용하지 않는다.
    function _eligibleSchedule(uint256 seed, bool forRevoke) internal view returns (bool found, uint256 selected) {
        uint256[8] memory candidates;
        uint256 count;
        for (uint256 id; id < expectedSchedules.length; ++id) {
            Vesting.Schedule memory expected = expectedSchedules[id];
            uint256 vested = expectedVested(id);
            bool eligible =
                forRevoke ? !expected.revoked && vested < expected.totalAmount : vested > expected.claimedAmount;
            if (eligible) candidates[count++] = id;
        }
        if (count == 0) return (false, 0);
        return (true, candidates[bound(seed, 0, count - 1)]);
    }

    /// @notice 권한 없는 실제 하위 호출의 실패 여부와 오류 데이터 전체를 확인한다.
    /// @param caller 해당 권한이 없는 준비 계정이다.
    /// @param payload claim 또는 revoke의 인코딩된 호출이다.
    /// @param expectedError selector와 인자까지 포함한 기대 오류다.
    function _assertRejected(address caller, bytes memory payload, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool success, bytes memory result) = address(vesting).call(payload);
        assertFalse(success, "unauthorized call succeeded");
        assertEq(result, expectedError, "exact authorization error");
    }

    /// @notice 조건 부족을 성공과 구분하여 사유별로 기록하고 금액·상태를 재확인한다.
    /// @param action 건너뛴 정상 행동이다.
    /// @param reason 실행하지 못한 조건이다.
    function _skip(Action action, SkipReason reason) internal {
        ++actionStats[action].skipped;
        ++skippedByReason[reason];
        assertModel();
    }

    /// @notice 한 계정의 mint·예치·청구·반환·직접 입금을 실제 잔고와 대조한다.
    /// @param account 사전에 준비한 자금 보유 계정이다.
    /// @return expectedBalance 독립 장부의 기대 잔고다.
    function _assertAccount(address account) internal view returns (uint256 expectedBalance) {
        AccountFlow memory flow = flows[account];
        expectedBalance = flow.minted - flow.deposited - flow.donated + flow.claimed + flow.refunded;
        assertEq(token.balanceOf(account), expectedBalance, "account flow ledger");
    }

    /// @notice 선택 횟수가 실제 성공·확인된 거절·건너뜀으로 분해되며 사유별 합도 맞는지 확인한다.
    function _assertStats() internal view {
        uint256 skipped;
        for (uint256 i; i <= uint256(Action.DirectDeposit); ++i) {
            Action action = Action(i);
            ActionStats memory stats = actionStats[action];
            assertEq(stats.attempts, stats.succeeded + stats.rejected + stats.skipped, "action counts");
            bool rejection = action == Action.RejectClaim || action == Action.RejectRevoke;
            assertEq(rejection ? stats.succeeded : stats.rejected, 0, "success and rejection separated");
            skipped += stats.skipped;
        }
        uint256 reasons;
        for (uint256 i; i <= uint256(SkipReason.NoRevocableSchedule); ++i) {
            reasons += skippedByReason[SkipReason(i)];
        }
        assertEq(skipped, reasons, "skip reason counts");
    }

    /// @notice 계정별 자금 합산이 명확하도록 준비한 일곱 계정이 모두 비영·서로 다름을 확인한다.
    function _assertDistinctAccounts() internal view {
        address[7] memory accounts =
            [owners[0], owners[1], owners[2], beneficiaries[0], beneficiaries[1], beneficiaries[2], donor];
        for (uint256 i; i < accounts.length; ++i) {
            assertTrue(accounts[i] != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(accounts[i] != accounts[j], "distinct fixture roles");
            }
        }
    }
}
