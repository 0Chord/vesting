// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Vesting} from "../../src/Vesting.sol";
import {ITokenCallback} from "../mocks/CallbackERC20.sol";

/// @notice 계약 계정 서명과 전송 중 관리자 변경을 재현하는 시험용 지갑이다.
/// @dev 제어 함수에 접근 제한이 없는 테스트 대역이며 실제 자금용 지갑이 아니다.
contract SignatureOwner is IERC1271, ITokenCallback {
    error UnexpectedToken(address caller);

    /// @notice 계약 계정이 유효한 서명자로 인정하는 테스트 EOA 주소.
    address public immutable SIGNER;
    /// @notice 같은 서명도 계약 계정 정책에 따라 거절할 수 있는지 검사하는 설정.
    bool public signaturesEnabled = true;
    address private callbackToken;
    Vesting private callbackVesting;
    address private nextOwner;

    /// @notice 시험용 계약 계정의 서명자를 지정한다.
    /// @param signer 테스트 개인키에서 얻은 EOA 주소.
    constructor(address signer) {
        SIGNER = signer;
    }

    /// @notice 서명 유효성 설정을 바꾼다. 서명이나 승인 사용 기록을 직접 수정하지 않는다.
    /// @param enabled true이면 지정한 서명자의 정상 ECDSA 서명을 허용한다.
    function setSignaturesEnabled(bool enabled) external {
        signaturesEnabled = enabled;
    }

    /// @notice ERC-1271 규칙에 따라 제공받은 해시와 서명을 검증한다.
    /// @param digest Vesting이 구성해 전달한 EIP-712 해시.
    /// @param signature 테스트 서명자 개인키로 만든 서명.
    /// @return magicValue 유효하면 ERC-1271 식별자, 아니면 실패 식별자.
    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4 magicValue) {
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signature);
        return signaturesEnabled && error == ECDSA.RecoverError.NoError && recovered == SIGNER
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    /// @notice 계약 계정 자신의 토큰을 Vesting이 예치할 수 있도록 승인한다.
    /// @param asset 승인할 테스트 토큰.
    /// @param target 승인받을 Vesting.
    /// @param amount 유한 승인 수량.
    function approve(IERC20 asset, Vesting target, uint256 amount) external {
        asset.approve(address(target), amount);
    }

    /// @notice 토큰 콜백에서 이 지갑이 보유한 관리자 권한을 옮기도록 설정한다.
    /// @param asset 콜백 호출을 허용할 토큰 주소.
    /// @param target 권한 이전 대상인 Vesting.
    /// @param newOwner 새 관리자 주소.
    function configureOwnershipCallback(address asset, Vesting target, address newOwner) external {
        callbackToken = asset;
        callbackVesting = target;
        nextOwner = newOwner;
    }

    /// @notice 토큰 전송 도중 관리자 권한을 실제로 변경한다.
    /// @dev 최초 등록이 실패하면 이 권한 변경도 같은 거래 안에서 되돌아간다.
    function onTokenTransfer() external {
        if (msg.sender != callbackToken) revert UnexpectedToken(msg.sender);
        callbackVesting.transferOwnership(nextOwner);
    }
}
