// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console2} from "forge-std/console2.sol";

import {Vesting} from "../src/Vesting.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VestingHandler} from "./handlers/VestingHandler.sol";

/// @notice 여러 일정의 입출금·반환 대상·직접 입금을 손으로 계산한 예시와 비교한다.
contract VestingInvariantScenarioTest is Test {
    uint64 internal constant START = 1_700_000_000;
    MockERC20 internal token;
    Vesting internal vesting;
    address internal owner1;
    address internal owner2;
    address internal beneficiaryA;
    address internal beneficiaryB;
    address internal receiverB;
    address internal donor;

    /// @notice 초기 관리자와 별도 수령자·입금자를 정하고 빈 정상 토큰·Vesting을 배포한다.
    function setUp() public {
        vm.warp(START);
        owner1 = makeAddr("scenario-owner-1");
        owner2 = makeAddr("scenario-owner-2");
        beneficiaryA = makeAddr("scenario-beneficiary-a");
        beneficiaryB = makeAddr("scenario-beneficiary-b");
        donor = makeAddr("scenario-donor");
        token = new MockERC20();
        vesting = new Vesting(token, owner1);
    }

    /// @notice 1,600 예치 후 A 청구·B 취소·B 청구로 잔고가 1,300·1,100·700이 된다.
    function test_TwoSchedulesTrackDepositsClaimsAndRefunds() public {
        _createPair(false);
        _assertPair(0, 0, 0, 0, 0, 0);

        vm.warp(START + 30 days);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 300 ether);
        _assertPair(300 ether, 0, 0, 0, 0, 0);

        vm.warp(START + 40 days);
        vm.prank(owner1);
        vesting.revoke(1);
        _assertPair(300 ether, 0, 0, START + 40 days, 200 ether, 0);
        assertEq(vesting.vestedAmount(1), 400 ether);

        vm.prank(beneficiaryB);
        assertEq(vesting.claim(1), 400 ether);
        _assertPair(300 ether, 400 ether, 0, START + 40 days, 200 ether, 0);
    }

    /// @notice 새 관리자가 취소해도 최초 제공자에게 반환되고 최종 수령액은 A 600·B 400이다.
    function test_NewOwnerRevokesButOriginalFunderReceivesRefund() public {
        _prepareThroughFortyDays();
        vm.warp(START + 60 days);
        bytes32 beforeTransfer = _pairHash();
        vm.prank(owner1);
        vesting.transferOwnership(owner2);
        assertEq(vesting.owner(), owner2);
        assertEq(_pairHash(), beforeTransfer);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner1));
        vm.prank(owner1);
        vesting.revoke(0);
        _assertPair(300 ether, 400 ether, 0, START + 40 days, 200 ether, 0);

        vm.prank(owner2);
        vesting.revoke(0);
        _assertPair(300 ether, 400 ether, START + 60 days, START + 40 days, 600 ether, 0);

        vm.warp(START + 100 days);
        assertEq(vesting.vestedAmount(0), 600 ether);
        assertEq(vesting.vestedAmount(1), 400 ether);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 300 ether);
        _assertPair(600 ether, 400 ether, START + 60 days, START + 40 days, 600 ether, 0);
    }

    /// @notice 같은 수령자가 두 일정에서 받아도 claimed는 일정별로, 토큰 잔고는 합산해 기록된다.
    function test_SharedBeneficiaryKeepsScheduleClaimsSeparate() public {
        _createPair(true);
        vm.warp(START + 30 days);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 300 ether);
        _assertPair(300 ether, 0, 0, 0, 0, 0);

        vm.prank(beneficiaryA);
        assertEq(vesting.claim(1), 300 ether);
        _assertPair(300 ether, 300 ether, 0, 0, 0, 0);
        assertEq(token.balanceOf(beneficiaryA), 600 ether);
    }

    /// @notice 직접 입금 50은 지급 의무 700을 늘리지 않으며 약정 정산 후에도 계약에 남는다.
    function test_DirectDepositLeavesSurplusAfterAllObligationsArePaid() public {
        _prepareThroughFortyDays();
        bytes32 beforeDeposit = _pairHash();
        token.mint(donor, 50 ether);
        vm.prank(donor);
        assertTrue(token.transfer(address(vesting), 50 ether));
        assertEq(_pairHash(), beforeDeposit);
        _assertPair(300 ether, 400 ether, 0, START + 40 days, 200 ether, 50 ether);
        assertEq(token.balanceOf(address(vesting)), 750 ether);

        vm.warp(START + 60 days);
        vm.prank(owner1);
        vesting.revoke(0);
        _assertPair(300 ether, 400 ether, START + 60 days, START + 40 days, 600 ether, 50 ether);

        vm.warp(START + 100 days);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 300 ether);
        _assertPair(600 ether, 400 ether, START + 60 days, START + 40 days, 600 ether, 50 ether);
        assertEq(token.balanceOf(address(vesting)), 50 ether);
    }

    /// @notice 0원·중복 청구와 재취소·종료 취소 거절이 다른 일정·잔고를 바꾸지 않는다.
    function test_StateRejectionsPreserveMultipleSchedules() public {
        _createPair(false);
        vm.expectRevert(Vesting.NothingToClaim.selector);
        vm.prank(beneficiaryA);
        vesting.claim(0);
        _assertPair(0, 0, 0, 0, 0, 0);

        vm.warp(START + 30 days);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 300 ether);
        vm.expectRevert(Vesting.NothingToClaim.selector);
        vm.prank(beneficiaryA);
        vesting.claim(0);
        _assertPair(300 ether, 0, 0, 0, 0, 0);

        vm.warp(START + 40 days);
        vm.prank(owner1);
        vesting.revoke(1);
        vm.expectRevert(Vesting.AlreadyRevoked.selector);
        vm.prank(owner1);
        vesting.revoke(1);
        _assertPair(300 ether, 0, 0, START + 40 days, 200 ether, 0);

        vm.warp(START + 100 days);
        vm.expectRevert(Vesting.NothingToRevoke.selector);
        vm.prank(owner1);
        vesting.revoke(0);
        _assertPair(300 ether, 0, 0, START + 40 days, 200 ether, 0);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 700 ether);
        vm.prank(beneficiaryB);
        assertEq(vesting.claim(1), 400 ether);
        _assertPair(1_000 ether, 400 ether, 0, START + 40 days, 200 ether, 0);
    }

    /// @notice 정상 행동·권한 거절을 실제로 실행하고 새 관리자 예치·원래 제공자 반환·각 통계를 확인한다.
    function test_HandlerActionsUpdateIndependentLedgerAndCounters() public {
        VestingHandler handler = _deployHandler(false);
        handler.claim(0);
        handler.revoke(1);
        handler.transferOwnership(1);
        bytes32 beforeCreate = _pairHash();
        handler.createSchedule([uint256(100 ether), uint256(10 days), uint256(0), uint256(0), uint256(0)]);
        assertEq(_pairHash(), beforeCreate);
        assertEq(vesting.getSchedule(2).funder, owner2);
        assertEq(vesting.getSchedule(0).funder, owner1);
        handler.advanceTime(10 days);
        handler.claim(1);
        handler.revoke(0);
        handler.rejectUnauthorizedClaim(0, 0);
        handler.rejectUnauthorizedRevoke(0, 0);

        assertEq(handler.totalDeposited(), 1_700 ether);
        assertEq(handler.totalClaimed(), 600 ether);
        assertEq(handler.totalRefunded(), 900 ether);
        assertEq(handler.outstandingObligation(), 200 ether);
        assertEq(token.balanceOf(owner1), 900 ether);
        assertEq(token.balanceOf(owner2), 0);
        _assertAction(handler, VestingHandler.Action.Create, 1, 1, 0, 0);
        _assertAction(handler, VestingHandler.Action.AdvanceTime, 1, 1, 0, 0);
        _assertAction(handler, VestingHandler.Action.Claim, 2, 2, 0, 0);
        _assertAction(handler, VestingHandler.Action.Revoke, 2, 2, 0, 0);
        _assertAction(handler, VestingHandler.Action.TransferOwnership, 1, 1, 0, 0);
        _assertAction(handler, VestingHandler.Action.RejectClaim, 1, 0, 1, 0);
        _assertAction(handler, VestingHandler.Action.RejectRevoke, 1, 0, 1, 0);
        handler.assertModel();
    }

    /// @notice 일정 생성 한도를 넘은 선택은 새 예치·성공 대신 한도 사유의 건너뜀으로 기록된다.
    function test_HandlerScheduleLimitIsRecordedAsSkip() public {
        VestingHandler handler = _deployHandler(false);
        uint256[5] memory raw = [uint256(1), uint256(1), uint256(0), uint256(0), uint256(0)];
        for (uint256 i; i < 7; ++i) {
            handler.createSchedule(raw);
        }

        assertEq(handler.scheduleCount(), 8);
        assertEq(handler.totalDeposited(), 1_600 ether + 6);
        _assertAction(handler, VestingHandler.Action.Create, 7, 6, 0, 1);
        assertEq(handler.skippedByReason(VestingHandler.SkipReason.ScheduleLimit), 1);
        handler.assertModel();
    }

    /// @notice 전액 수령 후 청구·취소할 일정이 없으면 호출 선택 수와 성공 횟수를 구분한다.
    function test_HandlerNoEligibleSchedulesAreRecordedAsSkips() public {
        VestingHandler handler = _deployHandler(false);
        for (uint256 i; i < 4; ++i) {
            handler.advanceTime(30 days);
        }
        handler.claim(0);
        handler.claim(0);
        handler.claim(0);
        handler.revoke(0);

        _assertAction(handler, VestingHandler.Action.Claim, 3, 2, 0, 1);
        _assertAction(handler, VestingHandler.Action.Revoke, 1, 0, 0, 1);
        assertEq(handler.skippedByReason(VestingHandler.SkipReason.NoClaimableSchedule), 1);
        assertEq(handler.skippedByReason(VestingHandler.SkipReason.NoRevocableSchedule), 1);
        assertEq(handler.outstandingObligation(), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
        handler.assertModel();
    }

    /// @notice 관찰 시각 상한에 도달한 뒤의 시간 선택은 시각을 늘리지 않고 사유를 기록한다.
    function test_HandlerTimeLimitIsRecordedAsSkip() public {
        VestingHandler handler = _deployHandler(false);
        uint256 steps;
        while (handler.expectedTime() < handler.TIME_LIMIT()) {
            handler.advanceTime(30 days);
            ++steps;
        }
        handler.advanceTime(1);

        assertEq(block.timestamp, handler.TIME_LIMIT());
        _assertAction(handler, VestingHandler.Action.AdvanceTime, steps + 1, steps, 0, 1);
        assertEq(handler.skippedByReason(VestingHandler.SkipReason.TimeLimit), 1);
        handler.assertModel();
    }

    /// @notice 순수 환경에서는 직접 입금을 거절하고, 별도 환경에서는 장부 E만 증가한다.
    function test_HandlerDirectDepositPolicyAndLedger() public {
        VestingHandler pureHandler = _deployHandler(false);
        vm.expectRevert(VestingHandler.DirectDepositsDisabled.selector);
        pureHandler.directDeposit(50 ether);
        pureHandler.assertModel();
        _assertAction(pureHandler, VestingHandler.Action.DirectDeposit, 0, 0, 0, 0);

        // 별도 환경은 새 토큰·Vesting·handler로 시작한다. 앞의 환경에 입금 모드를 섞지 않는다.
        vm.warp(START);
        token = new MockERC20();
        vesting = new Vesting(token, owner1);
        VestingHandler directHandler = _deployHandler(true);
        bytes32 beforeDeposit = _pairHash();
        directHandler.directDeposit(50 ether);
        assertEq(_pairHash(), beforeDeposit);
        assertEq(directHandler.outstandingObligation(), 1_600 ether);
        assertEq(directHandler.totalDirectDeposits(), 50 ether);
        assertEq(token.balanceOf(address(vesting)), 1_650 ether);
        _assertAction(directHandler, VestingHandler.Action.DirectDeposit, 1, 1, 0, 0);
        directHandler.assertModel();
    }

    /// @notice 시나리오의 기존 빈 계약을 대상으로 고유한 계정 풀과 원하는 입금 정책의 handler를 만든다.
    /// @param direct 직접 입금 환경인지 정한다.
    /// @return handler 초기 A·B와 독립 장부를 준비한 테스트용 계약이다.
    function _deployHandler(bool direct) internal returns (VestingHandler handler) {
        return new VestingHandler(
            token,
            vesting,
            [owner1, owner2, makeAddr("scenario-owner-3")],
            [beneficiaryA, beneficiaryB, makeAddr("scenario-beneficiary-c")],
            donor,
            direct
        );
    }

    /// @notice 한 행동의 실제 카운터를 손으로 정한 선택·성공·거절·건너뜀과 비교한다.
    /// @param handler 비교할 테스트 장부다.
    /// @param action 비교할 행동 종류다.
    /// @param attempts 기대 선택 횟수다.
    /// @param succeeded 기대 정상 성공 횟수다.
    /// @param rejected 기대 권한 거절 확인 횟수다.
    /// @param skipped 기대 조건 부족 횟수다.
    function _assertAction(
        VestingHandler handler,
        VestingHandler.Action action,
        uint256 attempts,
        uint256 succeeded,
        uint256 rejected,
        uint256 skipped
    ) internal view {
        (uint256 a, uint256 s, uint256 r, uint256 k) = handler.actionStats(action);
        assertEq(a, attempts);
        assertEq(s, succeeded);
        assertEq(r, rejected);
        assertEq(k, skipped);
    }

    /// @notice 고정 예시의 최초 네 단계를 실행하여 A 300·B 400 수령과 반환 200을 준비한다.
    function _prepareThroughFortyDays() internal {
        _createPair(false);
        vm.warp(START + 30 days);
        vm.prank(beneficiaryA);
        assertEq(vesting.claim(0), 300 ether);
        vm.warp(START + 40 days);
        vm.prank(owner1);
        vesting.revoke(1);
        vm.prank(beneficiaryB);
        assertEq(vesting.claim(1), 400 ether);
        _assertPair(300 ether, 400 ether, 0, START + 40 days, 200 ether, 0);
    }

    /// @notice 최초 제공자가 A 1,000·B 600을 정확히 승인·예치하고 독립적인 약정을 만든다.
    /// @param shared 두 일정의 수령자를 같은 주소로 둘지 정한다.
    function _createPair(bool shared) internal {
        receiverB = shared ? beneficiaryA : beneficiaryB;
        token.mint(owner1, 1_600 ether);
        vm.startPrank(owner1);
        token.approve(address(vesting), 1_000 ether);
        assertEq(vesting.createSchedule(beneficiaryA, 1_000 ether, START, 20 days, 100 days), 0);
        token.approve(address(vesting), 600 ether);
        assertEq(vesting.createSchedule(receiverB, 600 ether, START, 0, 60 days), 1);
        vm.stopPrank();
    }

    /// @notice 두 일정의 저장 필드 전체를 인코딩한 해시로 다른 행동의 침범 여부를 비교한다.
    /// @return digest A·B 저장 상태의 결합 해시다. 시간에 따른 조회값은 포함하지 않는다.
    function _pairHash() internal view returns (bytes32 digest) {
        return keccak256(abi.encode(vesting.getSchedule(0), vesting.getSchedule(1)));
    }

    /// @notice 손으로 정한 청구·취소·반환·직접 입금으로 일정 전체와 잔고·공급·승인·ID를 비교한다.
    /// @param claimedA A의 기대 누적 수령액이다.
    /// @param claimedB B의 기대 누적 수령액이다.
    /// @param revokedA A의 기대 취소 시각이며 미취소는 0이다.
    /// @param revokedB B의 기대 취소 시각이며 미취소는 0이다.
    /// @param refunded O1에게 반환한 기대 누적액이다.
    /// @param extra 약정 외 직접 입금의 기대 누적액이다.
    function _assertPair(
        uint256 claimedA,
        uint256 claimedB,
        uint64 revokedA,
        uint64 revokedB,
        uint256 refunded,
        uint256 extra
    ) internal view {
        _assertSchedule(0, claimedA, revokedA);
        _assertSchedule(1, claimedB, revokedB);
        assertEq(token.balanceOf(owner1), refunded);
        assertEq(token.balanceOf(owner2), 0);
        assertEq(token.balanceOf(beneficiaryA), claimedA + (receiverB == beneficiaryA ? claimedB : 0));
        assertEq(token.balanceOf(beneficiaryB), receiverB == beneficiaryB ? claimedB : 0);
        assertEq(token.balanceOf(donor), 0);
        assertEq(token.balanceOf(address(vesting)), 1_600 ether - claimedA - claimedB - refunded + extra);
        assertEq(token.totalSupply(), 1_600 ether + extra);
        assertEq(token.allowance(owner1, address(vesting)), 0);
        assertEq(vesting.nextScheduleId(), 2);
    }

    /// @notice 생성 입력에서 구성한 일정의 아홉 필드를 실제 저장 상태와 비교한다.
    /// @param id 비교할 A 또는 B의 ID다.
    /// @param claimed 기대 누적 청구액이다.
    /// @param revokedAt 기대 취소 시각이다.
    function _assertSchedule(uint256 id, uint256 claimed, uint64 revokedAt) internal view {
        Vesting.Schedule memory expected = Vesting.Schedule({
            beneficiary: id == 0 ? beneficiaryA : receiverB,
            funder: owner1,
            totalAmount: id == 0 ? 1_000 ether : 600 ether,
            claimedAmount: claimed,
            startTime: START,
            cliffDuration: id == 0 ? uint64(20 days) : 0,
            duration: id == 0 ? uint64(100 days) : uint64(60 days),
            revokedAt: revokedAt,
            revoked: revokedAt != 0
        });
        assertEq(abi.encode(vesting.getSchedule(id)), abi.encode(expected), "all schedule fields");
    }
}

