// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vesting} from "../../src/Vesting.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice 클라이언트가 전달할 ABI와 서명 데이터를 운영 코드와 독립적으로 정의한다.
interface ISignedVesting {
    struct Authorization {
        address funder;
        address beneficiary;
        uint256 totalAmount;
        uint64 cliffDuration;
        uint64 duration;
        uint256 nonce;
        uint256 deadline;
        uint256 ownerEpoch;
    }

    /// @notice 지정 수령자가 서명한 승인 내용을 제출하는 외부 ABI다.
    /// @param authorization 클라이언트가 구성한 지급 승인 조건.
    /// @param signature 관리자 서명 바이트.
    /// @return scheduleId 새로 저장한 일정 ID.
    function createScheduleWithSignature(Authorization calldata authorization, bytes calldata signature)
        external
        returns (uint256 scheduleId);

    /// @notice 운영 계약의 해시를 독립적으로 구성한 기대 해시와 대조하기 위한 조회 ABI다.
    /// @param authorization 해시를 조회할 승인 조건.
    /// @return digest 계약이 계산한 최종 EIP-712 해시.
    function hashScheduleAuthorization(Authorization calldata authorization) external view returns (bytes32 digest);
}

abstract contract SignedVestingTestBase is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant AUTHORIZATION_TYPEHASH = keccak256(
        "ScheduleAuthorization(address funder,address beneficiary,uint256 totalAmount,uint64 cliffDuration,uint64 duration,uint256 nonce,uint256 deadline,uint256 ownerEpoch)"
    );
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant AMOUNT = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint64 internal constant REGISTERED_AT = 1_800_000_000;

    MockERC20 internal token;
    Vesting internal vesting;
    ISignedVesting internal signedVesting;
    address internal owner;
    address internal beneficiary;

    /// @notice 시험용 제공자 키·수령자·토큰·Vesting과 유한 승인량, 등록 시각을 준비한다.
    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        beneficiary = makeAddr("beneficiary");
        token = new MockERC20();
        vesting = new Vesting(token, owner);
        signedVesting = ISignedVesting(address(vesting));
        token.mint(owner, INITIAL_BALANCE);
        vm.prank(owner);
        token.approve(address(vesting), AMOUNT);
        vm.warp(REGISTERED_AT);
    }

    /// @notice 별도 지급 승인 한 건의 기본 조건을 준비한다. 승인 번호와 일정 ID는 서로 다르다.
    function _authorization() internal view returns (ISignedVesting.Authorization memory) {
        return ISignedVesting.Authorization(owner, beneficiary, AMOUNT, 120, 600, 7, REGISTERED_AT + 1 hours, 1);
    }

    /// @notice 공통 승인에 서명하고 지정 수령자 주소로 등록한다.
    function _register(ISignedVesting.Authorization memory authorization) internal returns (uint256) {
        bytes memory signature = _sign(authorization, address(vesting), block.chainid, OWNER_KEY);
        return _submit(authorization, signature);
    }

    /// @notice 이미 받은 서명을 다시 생성하지 않고 그대로 제출한다.
    function _submit(ISignedVesting.Authorization memory authorization, bytes memory signature)
        internal
        returns (uint256)
    {
        vm.prank(authorization.beneficiary);
        return signedVesting.createScheduleWithSignature(authorization, signature);
    }

    /// @notice 거절된 승인에 사용 기록·새 일정·토큰 이동이 남지 않았는지 확인한다.
    function _assertUnregistered(ISignedVesting.Authorization memory authorization) internal view {
        assertFalse(vesting.usedAuthorizations(authorization.ownerEpoch, authorization.nonce));
        assertEq(vesting.nextScheduleId(), 0);
        assertEq(token.balanceOf(owner), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.balanceOf(beneficiary), 0);
    }

    /// @notice 공개 표준과 고정 타입 문자열로 해시를 직접 구성하여 운영 해시 함수에 의존하지 않는다.
    function _digest(ISignedVesting.Authorization memory authorization, address target, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Vesting"), keccak256("1"), chainId, target));
        bytes32 body = keccak256(
            abi.encode(
                AUTHORIZATION_TYPEHASH,
                authorization.funder,
                authorization.beneficiary,
                authorization.totalAmount,
                authorization.cliffDuration,
                authorization.duration,
                authorization.nonce,
                authorization.deadline,
                authorization.ownerEpoch
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, body));
    }

    /// @notice 시험용 개인키로만 서명하며 실제 MetaMask 키는 읽거나 저장하지 않는다.
    function _sign(ISignedVesting.Authorization memory authorization, address target, uint256 chainId, uint256 key)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(authorization, target, chainId));
        return abi.encodePacked(r, s, v);
    }
}
