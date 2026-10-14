// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vesting} from "../src/Vesting.sol";
import {RevertingERC20} from "./mocks/RevertingERC20.sol";
import {DepositRevertingERC20} from "./mocks/DepositRevertingERC20.sol";
import {FalseReturnERC20} from "./mocks/FalseReturnERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {DecreasingBalanceERC20} from "./mocks/DecreasingBalanceERC20.sol";
import {NoReturnERC20} from "./mocks/NoReturnERC20.sol";

contract VestingTokenBehaviorTest is Test {
    uint64 internal constant START_TIME = 1_700_000_000;
    uint64 internal constant CLIFF_DURATION = 20 days;
    uint64 internal constant DURATION = 100 days;
    uint256 internal constant TOTAL_AMOUNT = 1_000 ether;

    address internal owner;
    address internal beneficiary;
    address internal feeRecipient;
    address internal newOwner;

    struct StateSnapshot {
        bytes schedule;
        uint256 nextScheduleId;
        uint256 ownerBalance;
        uint256 beneficiaryBalance;
        uint256 vestingBalance;
        uint256 allowance;
        uint256 totalSupply;
        uint256 extraBalance;
        address vestingOwner;
    }

    function setUp() public {
        vm.warp(START_TIME);
        owner = makeAddr("owner");
        beneficiary = makeAddr("beneficiary");
        feeRecipient = makeAddr("feeRecipient");
        newOwner = makeAddr("newOwner");
    }

    /// @notice 취소 반환이 revert하면 취소 기록과 모든 관련 잔고가 되돌아간다.
    function test_RevokePreservesStateWhenRefundReverts() public {
        (RevertingERC20 token, Vesting vesting) = _prepareRevertingSchedule();
        _claimAtDay40(vesting);
        _moveToDay(60);
        token.setRevertTransfers(true);

        _assertRevokeFailure(vesting, token, abi.encodeWithSelector(RevertingERC20.TransferRevertedForTest.selector));
        assertTrue(token.revertTransfers());
    }

    /// @notice 취소 실패를 해제하고 같은 60일에 재시도하면 제공자에게 400토큰을 반환한다.
    function test_RevokeCanRetryAtSameTimeAfterRefundRevert() public {
        (RevertingERC20 token, Vesting vesting) = _prepareRevertingSchedule();
        _claimAtDay40(vesting);
        _moveToDay(60);
        token.setRevertTransfers(true);
        _assertRevokeFailure(vesting, token, abi.encodeWithSelector(RevertingERC20.TransferRevertedForTest.selector));

        token.setRevertTransfers(false);
        _revokeAndClaimRemainder(vesting, token, owner, 60, 400 ether, 200 ether);
    }

    /// @notice 60일의 취소 실패 후 70일에 성공하면 제공자와 수령자에게 각각 300토큰이 남는다.
    function test_RevokeUsesSuccessfulRetryTimeAfterRefundRevert() public {
        (RevertingERC20 token, Vesting vesting) = _prepareRevertingSchedule();
        _claimAtDay40(vesting);
        _moveToDay(60);
        token.setRevertTransfers(true);
        _assertRevokeFailure(vesting, token, abi.encodeWithSelector(RevertingERC20.TransferRevertedForTest.selector));

        token.setRevertTransfers(false);
        _moveToDay(70);
        _revokeAndClaimRemainder(vesting, token, owner, 70, 300 ether, 300 ether);
    }

    /// @notice 생성 전송이 revert하면 잔고와 유한 승인량을 보존하고 같은 승인으로 재시도할 수 있다.
    function test_CreateCanRetryAfterDepositRevert() public {
        DepositRevertingERC20 token = new DepositRevertingERC20();
        Vesting vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);
        vm.prank(owner);
        token.approve(address(vesting), TOTAL_AMOUNT);
        token.setRevertDeposits(true);

        _assertCreationFailure(
            vesting, token, TOTAL_AMOUNT, abi.encodeWithSelector(DepositRevertingERC20.DepositRevertedForTest.selector)
        );
        assertTrue(token.revertDeposits());
        assertEq(token.balanceOf(owner), TOTAL_AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.allowance(owner, address(vesting)), TOTAL_AMOUNT);

        token.setRevertDeposits(false);
        assertEq(_createUsingApproval(vesting, token, TOTAL_AMOUNT), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
    }

    /// @notice 생성 전송의 false를 SafeERC20이 거절하며 토큰 잔고와 승인량까지 되돌린다.
    function test_CreateCanRetryAfterFalseReturn() public {
        FalseReturnERC20 token = new FalseReturnERC20();
        Vesting vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);
        vm.prank(owner);
        token.approve(address(vesting), TOTAL_AMOUNT);
        token.setFalseTransferFrom(true);

        _assertCreationFailure(vesting, token, TOTAL_AMOUNT, _safeErc20Error(token));
        assertTrue(token.falseTransferFrom());
        assertEq(token.balanceOf(owner), TOTAL_AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.allowance(owner, address(vesting)), TOTAL_AMOUNT);

        token.setFalseTransferFrom(false);
        assertEq(_createUsingApproval(vesting, token, TOTAL_AMOUNT), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
    }

    /// @notice 청구 전송의 false로 실패하면 300토큰 수령 상태를 보존하고 재시도 시 100토큰만 추가한다.
    function test_ClaimCanRetryAfterFalseReturn() public {
        (FalseReturnERC20 token, Vesting vesting) = _prepareFalseReturnSchedule();
        _moveToDay(30);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 300 ether);
        _moveToDay(40);
        token.setFalseTransfers(true);
        StateSnapshot memory beforeState = _snapshot(vesting, token, newOwner);

        vm.expectRevert(_safeErc20Error(token));
        vm.prank(beneficiary);
        vesting.claim(0);

        _assertStatePreserved(vesting, token, newOwner, beforeState);
        assertEq(vesting.getSchedule(0).claimedAmount, 300 ether);
        assertEq(token.balanceOf(beneficiary), 300 ether);
        assertEq(token.balanceOf(address(vesting)), 700 ether);
        assertEq(vesting.vestedAmount(0), 400 ether);
        assertEq(vesting.releasableAmount(0), 100 ether);
        assertTrue(token.falseTransfers());

        token.setFalseTransfers(false);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 100 ether);
        assertEq(vesting.getSchedule(0).claimedAmount, 400 ether);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
        assertEq(vesting.releasableAmount(0), 0);
        StateSnapshot memory afterRetry = _snapshot(vesting, token, newOwner);
        vm.expectRevert(Vesting.NothingToClaim.selector);
        vm.prank(beneficiary);
        vesting.claim(0);
        _assertStatePreserved(vesting, token, newOwner, afterRetry);
    }

    /// @notice 취소 반환의 false로 실패해도 같은 60일에 재시도하면 반환 400과 미수령 200을 확정한다.
    function test_RevokeCanRetryAtSameTimeAfterFalseReturn() public {
        (FalseReturnERC20 token, Vesting vesting) = _prepareFalseReturnSchedule();
        _claimAtDay40(vesting);
        _moveToDay(60);
        token.setFalseTransfers(true);
        _assertRevokeFailure(vesting, token, _safeErc20Error(token));
        assertTrue(token.falseTransfers());

        token.setFalseTransfers(false);
        _revokeAndClaimRemainder(vesting, token, owner, 60, 400 ether, 200 ether);
    }

    /// @notice false로 실패한 60일 취소는 시각을 고정하지 않으며 70일 성공 기준으로 계산한다.
    function test_RevokeUsesSuccessfulRetryTimeAfterFalseReturn() public {
        (FalseReturnERC20 token, Vesting vesting) = _prepareFalseReturnSchedule();
        _claimAtDay40(vesting);
        _moveToDay(60);
        token.setFalseTransfers(true);
        _assertRevokeFailure(vesting, token, _safeErc20Error(token));
        assertTrue(token.falseTransfers());

        token.setFalseTransfers(false);
        _moveToDay(70);
        _revokeAndClaimRemainder(vesting, token, owner, 70, 300 ether, 300 ether);
    }

    /// @notice false 자체는 롤백이 아니므로 직접 전송에서 false를 받아들이면 잔고 변경이 남는다.
    function test_DirectFalseReturnDoesNotRollbackByItself() public {
        FalseReturnERC20 token = new FalseReturnERC20();
        token.mint(owner, TOTAL_AMOUNT);
        token.setFalseTransfers(true);
        vm.prank(owner);
        bool success = token.transfer(beneficiary, 100 ether);

        assertFalse(success);
        assertEq(token.balanceOf(owner), 900 ether);
        assertEq(token.balanceOf(beneficiary), 100 ether);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
        assertTrue(token.falseTransfers());
    }

    /// @notice 1000 중 990만 입금되면 수수료 이동까지 되돌리고 수수료 해제 후 전액 예치한다.
    function test_CreateRejectsDepositFeeAndCanRetry() public {
        FeeOnTransferERC20 token = new FeeOnTransferERC20(feeRecipient);
        Vesting vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);
        vm.prank(owner);
        token.approve(address(vesting), TOTAL_AMOUNT);
        token.setChargeDepositFee(true);

        _assertCreationFailure(
            vesting,
            token,
            TOTAL_AMOUNT,
            abi.encodeWithSelector(Vesting.UnsupportedToken.selector, TOTAL_AMOUNT, 990 ether)
        );
        assertTrue(token.chargeDepositFee());
        assertEq(token.balanceOf(owner), TOTAL_AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.balanceOf(feeRecipient), 0);
        assertEq(token.allowance(owner, address(vesting)), TOTAL_AMOUNT);

        token.setChargeDepositFee(false);
        assertEq(_createUsingApproval(vesting, token, TOTAL_AMOUNT), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(feeRecipient), 0);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);
    }

    /// @notice 입금 후 잔고가 감소하면 기존 일정과 소각·승인량을 보존하고 새 ID를 소비하지 않는다.
    function test_CreateRejectsDecreasedBalanceAndPreservesExistingSchedule() public {
        DecreasingBalanceERC20 token = new DecreasingBalanceERC20();
        Vesting vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);
        _createSchedule(vesting, token, TOTAL_AMOUNT);
        Vesting.Schedule memory existing = vesting.getSchedule(0);
        token.mint(owner, 100 ether);
        vm.prank(owner);
        token.approve(address(vesting), 100 ether);
        token.setDecreaseOnDeposit(true);

        _assertCreationFailure(
            vesting, token, 100 ether, abi.encodeWithSelector(Vesting.UnsupportedToken.selector, 100 ether, 0)
        );
        assertTrue(token.decreaseOnDeposit());
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.balanceOf(address(vesting)), TOTAL_AMOUNT);
        assertEq(token.totalSupply(), 1_100 ether);
        assertEq(token.allowance(owner, address(vesting)), 100 ether);

        token.setDecreaseOnDeposit(false);
        assertEq(_createUsingApproval(vesting, token, 100 ether), 1);
        assertEq(abi.encode(vesting.getSchedule(0)), abi.encode(existing));
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(address(vesting)), 1_100 ether);
        assertEq(token.totalSupply(), 1_100 ether);
    }

    /// @notice 반환값 없는 토큰의 승인·전송·승인 전송이 실제로 빈 반환 데이터를 낸다.
    function test_NoReturnTokenActuallyReturnsEmptyData() public {
        NoReturnERC20 token = new NoReturnERC20();
        token.mint(owner, 100 ether);
        vm.prank(owner);
        (bool approved, bytes memory approveData) =
            address(token).call(abi.encodeCall(NoReturnERC20.approve, (address(this), 100 ether)));
        assertTrue(approved);
        assertEq(approveData.length, 0);
        assertEq(token.allowance(owner, address(this)), 100 ether);

        (bool deposited, bytes memory depositData) =
            address(token).call(abi.encodeCall(NoReturnERC20.transferFrom, (owner, address(this), 100 ether)));
        assertTrue(deposited);
        assertEq(depositData.length, 0);
        assertEq(token.allowance(owner, address(this)), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(address(this)), 100 ether);

        (bool transferred, bytes memory transferData) =
            address(token).call(abi.encodeCall(NoReturnERC20.transfer, (beneficiary, 100 ether)));
        assertTrue(transferred);
        assertEq(transferData.length, 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(beneficiary), 100 ether);
        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.decimals(), 18);
    }

    /// @notice 반환값 없는 토큰도 정상 예치·추가 청구·취소 반환·취소 후 청구가 가능하다.
    function test_NoReturnTokenSupportsDepositClaimAndRevoke() public {
        NoReturnERC20 token = new NoReturnERC20();
        IERC20 asset = IERC20(address(token));
        Vesting vesting = new Vesting(asset, owner);
        token.mint(owner, TOTAL_AMOUNT);
        vm.prank(owner);
        token.approve(address(vesting), TOTAL_AMOUNT);
        _createUsingApproval(vesting, asset, TOTAL_AMOUNT);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);

        _moveToDay(30);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 300 ether);
        assertEq(vesting.getSchedule(0).claimedAmount, 300 ether);
        assertEq(token.balanceOf(beneficiary), 300 ether);
        assertEq(token.balanceOf(address(vesting)), 700 ether);
        _moveToDay(40);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 100 ether);
        assertEq(vesting.getSchedule(0).claimedAmount, 400 ether);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
        _moveToDay(60);
        _revokeAndClaimRemainder(vesting, asset, owner, 60, 400 ether, 200 ether);
    }

    /// @notice 소유권 이전 후 취소 권한은 새 관리자에게 있고 반환 대상은 최초 제공자이다.
    function test_RevokeAfterOwnershipTransferRefundsOriginalFunder() public {
        (RevertingERC20 token, Vesting vesting) = _prepareRevertingSchedule();
        _claimAtDay40(vesting);
        vm.prank(owner);
        vesting.transferOwnership(newOwner);
        _moveToDay(60);
        StateSnapshot memory beforeState = _snapshot(vesting, token, newOwner);
        assertEq(vesting.owner(), newOwner);
        assertEq(vesting.getSchedule(0).funder, owner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        vesting.revoke(0);
        _assertStatePreserved(vesting, token, newOwner, beforeState);
        assertEq(vesting.owner(), newOwner);

        _revokeAndClaimRemainder(vesting, token, newOwner, 60, 400 ether, 200 ether);
        assertEq(vesting.owner(), newOwner);
        assertEq(vesting.getSchedule(0).funder, owner);
    }

    function _prepareRevertingSchedule() internal returns (RevertingERC20 token, Vesting vesting) {
        token = new RevertingERC20();
        vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);
        _createSchedule(vesting, token, TOTAL_AMOUNT);
    }

    function _prepareFalseReturnSchedule() internal returns (FalseReturnERC20 token, Vesting vesting) {
        token = new FalseReturnERC20();
        vesting = new Vesting(token, owner);
        token.mint(owner, TOTAL_AMOUNT);
        _createSchedule(vesting, token, TOTAL_AMOUNT);
    }

    function _createSchedule(Vesting vesting, IERC20 token, uint256 amount) internal returns (uint256 id) {
        vm.prank(owner);
        token.approve(address(vesting), amount);
        return _createUsingApproval(vesting, token, amount);
    }

    function _createUsingApproval(Vesting vesting, IERC20 token, uint256 amount) internal returns (uint256 id) {
        uint256 nextId = vesting.nextScheduleId();
        uint256 balanceBefore = token.balanceOf(address(vesting));
        vm.prank(owner);
        id = vesting.createSchedule(beneficiary, amount, 0, CLIFF_DURATION, DURATION);

        assertEq(id, nextId);
        assertEq(vesting.nextScheduleId(), nextId + 1);
        assertEq(token.balanceOf(address(vesting)), balanceBefore + amount);
        assertEq(token.allowance(owner, address(vesting)), 0);
        Vesting.Schedule memory schedule = vesting.getSchedule(id);
        assertEq(schedule.beneficiary, beneficiary);
        assertEq(schedule.funder, owner);
        assertEq(schedule.totalAmount, amount);
        assertEq(schedule.claimedAmount, 0);
        assertEq(schedule.startTime, block.timestamp);
        assertEq(schedule.cliffDuration, CLIFF_DURATION);
        assertEq(schedule.duration, DURATION);
        assertFalse(schedule.revoked);
        assertEq(schedule.revokedAt, 0);
    }

    function _assertCreationFailure(Vesting vesting, IERC20 token, uint256 amount, bytes memory expectedError)
        internal
    {
        StateSnapshot memory beforeState = _snapshot(vesting, token, feeRecipient);
        assertEq(token.allowance(owner, address(vesting)), amount);
        vm.expectRevert(expectedError);
        vm.prank(owner);
        vesting.createSchedule(beneficiary, amount, 0, CLIFF_DURATION, DURATION);

        _assertStatePreserved(vesting, token, feeRecipient, beforeState);
        vm.expectRevert(abi.encodeWithSelector(Vesting.ScheduleNotFound.selector, beforeState.nextScheduleId));
        vesting.getSchedule(beforeState.nextScheduleId);
    }

    function _safeErc20Error(IERC20 token) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token));
    }

    function _claimAtDay40(Vesting vesting) internal {
        _moveToDay(40);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 400 ether);
    }

    function _assertRevokeFailure(Vesting vesting, IERC20 token, bytes memory expectedError) internal {
        StateSnapshot memory beforeState = _snapshot(vesting, token, newOwner);
        assertEq(vesting.getSchedule(0).claimedAmount, 400 ether);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), 600 ether);
        assertEq(token.balanceOf(owner), 0);
        assertFalse(vesting.getSchedule(0).revoked);
        assertEq(vesting.getSchedule(0).revokedAt, 0);
        assertEq(vesting.vestedAmount(0), 600 ether);

        vm.expectRevert(expectedError);
        vm.prank(owner);
        vesting.revoke(0);

        _assertStatePreserved(vesting, token, newOwner, beforeState);
        assertEq(vesting.vestedAmount(0), 600 ether);
        assertEq(vesting.releasableAmount(0), 200 ether);
    }

    function _revokeAndClaimRemainder(
        Vesting vesting,
        IERC20 token,
        address caller,
        uint256 day,
        uint256 refund,
        uint256 remainder
    ) internal {
        Vesting.Schedule memory beforeSchedule = vesting.getSchedule(0);
        assertEq(block.timestamp, uint256(START_TIME) + day * 1 days);
        vm.prank(caller);
        vesting.revoke(0);

        Vesting.Schedule memory expectedSchedule = beforeSchedule;
        expectedSchedule.revoked = true;
        expectedSchedule.revokedAt = uint64(block.timestamp);
        assertEq(abi.encode(vesting.getSchedule(0)), abi.encode(expectedSchedule));
        assertEq(token.balanceOf(owner), refund);
        assertEq(token.balanceOf(newOwner), 0);
        assertEq(token.balanceOf(beneficiary), 400 ether);
        assertEq(token.balanceOf(address(vesting)), remainder);
        assertEq(vesting.vestedAmount(0), 400 ether + remainder);
        assertEq(vesting.releasableAmount(0), remainder);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(token.totalSupply(), TOTAL_AMOUNT);

        // 실패한 취소는 지급 시각을 고정하지 않고, 성공한 취소는 이후 지급액을 계속 고정해야 한다.
        _moveToDay(100);
        assertEq(vesting.vestedAmount(0), 400 ether + remainder);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), remainder);
        assertEq(vesting.getSchedule(0).claimedAmount, 400 ether + remainder);
        assertEq(token.balanceOf(beneficiary), 400 ether + remainder);
        assertEq(token.balanceOf(owner), refund);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.releasableAmount(0), 0);

        StateSnapshot memory afterFinalClaim = _snapshot(vesting, token, newOwner);
        vm.expectRevert(Vesting.NothingToClaim.selector);
        vm.prank(beneficiary);
        vesting.claim(0);
        _assertStatePreserved(vesting, token, newOwner, afterFinalClaim);
    }

    function _snapshot(Vesting vesting, IERC20 token, address extra)
        internal
        view
        returns (StateSnapshot memory state)
    {
        state.nextScheduleId = vesting.nextScheduleId();
        // 각 테스트 상황에서 검증 대상 함수를 실행하기 전에 존재하는 일정은 최대 하나다.
        if (state.nextScheduleId != 0) state.schedule = abi.encode(vesting.getSchedule(0));
        state.ownerBalance = token.balanceOf(owner);
        state.beneficiaryBalance = token.balanceOf(beneficiary);
        state.vestingBalance = token.balanceOf(address(vesting));
        state.allowance = token.allowance(owner, address(vesting));
        state.totalSupply = token.totalSupply();
        state.extraBalance = token.balanceOf(extra);
        state.vestingOwner = vesting.owner();
    }

    function _assertStatePreserved(Vesting vesting, IERC20 token, address extra, StateSnapshot memory beforeState)
        internal
        view
    {
        StateSnapshot memory afterState = _snapshot(vesting, token, extra);
        assertEq(afterState.schedule, beforeState.schedule);
        assertEq(afterState.nextScheduleId, beforeState.nextScheduleId);
        assertEq(afterState.ownerBalance, beforeState.ownerBalance);
        assertEq(afterState.beneficiaryBalance, beforeState.beneficiaryBalance);
        assertEq(afterState.vestingBalance, beforeState.vestingBalance);
        assertEq(afterState.allowance, beforeState.allowance);
        assertEq(afterState.totalSupply, beforeState.totalSupply);
        assertEq(afterState.extraBalance, beforeState.extraBalance);
        assertEq(afterState.vestingOwner, beforeState.vestingOwner);
    }

    function _moveToDay(uint256 day) internal {
        vm.warp(uint256(START_TIME) + day * 1 days);
    }
}