/// @notice 두 invariant 환경의 준비·대상 selector 검증·관찰 run 통계 출력을 공유한다.
abstract contract VestingInvariantFixture is Test {
    VestingHandler internal handler;

    /// @notice 새 계약·독립 장부를 만들고 의도한 handler 행동만 Forge 호출 대상으로 등록한다.
    /// @param direct 직접 입금 행동도 허용할지 정한다.
    function _setUpInvariant(bool direct) internal {
        vm.warp(1_700_000_000);
        address[3] memory owners = [makeAddr("owner-1"), makeAddr("owner-2"), makeAddr("owner-3")];
        address[3] memory beneficiaries =
            [makeAddr("beneficiary-1"), makeAddr("beneficiary-2"), makeAddr("beneficiary-3")];
        MockERC20 token = new MockERC20();
        Vesting vesting = new Vesting(token, owners[0]);
        handler = new VestingHandler(token, vesting, owners, beneficiaries, makeAddr("donor"), direct);

        bytes4[] memory selectors = new bytes4[](direct ? 8 : 7);
        selectors[0] = VestingHandler.createSchedule.selector;
        selectors[1] = VestingHandler.advanceTime.selector;
        selectors[2] = VestingHandler.claim.selector;
        selectors[3] = VestingHandler.revoke.selector;
        selectors[4] = VestingHandler.transferOwnership.selector;
        selectors[5] = VestingHandler.rejectUnauthorizedClaim.selector;
        selectors[6] = VestingHandler.rejectUnauthorizedRevoke.selector;
        if (direct) selectors[7] = VestingHandler.directDeposit.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        address[] memory contracts = targetContracts();
        FuzzSelector[] memory configured = targetSelectors();
        assertEq(contracts.length, 1);
        assertEq(contracts[0], address(handler));
        assertEq(configured.length, 1);
        assertEq(configured[0].addr, address(handler));
        assertEq(abi.encode(configured[0].selectors), abi.encode(selectors));
        handler.assertModel();
    }

    /// @notice 종료 hook에서 보이는 run의 선택·성공·거절·건너뜀을 출력한다. 전체 runs 합계라고 가정하지 않는다.
    /// @dev 출력에 보이는 run 수는 실제 실행 로그에서 확인한다. 매 run에 모든 행동이 나와야 한다고 요구하지 않는다.
    function afterInvariant() public view {
        handler.assertModel();
        console2.log("RUN_METRICS_BEGIN");
        uint256 count = handler.ALLOW_DIRECT_DEPOSITS() ? 8 : 7;
        for (uint256 i; i < count; ++i) {
            (uint256 attempts, uint256 succeeded, uint256 rejected, uint256 skipped) =
                handler.actionStats(VestingHandler.Action(i));
            console2.log("ACTION_ATTEMPTS_SUCCESS", i, attempts, succeeded);
            console2.log("ACTION_REJECTED_SKIPPED", i, rejected, skipped);
        }
        for (uint256 i; i < 4; ++i) {
            console2.log("SKIP_REASON", i, handler.skippedByReason(VestingHandler.SkipReason(i)));
        }
        console2.log("RUN_METRICS_END");
    }
}

/// @notice 직접 입금이 없는 상태에서 여러 일정의 의무·실제 자금·권한을 같은 행동열에서 확인한다.
contract VestingInvariantTest is VestingInvariantFixture {
    /// @notice 순수 입출금 환경의 독립 계약·장부·허용 행동을 준비한다.
    function setUp() public {
        _setUpInvariant(false);
    }

    /// @notice 매 무작위 행동 뒤 모든 일정·자금·계정·통계의 독립 모델이 맞아야 한다.
    function invariant_AllSchedulesAndAssetsMatchModel() public view {
        handler.assertModel();
    }
}

/// @notice 직접 입금 E를 별도로 허용하여 잔고가 의무보다 E만큼 큰 환경을 확인한다.
contract VestingInvariantDirectDepositTest is VestingInvariantFixture {
    /// @notice 새 계약·장부에서 직접 입금 selector까지 포함한 별도 환경을 준비한다.
    function setUp() public {
        _setUpInvariant(true);
    }

    /// @notice 직접 입금이 약정을 바꾸지 않고 실제 잔고와 의무의 차이 E로만 남아야 한다.
    function invariant_AllSchedulesAndAssetsMatchModel() public view {
        handler.assertModel();
    }
}
