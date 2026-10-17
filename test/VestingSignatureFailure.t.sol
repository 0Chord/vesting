// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Vesting} from "../src/Vesting.sol";
import {SignedVestingTestBase, ISignedVesting} from "./helpers/SignedVestingTestBase.sol";
import {FalseReturnERC20} from "./mocks/FalseReturnERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {DepositRevertingERC20} from "./mocks/DepositRevertingERC20.sol";
import {NoReturnERC20} from "./mocks/NoReturnERC20.sol";
import {CallbackERC20} from "./mocks/CallbackERC20.sol";
import {ReentrantActor} from "./helpers/ReentrantActor.sol";

contract VestingSignatureFailureTest is SignedVestingTestBase {
    /// @notice approve 부족 실패는 승인을 소비하지 않고 보완 뒤 같은 서명으로 새 시각에 시작한다.
    function test_Register_RetriesSameSignatureAfterInsufficientAllowance() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.prank(owner);
        token.approve(address(vesting), 50 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vesting), 50 ether, AMOUNT)
        );
        _submit(a, signature);
        _assertUnregistered(a);
        assertEq(token.allowance(owner, address(vesting)), 50 ether);
        vm.prank(owner);
        token.approve(address(vesting), AMOUNT);
        vm.warp(REGISTERED_AT + 60);
        assertEq(_submit(a, signature), 0);
        assertEq(vesting.getSchedule(0).startTime, REGISTERED_AT + 60);
        assertTrue(vesting.usedAuthorizations(1, 7));
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(token.allowance(owner, address(vesting)), 0);
    }

    /// @notice 잔고 부족은 유한 승인량 소비도 되돌리며 자금 보완 후 원래 서명을 재사용할 수 있다.
    function test_Register_RetriesSameSignatureAfterInsufficientBalance() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.prank(owner);
        assertTrue(token.transfer(makeAddr("other holder"), INITIAL_BALANCE - 50 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 50 ether, AMOUNT));
        _submit(a, signature);
        assertEq(token.allowance(owner, address(vesting)), AMOUNT);
        assertEq(token.balanceOf(owner), 50 ether);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.nextScheduleId(), 0);
        assertFalse(vesting.usedAuthorizations(1, 7));
        token.mint(owner, 50 ether);
        assertEq(_submit(a, signature), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
    }

    /// @notice 미사용 승인이더라도 실패 보완 뒤 등록 마감이 지났으면 재시도를 거절한다.
    function test_Register_FailedAuthorizationStillExpires() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.prank(owner);
        token.approve(address(vesting), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vesting), 0, AMOUNT)
        );
        _submit(a, signature);
        vm.prank(owner);
        token.approve(address(vesting), AMOUNT);
        vm.warp(a.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Vesting.AuthorizationExpired.selector, a.deadline));
        _submit(a, signature);
        _assertUnregistered(a);
        assertEq(token.allowance(owner, address(vesting)), AMOUNT);
    }

    /// @notice 잔고 변경 후 false를 반환해도 사용 기록·잔고·승인량이 모두 복원된다.
    function test_Register_FalseReturnRollsBackAndRetries() public {
        FalseReturnERC20 asset = new FalseReturnERC20();
        _useAsset(asset);
        asset.mint(owner, AMOUNT);
        asset.setFalseTransferFrom(true);
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(asset)));
        _submit(a, signature);
        _assertAlternativePreserved(asset);
        asset.setFalseTransferFrom(false);
        assertEq(_submit(a, signature), 0);
        assertEq(asset.balanceOf(address(vesting)), AMOUNT);
        assertEq(asset.allowance(owner, address(vesting)), 0);
    }

    /// @notice 토큰 자체가 전송 후 revert해도 원래 오류를 전파하고 같은 서명 재시도가 가능하다.
    function test_Register_DepositRevertRollsBackAndRetries() public {
        DepositRevertingERC20 asset = new DepositRevertingERC20();
        _useAsset(asset);
        asset.mint(owner, AMOUNT);
        asset.setRevertDeposits(true);
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(DepositRevertingERC20.DepositRevertedForTest.selector);
        _submit(a, signature);
        _assertAlternativePreserved(asset);
        asset.setRevertDeposits(false);
        assertEq(_submit(a, signature), 0);
        assertEq(asset.balanceOf(address(vesting)), AMOUNT);
    }

    /// @notice 수수료로 전액이 예치되지 않으면 제공자·계약·수수료 잔고와 승인량을 모두 복원한다.
    function test_Register_DepositFeeRollsBackAndRetries() public {
        address feeRecipient = makeAddr("fee recipient");
        FeeOnTransferERC20 asset = new FeeOnTransferERC20(feeRecipient);
        _useAsset(asset);
        asset.mint(owner, AMOUNT);
        asset.setChargeDepositFee(true);
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(Vesting.UnsupportedToken.selector, AMOUNT, 99 ether));
        _submit(a, signature);
        _assertAlternativePreserved(asset);
        assertEq(asset.balanceOf(feeRecipient), 0);
        asset.setChargeDepositFee(false);
        assertEq(_submit(a, signature), 0);
        assertEq(asset.balanceOf(address(vesting)), AMOUNT);
    }

    /// @notice 반환값이 없는 토큰도 전액 예치되면 SafeERC20을 통해 등록·청구할 수 있다.
    function test_Register_NoReturnTokenCanRegisterAndClaim() public {
        NoReturnERC20 asset = new NoReturnERC20();
        vesting = new Vesting(IERC20(address(asset)), owner);
        signedVesting = ISignedVesting(address(vesting));
        vm.prank(owner);
        asset.approve(address(vesting), AMOUNT);
        asset.mint(owner, AMOUNT);
        _register(_authorization());
        vm.warp(REGISTERED_AT + 600);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), AMOUNT);
        assertEq(asset.balanceOf(beneficiary), AMOUNT);
        assertEq(asset.balanceOf(address(vesting)), 0);
    }

    /// @notice 유효한 수령자의 중첩 등록은 잠금으로 막고 최초 등록만 성공시킨다.
    function test_Register_CatchesNestedRegistration() public {
        _exerciseCallback(false, true);
    }

    /// @notice 중첩 등록 잠금 오류를 전파하면 최초 등록도 복원되고 같은 서명으로 재시도한다.
    function test_Register_PropagatesNestedRegistrationAndRetries() public {
        _exerciseCallback(true, true);
    }

    /// @notice 청구 가능한 기존 일정의 중첩 청구도 같은 잠금으로 차단한다.
    function test_Register_CatchesNestedClaim() public {
        _exerciseCallback(false, false);
    }

    /// @notice 중첩 청구 잠금 오류를 전파하면 토큰과 사용 기록을 복원하고 재시도한다.
    function test_Register_PropagatesNestedClaimAndRetries() public {
        _exerciseCallback(true, false);
    }

    /// @notice 기존 일정으로 청구 권한을 준비하고 등록 전송 도중 유효한 중첩 호출을 시도한다.
    function _exerciseCallback(bool propagate, bool nestedRegistration) internal {
        CallbackERC20 asset = new CallbackERC20();
        _useAsset(asset);
        asset.mint(owner, 2 * AMOUNT);
        vm.prank(owner);
        asset.approve(address(vesting), 2 * AMOUNT);
        ReentrantActor actor = new ReentrantActor(asset);
        actor.bindVesting(vesting);
        beneficiary = address(actor);
        vm.prank(owner);
        vesting.createSchedule(beneficiary, AMOUNT, 0, 120, 600);
        vm.warp(REGISTERED_AT + 300);
        assertEq(vesting.releasableAmount(0), 50 ether);
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        bytes memory nested = nestedRegistration
            ? abi.encodeCall(ISignedVesting.createScheduleWithSignature, (a, signature))
            : abi.encodeCall(Vesting.claim, (0));
        actor.configureAttempt(nested, propagate);
        asset.configureCallback(address(vesting), actor, true);

        if (propagate) {
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            _submit(a, signature);
            assertFalse(vesting.usedAuthorizations(1, 7));
            assertEq(vesting.nextScheduleId(), 1);
            assertEq(asset.balanceOf(owner), AMOUNT);
            assertEq(asset.balanceOf(address(vesting)), AMOUNT);
            assertEq(asset.allowance(owner, address(vesting)), AMOUNT);
            assertEq(asset.callbackCount(), 0);
            assertEq(actor.getCallbackRecord().attempts, 0);
            asset.setCallbackEnabled(false);
            vm.warp(REGISTERED_AT + 360);
            assertEq(_submit(a, signature), 1);
            assertEq(vesting.getSchedule(1).startTime, REGISTERED_AT + 360);
        } else {
            assertEq(_submit(a, signature), 1);
            ReentrantActor.CallbackRecord memory record = actor.getCallbackRecord();
            assertEq(record.attempts, 1);
            assertFalse(record.nestedSucceeded);
            assertEq(record.nestedResult, abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
            assertEq(asset.callbackCount(), 1);
        }
        assertEq(vesting.getSchedule(0).claimedAmount, 0);
        assertTrue(vesting.usedAuthorizations(1, 7));
        assertEq(vesting.nextScheduleId(), 2);
        assertEq(asset.balanceOf(owner), 0);
        assertEq(asset.balanceOf(beneficiary), 0);
        assertEq(asset.balanceOf(address(vesting)), 2 * AMOUNT);
        assertEq(asset.allowance(owner, address(vesting)), 0);
    }

    /// @notice 다른 토큰 사례는 별도 Vesting과 동일한 유한 승인량으로 준비한다.
    function _useAsset(IERC20 asset) internal {
        vesting = new Vesting(asset, owner);
        signedVesting = ISignedVesting(address(vesting));
        vm.prank(owner);
        asset.approve(address(vesting), AMOUNT);
    }

    /// @notice 토큰 전송까지 실행된 실패에서도 서명 소비와 자금 변화가 남지 않는지 검사한다.
    function _assertAlternativePreserved(IERC20 asset) internal view {
        assertEq(vesting.nextScheduleId(), 0);
        assertFalse(vesting.usedAuthorizations(1, 7));
        assertEq(asset.balanceOf(owner), AMOUNT);
        assertEq(asset.balanceOf(address(vesting)), 0);
        assertEq(asset.balanceOf(beneficiary), 0);
        assertEq(asset.allowance(owner, address(vesting)), AMOUNT);
    }
}
