// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vesting} from "../src/Vesting.sol";
import {SignedVestingTestBase, ISignedVesting} from "./helpers/SignedVestingTestBase.sol";

contract VestingSignatureTest is SignedVestingTestBase {
    /// @notice 수령자가 등록하면 제공자 토큰을 예치하고 등록 성공 시각에 새 일정이 시작된다.
    function test_Register_DepositsFromFunderAndStartsAtRegistration() public {
        ISignedVesting.Authorization memory authorization = _authorization();
        bytes memory signature = _sign(authorization, address(vesting), block.chainid, OWNER_KEY);

        vm.prank(beneficiary);
        (bool success, bytes memory result) = address(vesting)
            .call(abi.encodeCall(ISignedVesting.createScheduleWithSignature, (authorization, signature)));
        assertTrue(success, "signed registration must succeed");

        uint256 id = abi.decode(result, (uint256));
        Vesting.Schedule memory schedule = vesting.getSchedule(id);
        assertEq(id, 0);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(schedule.funder, owner);
        assertEq(schedule.beneficiary, beneficiary);
        assertEq(schedule.totalAmount, AMOUNT);
        assertEq(schedule.startTime, REGISTERED_AT);
        assertEq(schedule.cliffDuration, 120);
        assertEq(schedule.duration, 600);
        assertEq(schedule.claimedAmount, 0);
        assertEq(schedule.revokedAt, 0);
        assertFalse(schedule.revoked);
        assertEq(token.balanceOf(owner), INITIAL_BALANCE - AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.allowance(owner, address(vesting)), 0);
        assertTrue(vesting.usedAuthorizations(1, 7));
    }

    /// @notice 늦게 등록해도 성공 시점부터 계산하며 등록 마감 후에도 기존 일정은 청구한다.
    function test_Register_AccruesFromRegistrationAndClaimsAfterDeadline() public {
        ISignedVesting.Authorization memory a = _authorization();
        a.deadline = REGISTERED_AT + 400;
        vm.warp(REGISTERED_AT + 300);
        _register(a);
        assertEq(vesting.getSchedule(0).startTime, REGISTERED_AT + 300);
        vm.warp(REGISTERED_AT + 419);
        assertEq(vesting.releasableAmount(0), 0);
        vm.warp(REGISTERED_AT + 420);
        assertEq(vesting.releasableAmount(0), 20 ether);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 20 ether);
        vm.warp(REGISTERED_AT + 600);
        assertEq(vesting.releasableAmount(0), 30 ether);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 30 ether);
        vm.warp(REGISTERED_AT + 900);
        vm.prank(beneficiary);
        assertEq(vesting.claim(0), 50 ether);
        assertEq(token.balanceOf(beneficiary), AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.getSchedule(0).claimedAmount, AMOUNT);
    }

    /// @notice 사용한 승인을 다시 제출해도 추가 예치·승인량 소비·일정 생성이 없다.
    function test_Register_RejectsUsedAuthorization() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        _register(a);
        vm.prank(owner);
        token.approve(address(vesting), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Vesting.AuthorizationAlreadyUsed.selector, 1, 7));
        vm.prank(beneficiary);
        signedVesting.createScheduleWithSignature(a, signature);
        assertEq(vesting.nextScheduleId(), 1);
        assertEq(token.balanceOf(owner), INITIAL_BALANCE - AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(token.allowance(owner, address(vesting)), AMOUNT);
    }

    /// @notice 서로 다른 승인 번호는 번호순과 관계없이 동일 조건의 독립 일정을 만든다.
    function test_Register_SeparateNoncesCreateIndependentSchedulesOutOfOrder() public {
        vm.prank(owner);
        token.approve(address(vesting), 2 * AMOUNT);
        ISignedVesting.Authorization memory a = _authorization();
        a.nonce = 8;
        assertEq(_register(a), 0);
        a.nonce = 7;
        vm.warp(REGISTERED_AT + 60);
        assertEq(_register(a), 1);
        assertTrue(vesting.usedAuthorizations(1, 7));
        assertTrue(vesting.usedAuthorizations(1, 8));
        assertEq(vesting.getSchedule(0).startTime, REGISTERED_AT);
        assertEq(vesting.getSchedule(1).startTime, REGISTERED_AT + 60);
        assertEq(token.balanceOf(address(vesting)), 2 * AMOUNT);
        assertEq(token.balanceOf(owner), INITIAL_BALANCE - 2 * AMOUNT);
    }

    /// @notice 사용한 번호는 지급량을 바꿔 다시 서명해도 같은 관리자 재임 중 재사용할 수 없다.
    function test_Register_NonceIdentifiesAuthorizationNotSignatureBytes() public {
        ISignedVesting.Authorization memory a = _authorization();
        _register(a);
        a.totalAmount = 2 * AMOUNT;
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(Vesting.AuthorizationAlreadyUsed.selector, 1, 7));
        vm.prank(beneficiary);
        signedVesting.createScheduleWithSignature(a, signature);
        assertEq(vesting.nextScheduleId(), 1);
    }

    /// @notice 서명을 가진 제3자의 대리 등록은 거절하고 수령자의 승인은 보존한다.
    function test_Register_RejectsThirdPartyAndPreservesAuthorization() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(Vesting.NotBeneficiary.selector);
        vm.prank(makeAddr("third party"));
        signedVesting.createScheduleWithSignature(a, signature);
        _assertUnregistered(a);
        assertEq(token.allowance(owner, address(vesting)), AMOUNT);
        assertEq(_register(a), 0);
    }

    /// @notice 등록 마감 정각은 허용하고 그 뒤 1초는 거절한다.
    function test_Register_DeadlineBoundary() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.warp(a.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Vesting.AuthorizationExpired.selector, a.deadline));
        vm.prank(beneficiary);
        signedVesting.createScheduleWithSignature(a, signature);
        _assertUnregistered(a);
        assertEq(token.allowance(owner, address(vesting)), AMOUNT);
        // 시간 되돌리기는 동일 서명의 허용 경계를 따로 확인하는 테스트 대조다.
        vm.warp(a.deadline);
        assertEq(_register(a), 0);
        assertEq(vesting.getSchedule(0).startTime, a.deadline);
    }

    /// @notice 다른 계약용 서명은 토큰·조건·관리자가 같아도 현재 계약에서 거절된다.
    function test_Register_RejectsSignatureForDifferentContract() public {
        ISignedVesting.Authorization memory a = _authorization();
        Vesting other = new Vesting(token, owner);
        _expectInvalidSignature(a, _sign(a, address(other), block.chainid, OWNER_KEY));
        _assertUnregistered(a);
        assertEq(_register(a), 0);
    }

    /// @notice 배포 당시 체인 ID의 서명은 체인 ID가 바뀌면 사용할 수 없다.
    function test_Register_RejectsSignatureForDifferentChain() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.chainId(block.chainid + 1);
        _expectInvalidSignature(a, signature);
        _assertUnregistered(a);
        assertEq(_register(a), 0);
    }

    /// @notice 공개 해시 함수가 독립적으로 구성한 표준 도메인·메시지 해시와 일치한다.
    function test_Hash_MatchesIndependentTypedDataEncoding() public view {
        ISignedVesting.Authorization memory a = _authorization();
        assertEq(signedVesting.hashScheduleAuthorization(a), _digest(a, address(vesting), block.chainid));
        assertEq(vesting.SCHEDULE_AUTHORIZATION_TYPEHASH(), AUTHORIZATION_TYPEHASH);
        assertEq(vesting.ownerEpoch(), 1);
    }

    /// @notice 일정의 제공자·수령자와 사용한 승인 번호·일정 ID가 이벤트에 정확히 연결된다.
    function test_Register_EmitsScheduleAndAuthorizationLink() public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectEmit(true, true, true, true, address(vesting));
        emit Vesting.ScheduleCreated(0, beneficiary, owner, AMOUNT, REGISTERED_AT, 120, 600);
        vm.expectEmit(true, true, true, true, address(vesting));
        emit Vesting.ScheduleAuthorizationUsed(1, 7, 0);
        assertEq(_submit(a, signature), 0);
    }

    /// @notice 다양한 총량과 승인 번호에서도 만기에 원금이 보존되고 번호와 일정 ID는 독립이다.
    function testFuzz_Register_ClaimConservesTokens(uint256 amountSeed, uint256 nonce) public {
        ISignedVesting.Authorization memory a = _authorization();
        a.totalAmount = bound(amountSeed, 1, INITIAL_BALANCE);
        a.nonce = nonce;
        vm.prank(owner);
        token.approve(address(vesting), a.totalAmount);
        uint256 id = _register(a);
        assertEq(id, 0);
        vm.warp(REGISTERED_AT + 600);
        vm.prank(beneficiary);
        assertEq(vesting.claim(id), a.totalAmount);
        assertEq(token.balanceOf(owner), INITIAL_BALANCE - a.totalAmount);
        assertEq(token.balanceOf(beneficiary), a.totalAmount);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.getSchedule(id).claimedAmount, a.totalAmount);
        assertEq(vesting.releasableAmount(id), 0);
        assertTrue(vesting.usedAuthorizations(1, nonce));
    }

    /// @notice 다른 키·빈 서명·짧은 서명·유효하지 않은 서명 값을 모두 거절한다.
    function test_Register_RejectsWrongSignerAndMalformedSignatures() public {
        ISignedVesting.Authorization memory a = _authorization();
        _expectInvalidSignature(a, _sign(a, address(vesting), block.chainid, OWNER_KEY + 1));
        _expectInvalidSignature(a, hex"");
        _expectInvalidSignature(a, new bytes(64));
        _expectInvalidSignature(a, new bytes(65));
        _assertUnregistered(a);
    }

    /// @notice 서명한 제공자·수령자·금액·기간·번호·마감·재임 번호 중 한 필드를 바꾸면 거절된다.
    function testFuzz_Register_RejectsChangedSignedField(uint8 fieldSeed) public {
        ISignedVesting.Authorization memory a = _authorization();
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        uint256 field = bound(fieldSeed, 0, 7);
        if (field == 0) a.funder = makeAddr("other funder");
        if (field == 1) a.beneficiary = makeAddr("other beneficiary");
        if (field == 2) a.totalAmount += 1;
        if (field == 3) a.cliffDuration += 1;
        if (field == 4) a.duration += 1;
        if (field == 5) a.nonce += 1;
        if (field == 6) a.deadline += 1;
        if (field == 7) a.ownerEpoch += 1;
        if (field == 0) {
            vm.expectRevert(abi.encodeWithSelector(Vesting.InvalidAuthorizationFunder.selector, a.funder));
        } else if (field == 7) {
            vm.expectRevert(abi.encodeWithSelector(Vesting.InvalidAuthorizationEpoch.selector, 1, 2));
        } else {
            vm.expectRevert(Vesting.InvalidAuthorizationSignature.selector);
        }
        vm.prank(a.beneficiary);
        signedVesting.createScheduleWithSignature(a, signature);
        _assertUnregistered(a);
        assertEq(token.allowance(owner, address(vesting)), AMOUNT);
    }

    /// @notice 신규 경로도 영 금액·영 기간·기간보다 긴 cliff를 거절하며 승인을 보존한다.
    function test_Register_RejectsInvalidScheduleTerms() public {
        ISignedVesting.Authorization memory a = _authorization();
        a.totalAmount = 0;
        _expectInvalidTerms(a, Vesting.InvalidAmount.selector);
        a.totalAmount = AMOUNT;
        a.cliffDuration = 0;
        a.duration = 0;
        _expectInvalidTerms(a, Vesting.InvalidDuration.selector);
        a.duration = 100;
        a.cliffDuration = 101;
        _expectInvalidTerms(a, Vesting.InvalidCliff.selector);
        _assertUnregistered(a);
    }

    /// @notice 서명을 먼저 준비한 뒤 등록 함수가 정확한 입력 오류로 실패하는지 검사한다.
    function _expectInvalidTerms(ISignedVesting.Authorization memory a, bytes4 errorSelector) internal {
        bytes memory signature = _sign(a, address(vesting), block.chainid, OWNER_KEY);
        vm.expectRevert(errorSelector);
        vm.prank(beneficiary);
        signedVesting.createScheduleWithSignature(a, signature);
    }

    /// @notice 지정 서명이 현재 계약의 유효한 지급 승인으로 인정되지 않는지 검사한다.
    function _expectInvalidSignature(ISignedVesting.Authorization memory a, bytes memory signature) internal {
        vm.expectRevert(Vesting.InvalidAuthorizationSignature.selector);
        vm.prank(a.beneficiary);
        signedVesting.createScheduleWithSignature(a, signature);
    }
}
