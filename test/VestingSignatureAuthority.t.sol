// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vesting} from "../src/Vesting.sol";
import {SignedVestingTestBase, ISignedVesting} from "./helpers/SignedVestingTestBase.sol";
import {SignatureOwner} from "./helpers/SignatureOwner.sol";
import {CallbackERC20} from "./mocks/CallbackERC20.sol";

contract VestingSignatureAuthorityTest is SignedVestingTestBase {
    /// @notice P에서 Q로 바뀌거나 다시 P로 복귀해도 최초 P의 승인은 부활하지 않는다.
    function test_Register_OldAuthorizationDoesNotReviveAfterOwnershipRoundTrip() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        address nextOwner = makeAddr("next owner");
        vm.prank(owner);
        vesting.transferOwnership(nextOwner);
        assertEq(vesting.ownerEpoch(), 2);
        vm.expectRevert(abi.encodeWithSelector(Vesting.InvalidAuthorizationFunder.selector, owner));
        _submit(a, signature);
        _assertUnregistered(a);
        vm.prank(nextOwner);
        vesting.transferOwnership(owner);
        assertEq(vesting.ownerEpoch(), 3);
        vm.expectRevert(abi.encodeWithSelector(Vesting.InvalidAuthorizationEpoch.selector, 3, 1));
        _submit(a, signature);
        _assertUnregistered(a);
        a.ownerEpoch = 3;
        assertEq(_register(a), 0);
        assertTrue(vesting.usedAuthorizations(3, 7));
        assertFalse(vesting.usedAuthorizations(1, 7));
    }

    /// @notice 같은 관리자 주소로 이전하는 호출이나 실패한 이전은 미사용 승인을 무효화하지 않는다.
    function test_Register_SameOwnerAndFailedTransferPreserveEpoch() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.prank(owner);
        vesting.transferOwnership(owner);
        assertEq(vesting.ownerEpoch(), 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        vm.prank(owner);
        vesting.transferOwnership(address(0));
        assertEq(vesting.ownerEpoch(), 1);
        assertEq(_submit(a, signature), 0);
    }

    /// @notice 사용한 번호라도 새 재임 번호에 새로 서명하면 별도 승인으로 사용할 수 있다.
    function test_Register_NonceUseIsScopedToOwnershipEpoch() public {
        ISignedVesting.Authorization memory a = _authorization();
        _register(a);
        address nextOwner = makeAddr("next owner");
        vm.prank(owner);
        vesting.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        vesting.transferOwnership(owner);
        vm.prank(owner);
        token.approve(address(vesting), AMOUNT);
        a.ownerEpoch = 3;
        assertEq(_register(a), 1);
        assertTrue(vesting.usedAuthorizations(1, 7));
        assertTrue(vesting.usedAuthorizations(3, 7));
        assertEq(token.balanceOf(address(vesting)), 2 * AMOUNT);
        assertEq(vesting.getSchedule(1).funder, owner);
    }

    /// @notice 소유권을 포기하면 미등록 승인은 막되 이미 등록한 수령자의 청구는 유지한다.
    function test_Register_RenouncementInvalidatesPendingButPreservesClaims() public {
        ISignedVesting.Authorization memory a = _authorization();
        _register(a);
        a.nonce = 8;
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.prank(owner);
        vesting.renounceOwnership();
        assertEq(vesting.owner(), address(0));
        assertEq(vesting.ownerEpoch(), 2);
        vm.expectRevert(abi.encodeWithSelector(Vesting.InvalidAuthorizationFunder.selector, owner));
        _submit(a, signature);
        assertFalse(vesting.usedAuthorizations(1, 8));
        assertEq(vesting.nextScheduleId(), 1);
        vm.warp(REGISTERED_AT + 600);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), AMOUNT);
        assertEq(token.balanceOf(beneficiary), AMOUNT);
    }

    /// @notice 새 관리자가 서명 생성 일정을 취소해도 미확정 반환은 최초 제공자에게 간다.
    function test_Register_RevokeAfterOwnershipTransferRefundsOriginalFunder() public {
        _register(_authorization());
        address nextOwner = makeAddr("next owner");
        vm.prank(owner);
        vesting.transferOwnership(nextOwner);
        vm.warp(REGISTERED_AT + 300);
        vm.prank(nextOwner);
        vesting.revoke(0);
        assertEq(token.balanceOf(owner), INITIAL_BALANCE - 50 ether);
        assertEq(token.balanceOf(nextOwner), 0);
        assertEq(token.balanceOf(address(vesting)), 50 ether);
        vm.warp(REGISTERED_AT + 600);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 50 ether);
        assertEq(token.balanceOf(beneficiary), 50 ether);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.getSchedule(0).funder, owner);
    }

    /// @notice 관리자가 계약 계정이어도 ERC-1271의 실제 검증을 거쳐 자금을 예치한다.
    function test_Register_ContractOwnerValidatesERC1271Signature() public {
        SignatureOwner wallet = _contractOwner();
        assertEq(_register(_authorization()), 0);
        assertEq(vesting.getSchedule(0).funder, address(wallet));
        assertEq(token.balanceOf(address(wallet)), INITIAL_BALANCE - AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertTrue(vesting.usedAuthorizations(1, 7));
    }

    /// @notice 계약 지갑이 같은 서명을 거절하면 등록도 거절하며 정책 복구 후 원래 서명을 쓴다.
    function test_Register_ContractOwnerSignaturePolicyCanChange() public {
        SignatureOwner wallet = _contractOwner();
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        wallet.setSignaturesEnabled(false);
        vm.expectRevert(Vesting.InvalidAuthorizationSignature.selector);
        _submit(a, signature);
        _assertUnregistered(a);
        wallet.setSignaturesEnabled(true);
        assertEq(_submit(a, signature), 0);
    }

    /// @notice 계약 서명 검증의 revert나 짧은 반환값을 성공 서명으로 오인하지 않는다.
    function test_Register_RejectsRevertingAndShortERC1271Responses() public {
        _contractOwner();
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        // 라이브러리의 끝 패딩 생략에도 맞도록 함수 선택자 기준으로 응답을 모의한다.
        bytes memory callData = abi.encodePacked(IERC1271.isValidSignature.selector);
        vm.mockCallRevert(owner, callData, hex"deadbeef");
        vm.expectRevert(Vesting.InvalidAuthorizationSignature.selector);
        _submit(a, signature);
        vm.clearMockedCalls();
        vm.mockCall(owner, callData, hex"1626ba7e");
        vm.expectRevert(Vesting.InvalidAuthorizationSignature.selector);
        _submit(a, signature);
        vm.clearMockedCalls();
        _assertUnregistered(a);
        assertEq(_submit(a, signature), 0);
    }

    /// @notice 토큰 외부 호출 도중 관리자 이전이 발생하면 이전과 예치·등록 모두 되돌린다.
    function test_Register_OwnershipChangeDuringDepositRollsBack() public {
        address signer = owner;
        CallbackERC20 asset = new CallbackERC20();
        SignatureOwner wallet = new SignatureOwner(signer);
        owner = address(wallet);
        vesting = new Vesting(asset, owner);
        signedVesting = ISignedVesting(address(vesting));
        asset.mint(owner, AMOUNT);
        wallet.approve(asset, vesting, AMOUNT);
        wallet.configureOwnershipCallback(address(asset), vesting, makeAddr("next owner"));
        asset.configureCallback(address(vesting), wallet, true);
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(Vesting.InvalidAuthorizationFunder.selector, owner));
        _submit(a, signature);
        assertEq(vesting.owner(), owner);
        assertEq(vesting.ownerEpoch(), 1);
        assertEq(vesting.nextScheduleId(), 0);
        assertFalse(vesting.usedAuthorizations(1, 7));
        assertEq(asset.balanceOf(owner), AMOUNT);
        assertEq(asset.balanceOf(address(vesting)), 0);
        assertEq(asset.allowance(owner, address(vesting)), AMOUNT);
        assertEq(asset.callbackCount(), 0);
        asset.setCallbackEnabled(false);
        assertEq(_submit(a, signature), 0);
    }

    /// @notice 실제 서명 검증 로직을 가진 계약 관리자를 충분한 자금과 유한 승인량으로 준비한다.
    function _contractOwner() internal returns (SignatureOwner wallet) {
        wallet = new SignatureOwner(owner);
        owner = address(wallet);
        vesting = new Vesting(token, owner);
        signedVesting = ISignedVesting(address(vesting));
        token.mint(owner, INITIAL_BALANCE);
        wallet.approve(token, vesting, AMOUNT);
    }
}
