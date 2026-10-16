// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vesting} from "../src/Vesting.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @dev 파일 접근은 foundry.toml의 cache/local-vesting 권한 안에서만 허용한다.
/// @notice 로컬 RPC 결과·약정·자금을 Foundry로 검사한다. broadcast하지 않는 검증용 스크립트다.
contract CheckLocal is Test {
    uint256 internal constant TOTAL = 1000 ether;

    /// @notice 실행 예제에서 보내는 별개 거래의 순서다.
    enum Action {
        Mint,
        NoApproval,
        Approve,
        InvalidRecipient,
        Create,
        Cliff,
        Claim30,
        WrongClaim,
        WrongRevoke,
        Claim40,
        Revoke60,
        Claim100
    }

    /// @notice 같은 실행의 실제 주소·이벤트 ID·생성 블록 시각을 보관한다.
    struct Context {
        address provider;
        address beneficiary;
        MockERC20 token;
        Vesting vesting;
        uint256 id;
        uint256 start;
    }

    /// @notice 노드의 실제 계정 둘을 읽어 Cast가 해독할 ABI와 실행별 JSON을 저장한다.
    /// @param dir 이 실행의 cache/local-vesting 하위 경로다.
    function accounts(string memory dir) public {
        assertEq(block.chainid, 31337, "local chain");
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        address[] memory pool = vm.parseJsonAddressArray(vm.readFile(string.concat(dir, "/accounts-rpc.log")), "$");
        assertGe(pool.length, 2);
        assertTrue(pool[0] != address(0) && pool[1] != address(0) && pool[0] != pool[1]);
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory info = vm.readFile(string.concat(dir, "/node-info.log"));
        assertEq(vm.parseJson(info, ".forkConfig.forkUrl"), abi.encode(bytes32(0)));
        Context memory c;
        c.provider = pool[0];
        c.beneficiary = pool[1];
        _write(dir, c);
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/roles.abi"), vm.toString(abi.encode(pool[0], pool[1])));
    }

    /// @notice 배포 artifact를 typed JSON으로 읽어 실제 receipt를 조회할 hash와 주소를 ABI로 저장한다.
    /// @param dir 이 실행만의 broadcast 경로다.
    function deployment(string memory dir) public {
        Context memory c = _context(dir);
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(string.concat(dir, "/broadcast/DeployLocal.s.sol/31337/run-latest.json"));
        bytes32 first = vm.parseJsonBytes32(json, ".transactions[0].hash");
        bytes32 second = vm.parseJsonBytes32(json, ".transactions[1].hash");
        c.token = MockERC20(vm.parseJsonAddress(json, ".transactions[0].contractAddress"));
        c.vesting = Vesting(vm.parseJsonAddress(json, ".transactions[1].contractAddress"));
        _write(dir, c);
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/deployment-hashes.abi"), vm.toString(abi.encode(first, second)));
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(
            string.concat(dir, "/addresses.abi"), vm.toString(abi.encode(address(c.token), address(c.vesting)))
        );
    }

    /// @notice 배포 결과 JSON을 실제 receipt·code·owner/TOKEN과 대조하고 주소 ABI를 저장한다.
    /// @param dir 실행별 broadcast와 context가 있는 경로다.
    function prepare(string memory dir) public {
        Context memory c = _context(dir);
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(string.concat(dir, "/broadcast/DeployLocal.s.sol/31337/run-latest.json"));
        assertFalse(vm.keyExistsJson(json, ".transactions[2]"), "exactly two deployments");
        address[2] memory deployed;
        for (uint256 i; i < 2; ++i) {
            string memory key = string.concat(".transactions[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(key, ".contractName")), i == 0 ? "MockERC20" : "Vesting");
            assertEq(vm.parseJsonString(json, string.concat(key, ".transactionType")), "CREATE");
            bytes32 hash = vm.parseJsonBytes32(json, string.concat(key, ".hash"));
            // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory receipt = vm.readFile(string.concat(dir, "/deployment-", vm.toString(i), ".log"));
            assertEq(vm.parseJsonBytes32(receipt, ".transactionHash"), hash);
            assertEq(vm.parseJsonUint(receipt, ".status"), 1);
            assertEq(vm.parseJsonAddress(receipt, ".from"), c.provider);
            deployed[i] = vm.parseJsonAddress(receipt, ".contractAddress");
            assertEq(deployed[i], vm.parseJsonAddress(json, string.concat(key, ".contractAddress")));
            assertGt(deployed[i].code.length, 0);
            uint256 timestamp = _blockTimestamp(dir, string.concat("deployment-", vm.toString(i)), receipt);
            vm.serializeBytes32("deployment-time", "transactionHash", hash);
            vm.serializeUint("deployment-time", "blockNumber", vm.parseJsonUint(receipt, ".blockNumber"));
            vm.writeJson(
                vm.serializeUint("deployment-time", "timestamp", timestamp),
                string.concat(dir, "/deployment-time-", vm.toString(i), ".json")
            );
            // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
            // forge-lint: disable-next-line(unsafe-cheatcode)
            vm.writeFile(string.concat(dir, "/deployment-", vm.toString(i), ".json"), receipt);
        }
        c.token = MockERC20(deployed[0]);
        c.vesting = Vesting(deployed[1]);
        assertEq(c.vesting.owner(), c.provider);
        assertEq(address(c.vesting.TOKEN()), address(c.token));
        assertEq(c.token.totalSupply(), 0);
        assertEq(c.vesting.nextScheduleId(), 0);
        _write(dir, c);
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/addresses.abi"), vm.toString(abi.encode(deployed[0], deployed[1])));
    }

    /// @notice 실패 거래 직전의 저장 약정·토큰·권한을 보존한다. 가스·nonce·시각별 조회는 제외한다.
    /// @param dir 실행별 기록 경로다.
    /// @param action 다음 거래의 행동 번호다. 기록을 덮어쓰지 않고 전후 상태를 연결한다.
    function snapshot(string memory dir, Action action) public {
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/before.hash"), vm.toString(keccak256(_state(_context(dir)))));
        _recordState(dir, string.concat("before-", vm.toString(uint256(action))), _context(dir));
    }

    /// @notice 실제 거래의 발신자·입력·receipt·오류·이벤트·시각·최종 상태를 검사한다.
    /// @param dir 실행별 기록 경로다.
    /// @param action 보낸 거래의 기대 역할이다.
    /// @param hash 실제 Cast가 전송한 거래 hash다.
    function verify(string memory dir, Action action, bytes32 hash) public {
        Context memory c = _context(dir);
        bytes memory error = _transaction(dir, c, action, hash);
        string memory receipt = _receipt(dir, action, hash);
        assertEq(vm.parseJsonUint(receipt, ".status"), error.length == 0 ? 1 : 0, "receipt status");
        uint256 timestamp = _timestamp(dir, action, receipt);
        uint256 day = action == Action.Cliff
            ? 19
            : action == Action.Claim30
                ? 30
                : action == Action.Claim40 ? 40 : action == Action.Revoke60 ? 60 : action == Action.Claim100 ? 100 : 0;
        if (day != 0) assertEq(timestamp, c.start + day * 1 days, "actual transaction timestamp");
        if (error.length != 0) {
            _failure(dir, c, action, receipt, error);
        } else {
            if (action == Action.Create) {
                c.id = uint256(vm.parseJsonBytes32Array(receipt, ".logs[1].topics")[1]);
                assertEq(c.id, 0, "fresh schedule id");
                c.start = timestamp;
                _write(dir, c);
                // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
                // forge-lint: disable-next-line(unsafe-cheatcode)
                vm.writeFile(string.concat(dir, "/start.abi"), vm.toString(abi.encode(timestamp)));
            }
            _events(c, action, receipt);
        }
        _assertState(c, _phase(action));
        _recordState(dir, string.concat("after-", vm.toString(uint256(action))), c);
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/receipt-", vm.toString(uint256(action)), ".json"), receipt);
    }

    /// @notice 실제 거래의 from/to/input을 확인하고 기대 오류를 반환한다.
    function _transaction(string memory dir, Context memory c, Action action, bytes32 hash)
        internal
        returns (bytes memory)
    {
        (address sender, address to, bytes memory input, bytes memory error) = _request(c, action);
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory txJson = vm.readFile(string.concat(dir, "/tx-", vm.toString(uint256(action)), ".log"));
        assertEq(vm.parseJsonBytes32(txJson, ".hash"), hash);
        assertEq(vm.parseJsonAddress(txJson, ".from"), sender);
        assertEq(vm.parseJsonAddress(txJson, ".to"), to);
        assertEq(vm.parseJsonBytes(txJson, ".input"), input);
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/transaction-", vm.toString(uint256(action)), ".json"), txJson);
        return error;
    }

    /// @notice 실제 실패의 receipt·trace·보존 상태를 확인한다. status0만으로 통과하지 않는다.
    function _failure(string memory dir, Context memory c, Action action, string memory receipt, bytes memory error)
        internal
    {
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory trace = vm.readFile(string.concat(dir, "/trace-rpc-", vm.toString(uint256(action)), ".log"));
        assertGt(bytes(vm.parseJsonString(trace, ".error")).length, 0);
        assertEq(vm.parseJsonBytes(trace, ".output"), error, "exact transaction revert data");
        assertFalse(vm.keyExistsJson(receipt, ".logs[0]"));
        assertEq(
            keccak256(_state(c)),
            // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
            // forge-lint: disable-next-line(unsafe-cheatcode)
            vm.parseBytes32(vm.readFile(string.concat(dir, "/before.hash"))),
            "failed transaction preserves state"
        );
        // 로컬 실행의 검증 결과를 보관한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(string.concat(dir, "/trace-", vm.toString(uint256(action)), ".json"), trace);
    }

    /// @notice 성공한 30일 블록으로 고정한 Forge 시뮬레이션에서 중복 청구 거절을 확인한다.
    /// @param dir 실제 주소·약정이 있는 실행 경로다. 이 호출은 broadcast하지 않는다.
    function duplicate(string memory dir) public {
        Context memory c = _context(dir);
        assertEq(block.timestamp, c.start + 30 days);
        bytes32 beforeHash = keccak256(_state(c));
        vm.prank(c.beneficiary);
        vm.expectRevert(Vesting.NothingToClaim.selector);
        c.vesting.claim(c.id);
        assertEq(keccak256(_state(c)), beforeHash);
        _assertState(c, 3);
    }

    /// @notice 현재 저장 상태를 ABI로 묶는다. 모든 실패 비교가 같은 필드를 사용한다.
    function _state(Context memory c) internal view returns (bytes memory) {
        Vesting.Schedule memory schedule;
        if (c.vesting.nextScheduleId() != 0) schedule = c.vesting.getSchedule(c.id);
        return abi.encode(
            c.token.balanceOf(c.provider),
            c.token.balanceOf(address(c.vesting)),
            c.token.balanceOf(c.beneficiary),
            c.token.allowance(c.provider, address(c.vesting)),
            c.token.totalSupply(),
            c.token.decimals(),
            c.vesting.nextScheduleId(),
            c.vesting.owner(),
            c.vesting.TOKEN(),
            schedule
        );
    }

    /// @notice 수동 약정에서 정한 단계별 잔고·승인·전체 약정과 시각별 지급액을 대조한다.
    function _assertState(Context memory c, uint256 phase) internal view {
        uint256 p = phase < 2 ? 1000 ether : phase >= 5 ? 400 ether : 0;
        uint256 b = phase < 3 ? 0 : phase == 3 ? 300 ether : phase < 6 ? 400 ether : 600 ether;
        uint256 claimed = phase < 3 ? 0 : phase == 3 ? 300 ether : phase < 6 ? 400 ether : 600 ether;
        assertEq(c.token.balanceOf(c.provider), p);
        assertEq(c.token.balanceOf(c.beneficiary), b);
        assertEq(c.token.balanceOf(address(c.vesting)), TOTAL - p - b);
        assertEq(c.token.totalSupply(), TOTAL);
        assertEq(c.token.decimals(), 18);
        assertEq(c.token.allowance(c.provider, address(c.vesting)), phase == 1 ? TOTAL : 0);
        assertEq(c.vesting.owner(), c.provider);
        assertEq(address(c.vesting.TOKEN()), address(c.token));
        assertEq(c.vesting.nextScheduleId(), phase < 2 ? 0 : 1);
        if (phase < 2) return;
        Vesting.Schedule memory expected = Vesting.Schedule(
            c.beneficiary,
            c.provider,
            TOTAL,
            claimed,
            uint64(c.start),
            20 days,
            100 days,
            phase >= 5 ? uint64(c.start + 60 days) : 0,
            phase >= 5
        );
        assertEq(abi.encode(c.vesting.getSchedule(c.id)), abi.encode(expected));
        uint256 effective = phase >= 5 ? c.start + 60 days : block.timestamp;
        uint256 vested = effective < c.start + 20 days
            ? 0
            : effective >= c.start + 100 days ? TOTAL : TOTAL * (effective - c.start) / 100 days;
        assertEq(c.vesting.vestedAmount(c.id), vested);
        assertEq(c.vesting.releasableAmount(c.id), vested - claimed);
    }

    /// @notice 행동에서 예상 호출자·대상·calldata·오류를 만든다. 실제 반환값을 정답으로 복사하지 않는다.
    function _request(Context memory c, Action a)
        internal
        pure
        returns (address sender, address to, bytes memory input, bytes memory error)
    {
        sender = a == Action.Cliff || a == Action.Claim30 || a == Action.WrongRevoke || a == Action.Claim40
            || a == Action.Claim100
            ? c.beneficiary
            : c.provider;
        to = a == Action.Mint || a == Action.Approve ? address(c.token) : address(c.vesting);
        if (a == Action.Mint) {
            input = abi.encodeCall(MockERC20.mint, (c.provider, TOTAL));
        } else if (a == Action.Approve) {
            input = abi.encodeCall(IERC20.approve, (address(c.vesting), TOTAL));
        } else if (a == Action.NoApproval || a == Action.InvalidRecipient || a == Action.Create) {
            input = abi.encodeCall(
                Vesting.createSchedule,
                (a == Action.InvalidRecipient ? address(0) : c.beneficiary, TOTAL, 0, 20 days, 100 days)
            );
        } else if (a == Action.WrongRevoke || a == Action.Revoke60) {
            input = abi.encodeCall(Vesting.revoke, (c.id));
        } else {
            input = abi.encodeCall(Vesting.claim, (c.id));
        }
        if (a == Action.NoApproval) {
            error =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(c.vesting), 0, TOTAL);
        } else if (a == Action.InvalidRecipient) {
            error = abi.encodeWithSelector(Vesting.InvalidBeneficiary.selector);
        } else if (a == Action.Cliff) {
            error = abi.encodeWithSelector(Vesting.NothingToClaim.selector);
        } else if (a == Action.WrongClaim) {
            error = abi.encodeWithSelector(Vesting.NotBeneficiary.selector);
        } else if (a == Action.WrongRevoke) {
            error = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, c.beneficiary);
        }
    }

    /// @notice 성공 단계에 대응하는 독립 기대 상태 번호를 반환한다. 실패는 직전 상태다.
    function _phase(Action a) internal pure returns (uint256) {
        return a <= Action.NoApproval
            ? 0
            : a <= Action.InvalidRecipient
                ? 1
                : a <= Action.Cliff
                    ? 2
                    : a <= Action.WrongRevoke ? 3 : a == Action.Claim40 ? 4 : a == Action.Revoke60 ? 5 : 6;
    }

    /// @notice 성공 이벤트의 전체 topics/data와 정확한 로그 개수를 대조한다.
    function _events(Context memory c, Action a, string memory json) internal view {
        uint256 amount = a == Action.Claim30
            ? 300 ether
            : a == Action.Claim40
                ? 100 ether
                : a == Action.Claim100 ? 200 ether : a == Action.Revoke60 ? 400 ether : TOTAL;
        address receiver = a == Action.Mint
            ? c.provider
            : a == Action.Approve || a == Action.Create
                ? address(c.vesting)
                : a == Action.Revoke60 ? c.provider : c.beneficiary;
        address from =
            a == Action.Mint ? address(0) : a == Action.Approve || a == Action.Create ? c.provider : address(c.vesting);
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = a == Action.Approve
            ? keccak256("Approval(address,address,uint256)")
            : keccak256("Transfer(address,address,uint256)");
        topics[1] = bytes32(uint256(uint160(from)));
        topics[2] = bytes32(uint256(uint160(receiver)));
        _event(json, 0, address(c.token), topics, abi.encode(amount));
        if (a == Action.Mint || a == Action.Approve) {
            assertFalse(vm.keyExistsJson(json, ".logs[1]"));
            return;
        }
        if (a == Action.Create) {
            topics = new bytes32[](4);
            topics[0] = keccak256("ScheduleCreated(uint256,address,address,uint256,uint64,uint64,uint64)");
            topics[1] = bytes32(c.id);
            topics[2] = bytes32(uint256(uint160(c.beneficiary)));
            topics[3] = bytes32(uint256(uint160(c.provider)));
            _event(json, 1, address(c.vesting), topics, abi.encode(TOTAL, c.start, uint256(20 days), uint256(100 days)));
        } else if (a == Action.Revoke60) {
            topics = new bytes32[](2);
            topics[0] = keccak256("ScheduleRevoked(uint256,uint256,uint256)");
            topics[1] = bytes32(c.id);
            _event(json, 1, address(c.vesting), topics, abi.encode(uint256(600 ether), uint256(400 ether)));
        } else {
            topics = new bytes32[](3);
            topics[0] = keccak256("TokensClaimed(uint256,address,uint256)");
            topics[1] = bytes32(c.id);
            topics[2] = bytes32(uint256(uint160(c.beneficiary)));
            _event(json, 1, address(c.vesting), topics, abi.encode(amount));
        }
        assertFalse(vm.keyExistsJson(json, ".logs[2]"), "exact log count");
    }

    /// @notice receipt의 한 로그를 typed JSON으로 읽어 발행 주소와 인자를 대조한다.
    function _event(string memory json, uint256 i, address emitter, bytes32[] memory topics, bytes memory data)
        internal
        pure
    {
        string memory key = string.concat(".logs[", vm.toString(i), "]");
        assertEq(vm.parseJsonAddress(json, string.concat(key, ".address")), emitter);
        assertEq(abi.encode(vm.parseJsonBytes32Array(json, string.concat(key, ".topics"))), abi.encode(topics));
        assertEq(vm.parseJsonBytes(json, string.concat(key, ".data")), data);
    }

    /// @notice Cast가 읽은 receipt의 hash를 실제 전송 hash와 대조한다. 누락은 실패다.
    function _receipt(string memory dir, Action action, bytes32 hash) internal view returns (string memory json) {
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        json = vm.readFile(string.concat(dir, "/mined-", vm.toString(uint256(action)), ".log"));
        assertEq(vm.parseJsonBytes32(json, ".transactionHash"), hash);
    }

    /// @notice Cast가 읽은 블록과 receipt의 hash/번호를 연결하고 실제 timestamp를 반환한다.
    function _timestamp(string memory dir, Action action, string memory receipt) internal view returns (uint256) {
        return _blockTimestamp(dir, vm.toString(uint256(action)), receipt);
    }

    /// @notice 배포와 일반 거래 모두 실제 블록 JSON을 receipt와 연결한다.
    function _blockTimestamp(string memory dir, string memory label, string memory receipt)
        internal
        view
        returns (uint256)
    {
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(string.concat(dir, "/block-", label, ".log"));
        assertEq(vm.parseJsonBytes32(json, ".hash"), vm.parseJsonBytes32(receipt, ".blockHash"));
        assertEq(vm.parseJsonUint(json, ".number"), vm.parseJsonUint(receipt, ".blockNumber"));
        return vm.parseJsonUint(json, ".timestamp");
    }

    /// @notice 단계별 실제 관측값을 별도 JSON에 보존한다. raw는 최소 단위, tokens는 18자리 소수 표시다.
    function _recordState(string memory dir, string memory label, Context memory c) internal {
        string memory key = "observed-state";
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeUint(key, "timestamp", block.timestamp);
        vm.serializeAddress(key, "provider", c.provider);
        vm.serializeAddress(key, "beneficiary", c.beneficiary);
        vm.serializeAddress(key, "token", address(c.vesting.TOKEN()));
        vm.serializeAddress(key, "vesting", address(c.vesting));
        vm.serializeAddress(key, "owner", c.vesting.owner());
        vm.serializeUint(key, "decimals", c.token.decimals());
        _amount(key, "providerBalance", c.token.balanceOf(c.provider));
        _amount(key, "vestingBalance", c.token.balanceOf(address(c.vesting)));
        _amount(key, "beneficiaryBalance", c.token.balanceOf(c.beneficiary));
        _amount(key, "allowance", c.token.allowance(c.provider, address(c.vesting)));
        _amount(key, "totalSupply", c.token.totalSupply());
        uint256 next = c.vesting.nextScheduleId();
        vm.serializeUint(key, "nextScheduleId", next);
        vm.serializeBool(key, "scheduleExists", next != 0);
        if (next != 0) {
            Vesting.Schedule memory s = c.vesting.getSchedule(c.id);
            vm.serializeUint(key, "scheduleId", c.id);
            vm.serializeAddress(key, "scheduleBeneficiary", s.beneficiary);
            vm.serializeAddress(key, "scheduleFunder", s.funder);
            _amount(key, "totalAmount", s.totalAmount);
            _amount(key, "claimedAmount", s.claimedAmount);
            vm.serializeUint(key, "startTime", s.startTime);
            vm.serializeUint(key, "cliffDuration", s.cliffDuration);
            vm.serializeUint(key, "duration", s.duration);
            vm.serializeUint(key, "revokedAt", s.revokedAt);
            vm.serializeBool(key, "revoked", s.revoked);
            uint256 vested = c.vesting.vestedAmount(c.id);
            _amount(key, "vestedAmount", vested);
            _amount(key, "releasableAmount", c.vesting.releasableAmount(c.id));
            _amount(key, "outstanding", (s.revoked ? vested : s.totalAmount) - s.claimedAmount);
            _amount(key, "refundedAmount", s.revoked ? s.totalAmount - vested : 0);
        }
        string memory json = vm.serializeString(key, "phase", label);
        vm.writeJson(json, string.concat(dir, "/state-", label, ".json"));
        if (keccak256(bytes(label)) == keccak256("after-11")) {
            vm.writeJson(json, string.concat(dir, "/final-settlement.json"));
        }
    }

    /// @notice 실제 정수와 소수 18자리 토큰 수를 함께 저장하고 사람이 읽을 값을 출력한다.
    function _amount(string memory key, string memory field, uint256 value) internal {
        vm.serializeUint(key, string.concat(field, "Raw"), value);
        bytes memory fraction = bytes(vm.toString(value % 1 ether));
        bytes memory padded = new bytes(18);
        // ASCII 문자 '0'의 한 바이트 값이다. 문자열을 잘라 변환하지 않고 사용한다.
        bytes1 zero = hex"30";
        for (uint256 i; i < 18; ++i) {
            padded[i] = i < 18 - fraction.length ? zero : fraction[i - (18 - fraction.length)];
        }
        string memory display = string.concat(vm.toString(value / 1 ether), ".", string(padded));
        vm.serializeString(key, string.concat(field, "Tokens"), display);
        console2.log(field, display);
    }

    /// @notice 같은 실행의 구조화된 context를 읽는다.
    function _context(string memory dir) internal view returns (Context memory c) {
        // 로컬 실행 기록을 읽어 실제 RPC 결과와 대조한다. 접근은 cache/local-vesting 안으로 제한된다.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(string.concat(dir, "/context.json"));
        c.provider = vm.parseJsonAddress(json, ".provider");
        c.beneficiary = vm.parseJsonAddress(json, ".beneficiary");
        c.token = MockERC20(vm.parseJsonAddress(json, ".token"));
        c.vesting = Vesting(vm.parseJsonAddress(json, ".vesting"));
        c.id = vm.parseJsonUint(json, ".id");
        c.start = vm.parseJsonUint(json, ".start");
    }

    /// @notice 실제 실행 주소와 ID/S를 JSON에 쓰고 새로운 언어의 파서를 요구하지 않는다.
    function _write(string memory dir, Context memory c) internal {
        vm.serializeAddress("context", "provider", c.provider);
        vm.serializeAddress("context", "beneficiary", c.beneficiary);
        vm.serializeAddress("context", "token", address(c.token));
        vm.serializeAddress("context", "vesting", address(c.vesting));
        vm.serializeUint("context", "id", c.id);
        vm.writeJson(vm.serializeUint("context", "start", c.start), string.concat(dir, "/context.json"));
    }
}
