// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vesting} from "../src/Vesting.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice 로컬 체인에 정상 테스트 토큰과 Vesting을 배포한다. 자금 준비·승인은 별도 거래다.
contract DeployLocal is Script {
    error UnsupportedChain(uint256 chainId);
    error InvalidProvider();

    /// @notice chain ID 31337에서 제공자를 발신자·최초 관리자로 두고 두 계약을 각각 배포한다.
    /// @param provider 로컬 unlocked 계정이며 영 주소를 허용하지 않는다.
    /// @return token 새 정상 테스트 토큰이다. 아직 발행한 토큰은 없다.
    /// @return vesting token을 사용하고 provider가 관리하는 새 계약이다. 아직 일정은 없다.
    function run(address provider) external returns (MockERC20 token, Vesting vesting) {
        if (block.chainid != 31337) revert UnsupportedChain(block.chainid);
        if (provider == address(0)) revert InvalidProvider();

        vm.startBroadcast(provider);
        token = new MockERC20();
        vesting = new Vesting(token, provider);
        vm.stopBroadcast();
    }
}
