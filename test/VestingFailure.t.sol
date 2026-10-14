// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Vesting} from "../src/Vesting.sol";
import {RevertingERC20} from "./mocks/RevertingERC20.sol";

contract VestingFailureTest is Test {
    uint64 internal constant START_TIME = 1_700_000_000;
    uint64 internal constant CLIFF_DURATION = 20 days;
    uint64 internal constant DURATION = 100 days;
    uint256 internal constant TOTAL_AMOUNT = 1_000 ether;

    RevertingERC20 internal token;
    Vesting internal vesting;
    address internal owner;
    address internal beneficiary;
    uint256 internal scheduleId;
    uint256 internal firstClaim;

    function setUp() public {
        vm.warp(START_TIME);
        owner = makeAddr("owner");
        beneficiary = makeAddr("beneficiary");

        token = new RevertingERC20();
        vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);

        vm.startPrank(owner);
        token.approve(address(vesting), TOTAL_AMOUNT);
        scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);
        vm.stopPrank();

        vm.warp(uint256(START_TIME) + 30 days);
        vm.prank(beneficiary);
        firstClaim = vesting.claim(scheduleId);
    }

    /// @notice 정상 예치와 30일째 첫 청구 후 일정과 잔고가 올바르게 저장된다.
    function test_MockSupportsDepositAndInitialClaim() public view {
        assertFalse(token.revertTransfers());
        assertEq(token.decimals(), 18);
        assertEq(firstClaim, 300 ether);
        assertEq(scheduleId, 0);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(beneficiary), 300 ether);
        assertEq(token.balanceOf(address(vesting)), 700 ether);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);
        assertEq(schedule.beneficiary, beneficiary);
        assertEq(schedule.funder, owner);
        assertEq(schedule.totalAmount, TOTAL_AMOUNT);
        assertEq(schedule.claimedAmount, 300 ether);
        assertEq(schedule.startTime, START_TIME);
        assertEq(schedule.cliffDuration, CLIFF_DURATION);
        assertEq(schedule.duration, DURATION);
        assertFalse(schedule.revoked);
        assertEq(schedule.revokedAt, 0);
    }

    /// @notice 전송 실패 설정이 꺼져 있으면 40일째 추가 100토큰을 수령한다.
    function test_ClaimSucceedsWhenTransferFailureIsDisabled() public {
        _moveToDay40();

        vm.prank(beneficiary);
        uint256 amount = vesting.claim(scheduleId);

        assertEq(amount, 100 ether);
        assertEq(vesting.getSchedule(scheduleId).claimedAmount, 400 ether);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
        assertEq(vesting.releasableAmount(scheduleId), 0);
    }

    /// @notice 토큰 전송이 실패하면 일정과 잔고가 청구 직전 상태로 유지된다.
    function test_ClaimPreservesStateWhenTokenTransferReverts() public {
        _moveToDay40();
        _assertFailedClaimPreservesState();
    }

    /// @notice 실패 설정을 끄면 같은 시점에 재청구할 수 있고 중복 청구는 거절된다.
    function test_ClaimCanRetryAfterTransferFailureIsDisabled() public {
        _moveToDay40();
        _assertFailedClaimPreservesState();

        token.setRevertTransfers(false);
        assertFalse(token.revertTransfers());

        vm.prank(beneficiary);
        uint256 amount = vesting.claim(scheduleId);

        assertEq(block.timestamp, uint256(START_TIME) + 40 days);
        assertEq(amount, 100 ether);
        assertEq(vesting.getSchedule(scheduleId).claimedAmount, 400 ether);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
        assertEq(vesting.releasableAmount(scheduleId), 0);

        vm.expectRevert(Vesting.NothingToClaim.selector);
        vm.prank(beneficiary);
        vesting.claim(scheduleId);

        assertEq(vesting.getSchedule(scheduleId).claimedAmount, 400 ether);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
    }

    /// @notice 전송 실패 설정이 켜져 있어도 토큰 발행과 새 일정 예치는 정상 동작한다.
    function test_TransferFailureDoesNotAffectMintOrTransferFrom() public {
        token.setRevertTransfers(true);
        token.mint(owner, 100 ether);
        assertEq(token.balanceOf(owner), 100 ether);

        vm.startPrank(owner);
        token.approve(address(vesting), 100 ether);
        uint256 newScheduleId = vesting.createSchedule(beneficiary, 100 ether, 0, CLIFF_DURATION, DURATION);
        vm.stopPrank();

        assertTrue(token.revertTransfers());
        assertEq(newScheduleId, 1);
        assertEq(vesting.nextScheduleId(), 2);
        assertEq(token.totalSupply(), 1_100 ether);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(beneficiary), 300 ether);
        assertEq(token.balanceOf(address(vesting)), 800 ether);
        assertEq(vesting.getSchedule(scheduleId).claimedAmount, 300 ether);
        assertEq(vesting.getSchedule(newScheduleId).totalAmount, 100 ether);
        assertEq(vesting.getSchedule(newScheduleId).claimedAmount, 0);
    }

    function _moveToDay40() internal {
        vm.warp(uint256(START_TIME) + 40 days);
        assertEq(vesting.vestedAmount(scheduleId), 400 ether);
        assertEq(vesting.releasableAmount(scheduleId), 100 ether);
        assertEq(token.balanceOf(beneficiary), 300 ether);
        assertEq(token.balanceOf(address(vesting)), 700 ether);
    }

    function _assertFailedClaimPreservesState() internal {
        token.setRevertTransfers(true);

        Vesting.Schedule memory scheduleBefore = vesting.getSchedule(scheduleId);
        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);
        uint256 vestingBalanceBefore = token.balanceOf(address(vesting));
        uint256 nextScheduleIdBefore = vesting.nextScheduleId();
        uint256 totalSupplyBefore = token.totalSupply();

        vm.expectRevert(RevertingERC20.TransferRevertedForTest.selector);
        vm.prank(beneficiary);
        vesting.claim(scheduleId);

        assertEq(abi.encode(vesting.getSchedule(scheduleId)), abi.encode(scheduleBefore));
        assertEq(token.balanceOf(beneficiary), beneficiaryBalanceBefore);
        assertEq(token.balanceOf(address(vesting)), vestingBalanceBefore);
        assertEq(token.balanceOf(owner), 0);
        assertEq(vesting.nextScheduleId(), nextScheduleIdBefore);
        assertEq(token.totalSupply(), totalSupplyBefore);
        assertEq(vesting.getSchedule(scheduleId).claimedAmount, 300 ether);
        assertEq(vesting.vestedAmount(scheduleId), 400 ether);
        assertEq(vesting.releasableAmount(scheduleId), 100 ether);
        assertTrue(token.revertTransfers());
    }
}
