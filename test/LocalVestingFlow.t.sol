// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLocal} from "../script/DeployLocal.s.sol";
import {Vesting} from "../src/Vesting.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice 로컬 배포 스크립트의 연결·빈 초기 상태·거절 조건을 확인한다.
contract LocalVestingFlowTest is Test {
    /// @notice 지정한 제공자가 관리하며 잔고·일정이 비어 있는 두 계약을 배포한다.
    function test_DeployLocalConnectsTokenAndOwnerWithoutFunding() public {
        vm.chainId(31337);
        address provider = makeAddr("local-provider");
        DeployLocal deployer = new DeployLocal();
        uint64 nonceBefore = vm.getNonce(provider);

        (MockERC20 token, Vesting vesting) = deployer.run(provider);

        assertGt(address(token).code.length, 0);
        assertGt(address(vesting).code.length, 0);
        assertEq(vesting.owner(), provider);
        assertEq(address(vesting.TOKEN()), address(token));
        assertEq(vm.getNonce(provider), nonceBefore + 2);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(token.allowance(provider, address(vesting)), 0);
        assertEq(token.decimals(), 18);
        assertEq(vesting.nextScheduleId(), 0);
    }

    /// @notice 다른 chain ID에서는 배포를 시작하지 않고 제공자의 nonce도 소비하지 않는다.
    function test_DeployLocalRejectsOtherChainBeforeBroadcast() public {
        vm.chainId(1);
        address provider = makeAddr("local-provider");
        DeployLocal deployer = new DeployLocal();
        uint64 nonceBefore = vm.getNonce(provider);

        vm.expectRevert(abi.encodeWithSelector(DeployLocal.UnsupportedChain.selector, 1));
        deployer.run(provider);

        assertEq(vm.getNonce(provider), nonceBefore);
    }

    /// @notice 로컬 체인에서도 관리자로 사용할 수 없는 영 주소를 거절한다.
    function test_DeployLocalRejectsZeroProvider() public {
        vm.chainId(31337);
        DeployLocal deployer = new DeployLocal();

        vm.expectRevert(DeployLocal.InvalidProvider.selector);
        deployer.run(address(0));
    }

    /// @notice Cast receipt의 hex status·topic·data·빈 로그와 null 값을 Foundry로 읽는다.
    function test_ReadsRpcReceiptFields() public view {
        string memory json =
            '{"status":"0x1","logs":[{"address":"0x0000000000000000000000000000000000000001","topics":["0x0000000000000000000000000000000000000000000000000000000000000002"],"data":"0x1234"}]}';
        assertEq(vm.parseJsonUint(json, ".status"), 1);
        assertTrue(vm.keyExistsJson(json, ".logs[0]"));
        assertFalse(vm.keyExistsJson(json, ".logs[1]"));
        assertEq(vm.parseJsonBytes32Array(json, ".logs[0].topics")[0], bytes32(uint256(2)));
        assertEq(vm.parseJsonBytes(json, ".logs[0].data"), hex"1234");
        assertFalse(vm.keyExistsJson('{"logs":[]}', ".logs[0]"));
        assertEq(vm.parseJson('{"forkUrl":null}', ".forkUrl"), abi.encode(bytes32(0)));
    }
}
