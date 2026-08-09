// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Vesting} from "../src/Vesting.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VestingTest is Test {
    MockERC20 internal token;
    Vesting internal vesting;

    address internal owner;
    address internal beneficiary;
    address internal stranger;

    uint256 internal constant OWNER_BALANCE = 1_000_000 ether;
    uint256 internal constant TOTAL_AMOUNT = 120_000 ether;
    uint64 internal constant CLIFF_DURATION = 90 days;
    uint64 internal constant DURATION = 365 days;

    function setUp() public {
        owner = makeAddr("owner");
        beneficiary = makeAddr("beneficiary");
        stranger = makeAddr("stranger");

        token = new MockERC20();
        vesting = new Vesting(token, owner);

        token.mint(owner, OWNER_BALANCE);

        vm.prank(owner);
        token.approve(address(vesting), type(uint256).max);
    }

    function test_Constructor_SetsToken() public view {
        assertEq(address(vesting.TOKEN()), address(token));
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(vesting.owner(), owner);
    }

    function test_Constructor_RevertsWhenTokenIsZero() public {
        vm.expectRevert(Vesting.InvalidToken.selector);
        new Vesting(IERC20(address(0)), owner);
    }

    function test_Constructor_RevertsWhenOwnerIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Vesting(token, address(0));
    }

    function test_CreateSchedule_StoresSchedule() public {
        uint64 currentTime = 1_700_000_000;
        vm.warp(currentTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertEq(scheduleId, 0);
        assertEq(vesting.nextScheduleId(), 1);

        assertEq(schedule.beneficiary, beneficiary);
        assertEq(schedule.funder, owner);
        assertEq(schedule.totalAmount, TOTAL_AMOUNT);
        assertEq(schedule.claimedAmount, 0);
        assertEq(schedule.startTime, currentTime);

        assertEq(schedule.cliffDuration, CLIFF_DURATION);

        assertEq(schedule.duration, DURATION);
        assertEq(schedule.revokedAt, 0);
        assertFalse(schedule.revoked);
    }

    function test_CreateSchedule_DepositsTokens() public {
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        assertEq(token.balanceOf(address(vesting)), TOTAL_AMOUNT);

        assertEq(token.balanceOf(owner), ownerBalanceBefore - TOTAL_AMOUNT);
    }

    function test_CreateSchedule_RevertsWhenCallerIsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));

        vm.prank(stranger);
        vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);
    }

    function test_CreateSchedule_RevertsWhenBeneficiaryIsZero() public {
        vm.expectRevert(Vesting.InvalidBeneficiary.selector);

        vm.prank(owner);

        vesting.createSchedule(address(0), TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);
    }

    function test_CreateSchedule_RevertsWhenAmountIsZero() public {
        vm.expectRevert(Vesting.InvalidAmount.selector);

        vm.prank(owner);

        vesting.createSchedule(beneficiary, 0, 0, CLIFF_DURATION, DURATION);
    }

    function test_CreateSchedule_RevertsWhenDurationIsZero() public {
        vm.expectRevert(Vesting.InvalidDuration.selector);

        vm.prank(owner);

        vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, 0, 0);
    }

    function test_CreateSchedule_RevertsWhenCliffExceedsDuration() public {
        vm.expectRevert(Vesting.InvalidCliff.selector);

        vm.prank(owner);

        vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, DURATION + 1, DURATION);
    }

    function test_CreateSchedule_RevertsWithoutAllowance() public {
        vm.prank(owner);
        token.approve(address(vesting), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vesting), 0, TOTAL_AMOUNT)
        );

        vm.prank(owner);
        vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);
    }

    function test_VestedAmount_ReturnsZeroBeforeCliff() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + CLIFF_DURATION - 1);

        uint256 vested = vesting.vestedAmount(scheduleId);
        assertEq(vested, 0);
    }

    function test_VestedAmount_ReturnsAccruedAmountAtCliff() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + CLIFF_DURATION);

        uint256 vested = vesting.vestedAmount(scheduleId);

        uint256 expected = (TOTAL_AMOUNT * CLIFF_DURATION) / DURATION;

        assertEq(vested, expected);
    }

    function test_VestedAmount_ReturnsHalfAtHalfDuration() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 halfDuration = uint256(DURATION) / 2;

        vm.warp(uint256(startTime) + halfDuration);

        uint256 vested = vesting.vestedAmount(scheduleId);

        assertEq(vested, TOTAL_AMOUNT / 2);
    }

    function test_VestedAmount_ReturnsAccruedAmountBeforeEnd() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 elapsed = uint256(DURATION) - 1;

        vm.warp(uint256(startTime) + elapsed);

        uint256 vested = vesting.vestedAmount(scheduleId);

        uint256 expected = (TOTAL_AMOUNT * elapsed) / DURATION;

        assertEq(vested, expected);
        assertLt(vested, TOTAL_AMOUNT);
    }

    function test_VestedAmount_ReturnsTotalAtEnd() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + DURATION);

        uint256 vested = vesting.vestedAmount(scheduleId);

        assertEq(vested, TOTAL_AMOUNT);
    }

    function test_VestedAmount_ReturnsTotalAfterEnd() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + DURATION + 30 days);

        uint256 vested = vesting.vestedAmount(scheduleId);

        assertEq(vested, TOTAL_AMOUNT);
    }

    function test_Claim_TransfersVestedTokens() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 halfDuration = uint256(DURATION) / 2;

        vm.warp(uint256(startTime) + halfDuration);

        uint256 expectedAmount = TOTAL_AMOUNT / 2;

        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);

        uint256 vestingBalanceBefore = token.balanceOf(address(vesting));

        vm.prank(beneficiary);
        uint256 claimedAmount = vesting.claim(scheduleId);

        assertEq(claimedAmount, expectedAmount);

        assertEq(token.balanceOf(beneficiary), beneficiaryBalanceBefore + expectedAmount);

        assertEq(token.balanceOf(address(vesting)), vestingBalanceBefore - expectedAmount);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertEq(schedule.claimedAmount, expectedAmount);

        assertEq(vesting.releasableAmount(scheduleId), 0);
    }

    function test_Claim_RevertsWhenCallerIsNotBeneficiary() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + CLIFF_DURATION);

        vm.expectRevert(Vesting.NotBeneficiary.selector);

        vm.prank(stranger);
        vesting.claim(scheduleId);
    }

    function test_Claim_RevertsBeforeCliff() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + CLIFF_DURATION - 1);

        vm.expectRevert(Vesting.NothingToClaim.selector);

        vm.prank(beneficiary);
        vesting.claim(scheduleId);
    }

    function test_Claim_RevertsWhenNothingNewHasVested() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + uint256(DURATION) / 2);

        vm.prank(beneficiary);
        vesting.claim(scheduleId);

        vm.expectRevert(Vesting.NothingToClaim.selector);

        vm.prank(beneficiary);
        vesting.claim(scheduleId);
    }

    function test_Claim_TransfersOnlyNewlyVestedTokens() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + uint256(DURATION) / 2);

        vm.prank(beneficiary);
        uint256 firstClaim = vesting.claim(scheduleId);

        assertEq(firstClaim, TOTAL_AMOUNT / 2);

        uint256 threeQuarterDuration = uint256(DURATION) * 3 / 4;

        vm.warp(uint256(startTime) + threeQuarterDuration);

        vm.prank(beneficiary);
        uint256 secondClaim = vesting.claim(scheduleId);

        assertEq(secondClaim, TOTAL_AMOUNT / 4);

        assertEq(token.balanceOf(beneficiary), TOTAL_AMOUNT * 3 / 4);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertEq(schedule.claimedAmount, TOTAL_AMOUNT * 3 / 4);

        assertEq(vesting.releasableAmount(scheduleId), 0);
    }

    function test_Claim_TransfersRemainingTokensAtEnd() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 threeQuarterDuration = uint256(DURATION) * 3 / 4;

        vm.warp(uint256(startTime) + threeQuarterDuration);

        vm.prank(beneficiary);
        uint256 firstClaim = vesting.claim(scheduleId);

        assertEq(firstClaim, TOTAL_AMOUNT * 3 / 4);

        vm.warp(uint256(startTime) + DURATION);

        vm.prank(beneficiary);
        uint256 finalClaim = vesting.claim(scheduleId);

        assertEq(finalClaim, TOTAL_AMOUNT / 4);

        assertEq(token.balanceOf(beneficiary), TOTAL_AMOUNT);

        assertEq(token.balanceOf(address(vesting)), 0);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertEq(schedule.claimedAmount, TOTAL_AMOUNT);

        assertEq(vesting.releasableAmount(scheduleId), 0);
    }

    function test_Claim_RevertsWhenScheduleDoesNotExist() public {
        uint256 missingScheduleId = 0;

        vm.expectRevert(abi.encodeWithSelector(Vesting.ScheduleNotFound.selector, missingScheduleId));

        vm.prank(beneficiary);
        vesting.claim(missingScheduleId);
    }

    function test_Revoke_RefundsUnvestedTokens() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 halfDuration = uint256(DURATION) / 2;

        uint256 revokeTime = uint256(startTime) + halfDuration;

        vm.warp(revokeTime);

        uint256 expectedVested = TOTAL_AMOUNT / 2;

        uint256 expectedRefund = TOTAL_AMOUNT - expectedVested;

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + expectedRefund);

        assertEq(token.balanceOf(address(vesting)), expectedVested);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertTrue(schedule.revoked);

        assertEq(schedule.revokedAt, revokeTime);

        assertEq(schedule.claimedAmount, 0);

        assertEq(vesting.vestedAmount(scheduleId), expectedVested);
    }

    function test_Revoke_FreezesVestingAtRevocationTime() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 halfDuration = uint256(DURATION) / 2;

        uint256 revokeTime = uint256(startTime) + halfDuration;

        vm.warp(revokeTime);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        vm.warp(uint256(startTime) + DURATION + 30 days);

        uint256 vested = vesting.vestedAmount(scheduleId);

        assertEq(vested, TOTAL_AMOUNT / 2);

        assertEq(vesting.releasableAmount(scheduleId), TOTAL_AMOUNT / 2);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertTrue(schedule.revoked);
        assertEq(schedule.revokedAt, revokeTime);
    }

    function test_Revoke_AllowsClaimingVestedTokens() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 halfDuration = uint256(DURATION) / 2;

        vm.warp(uint256(startTime) + halfDuration);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        vm.warp(uint256(startTime) + DURATION + 30 days);

        vm.prank(beneficiary);
        uint256 claimedAmount = vesting.claim(scheduleId);

        assertEq(claimedAmount, TOTAL_AMOUNT / 2);

        assertEq(token.balanceOf(beneficiary), TOTAL_AMOUNT / 2);

        assertEq(token.balanceOf(address(vesting)), 0);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertEq(schedule.claimedAmount, TOTAL_AMOUNT / 2);

        assertEq(vesting.releasableAmount(scheduleId), 0);
    }

    function test_Revoke_RevertsWhenCallerIsNotOwner() public {
        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));

        vm.prank(stranger);
        vesting.revoke(scheduleId);
    }

    function test_Revoke_RevertsWhenAlreadyRevoked() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + uint256(DURATION) / 2);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        vm.expectRevert(Vesting.AlreadyRevoked.selector);

        vm.prank(owner);
        vesting.revoke(scheduleId);
    }

    function test_Revoke_RevertsWhenNothingIsLeftToRevoke() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        vm.warp(uint256(startTime) + DURATION);

        vm.expectRevert(Vesting.NothingToRevoke.selector);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertFalse(schedule.revoked);
    }

    function test_Revoke_RefundsAllTokensBeforeCliff() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        uint256 revokeTime = uint256(startTime) + CLIFF_DURATION - 1;

        vm.warp(revokeTime);

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + TOTAL_AMOUNT);

        assertEq(token.balanceOf(address(vesting)), 0);

        assertEq(token.balanceOf(beneficiary), 0);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertTrue(schedule.revoked);
        assertEq(schedule.revokedAt, revokeTime);

        assertEq(vesting.vestedAmount(scheduleId), 0);

        assertEq(vesting.releasableAmount(scheduleId), 0);
    }

    function test_Revoke_AccountsForPreviouslyClaimedTokens() public {
        uint64 startTime = 1_700_000_000;
        vm.warp(startTime);

        vm.prank(owner);
        uint256 scheduleId = vesting.createSchedule(beneficiary, TOTAL_AMOUNT, 0, CLIFF_DURATION, DURATION);

        // 50% 시점에 첫 claim
        vm.warp(uint256(startTime) + uint256(DURATION) / 2);

        vm.prank(beneficiary);
        uint256 firstClaim = vesting.claim(scheduleId);

        assertEq(firstClaim, TOTAL_AMOUNT / 2);

        // 75% 시점에 revoke
        uint256 revokeTime = uint256(startTime) + uint256(DURATION) * 3 / 4;

        vm.warp(revokeTime);

        uint256 expectedVested = TOTAL_AMOUNT * 3 / 4;

        uint256 expectedRefund = TOTAL_AMOUNT - expectedVested;

        uint256 expectedRemainingClaim = expectedVested - firstClaim;

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vesting.revoke(scheduleId);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + expectedRefund);

        assertEq(token.balanceOf(address(vesting)), expectedRemainingClaim);

        assertEq(token.balanceOf(beneficiary), firstClaim);

        Vesting.Schedule memory schedule = vesting.getSchedule(scheduleId);

        assertTrue(schedule.revoked);

        assertEq(schedule.claimedAmount, firstClaim);

        assertEq(vesting.releasableAmount(scheduleId), expectedRemainingClaim);

        // 시간이 더 지나도 75%에서 고정
        vm.warp(uint256(startTime) + DURATION + 30 days);

        vm.prank(beneficiary);
        uint256 finalClaim = vesting.claim(scheduleId);

        assertEq(finalClaim, expectedRemainingClaim);

        assertEq(token.balanceOf(beneficiary), expectedVested);

        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_Revoke_RevertsWhenScheduleDoesNotExist() public {
        uint256 missingScheduleId = 0;

        vm.expectRevert(abi.encodeWithSelector(Vesting.ScheduleNotFound.selector, missingScheduleId));

        vm.prank(owner);
        vesting.revoke(missingScheduleId);
    }
}
