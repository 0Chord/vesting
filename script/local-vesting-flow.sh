#!/usr/bin/env bash
# Anvil·Cast·Forge로 실제 로컬 거래를 실행한다. JSON·약정·자금 검사는 CheckLocal.s.sol이 맡는다.
set -euo pipefail
flow_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$flow_root"
flow_port=18545
flow_through=full
while (($#)); do
    case "$1" in
        --port) flow_port="${2:?포트 필요}"; shift 2 ;;
        --through) flow_through="${2:?create 또는 full 필요}"; shift 2 ;;
        *) printf '알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$flow_port" =~ ^[1-9][0-9]{0,4}$ ]] && ((flow_port < 65536)) || exit 2
[[ "$flow_through" == create || "$flow_through" == full ]] || exit 2
mkdir -p cache/local-vesting
flow_dir="$(mktemp -d "$flow_root/cache/local-vesting/run-XXXXXXXX")"
flow_rpc="http://127.0.0.1:$flow_port"
export ETH_RPC_TIMEOUT=5
flow_node_pid=
flow_child_pid=
flow_signal=0
flow_error=
flow_status=running
flow_labels=("1,000 발행" "승인 전 생성 거절" "승인: 아직 예치되지 않음" "생성 실패: 이전 승인 유지" "생성 성공: 1,000 예치" "19일 청구 거절" "30일 300 청구" "비수령자 청구 거절" "비관리자 취소 거절" "40일 추가 100 청구" "60일 취소: 400 반환" "100일 남은 200 청구")

# 신호는 요청만 기록한다. 정리 중 첫 신호도 정리 자체를 끊지 않는다.
request_stop() { if ((flow_signal == 0)); then flow_signal="$1"; fi; }
trap 'request_stop 143' TERM
trap 'request_stop 130' INT
trap 'request_stop 129' HUP

# 자기 자식만 종료하고 제한 시간 뒤에도 남으면 회수한다. 원래 실패 원인은 보존한다.
stop_child() {
    local child="$1" deadline
    [[ -n "$child" ]] || return 0
    kill -TERM "$child" 2>/dev/null || true
    deadline=$((SECONDS + 5))
    while kill -0 "$child" 2>/dev/null && ((SECONDS < deadline)); do sleep 0.05; done
    if kill -0 "$child" 2>/dev/null; then kill -KILL "$child" 2>/dev/null || true; fi
    wait "$child" 2>/dev/null || true
}

# EXIT에서도 신호를 예외처럼 던지지 않는다. 노드 종료 후 결과와 종료 코드를 고정한다.
cleanup() {
    local code=$?
    trap - EXIT
    set +e
    stop_child "$flow_child_pid"
    stop_child "$flow_node_pid"
    trap '' TERM INT HUP
    if ((flow_signal != 0 && code == 0)); then code="$flow_signal"; fi
    local stopped=true
    if [[ -n "$flow_node_pid" ]] && kill -0 "$flow_node_pid" 2>/dev/null; then stopped=false; code=1; fi
    if ((code != 0)); then flow_status=failed; fi
    printf 'status=%s\nexit_code=%s\nshutdown_code=%s\nerror=%s\nanvil_pid=%s\nanvil_stopped=%s\n' \
        "$flow_status" "$code" "$flow_signal" "$flow_error" "$flow_node_pid" "$stopped" > "$flow_dir/summary.txt"
    printf '검증 기록: %s/summary.txt\n' "$flow_dir"
    exit "$code"
}
trap cleanup EXIT
printf '실행 기록: %s\n' "$flow_dir"

# 모든 외부 명령의 종료 상태를 확인한다. 신호로 wait가 중단되면 자식 정리를 거쳐 종료한다.
run() {
    local label="$1" code=0; shift
    if ((flow_signal != 0)); then exit "$flow_signal"; fi
    printf '%q ' "$@" >> "$flow_dir/commands.log"; printf '\n' >> "$flow_dir/commands.log"
    "$@" > "$flow_dir/$label.log" 2>&1 &
    flow_child_pid=$!
    if wait "$flow_child_pid"; then code=0; else code=$?; fi
    if ((flow_signal != 0)); then exit "$flow_signal"; fi
    flow_child_pid=
    if ((code != 0)); then
        flow_error="$label"
        tail -20 "$flow_dir/$label.log" >&2
        return "$code"
    fi
}

# 코드는 실행하지 않고 도구의 출력만 지정 변수에 담는다.
capture() {
    local destination="$1" label="$2"; shift 2
    run "$label" "$@"
    printf -v "$destination" '%s' "$(< "$flow_dir/$label.log")"
}

# Cast가 ABI로 해독한 두 주소를 읽는다. 임의 JSON/console 문자열에서 주소를 추측하지 않는다.
read_pair() {
    local path="$1" first="$2" second="$3" left right
    run decode-pair cast abi-decode 'result()(address,address)' "$(< "$path")"
    { read -r left; read -r right; } < "$flow_dir/decode-pair.log"
    [[ "$left" =~ ^0x[0-9a-fA-F]{40}$ && "$right" =~ ^0x[0-9a-fA-F]{40}$ ]]
    printf -v "$first" '%s' "$left"; printf -v "$second" '%s' "$right"
}

# Solidity 검사 스크립트는 RPC의 현재 상태를 읽기만 하며 broadcast하지 않는다.
check() {
    local label="$1" signature="$2"; shift 2
    run "$label" forge script script/CheckLocal.s.sol:CheckLocal --rpc-url "$flow_rpc" --sig "$signature" "$flow_dir" "$@"
}

# 실제 거래 hash를 기록하고 Foundry로 receipt·trace·이벤트·시각·보존 상태를 검사한다.
send_action() {
    local action="$1" actor="$2" destination="$3"; shift 3
    check "before-$action" 'snapshot(string,uint8)' "$action"
    capture flow_hash "send-$action" cast send "$destination" "$@" --from "$actor" --unlocked --gas-limit 2000000 --async --rpc-url "$flow_rpc"
    [[ "$flow_hash" =~ ^0x[0-9a-fA-F]{64}$ ]]
    run "mined-$action" cast receipt "$flow_hash" --rpc-url "$flow_rpc" --async --json
    run "tx-$action" cast tx "$flow_hash" --rpc-url "$flow_rpc" --json
    capture flow_block_hash "block-hash-$action" cast receipt "$flow_hash" blockHash --rpc-url "$flow_rpc" --async
    run "block-$action" cast block "$flow_block_hash" --rpc-url "$flow_rpc" --json
    case "$action" in
        1|3|5|7|8) run "trace-rpc-$action" cast rpc debug_traceTransaction "$flow_hash" '{"tracer":"callTracer"}' --rpc-url "$flow_rpc" ;;
    esac
    check "verify-$action" 'verify(string,uint8,bytes32)' "$action" "$flow_hash"
    cat "$flow_dir/verify-$action.log"
    printf '%s\t%s\n' "$action" "$flow_hash" >> "$flow_dir/transactions.tsv"
    printf '%s 검증 통과: %s\n' "${flow_labels[$action]}" "$flow_hash"
}

# 다음 변경 거래에만 목표 시각을 적용한다. 중간에 mine/다른 거래를 넣지 않는다.
at_day() { run "time-$1" cast rpc evm_setNextBlockTimestamp "$((flow_start + $1 * 86400))" --rpc-url "$flow_rpc"; }

for flow_tool in anvil forge cast; do run "version-$flow_tool" "$flow_tool" --version; done
run source git rev-parse HEAD
run source-hashes shasum -a 256 script/DeployLocal.s.sol script/CheckLocal.s.sol script/local-vesting-flow.sh foundry.toml
# 기존 노드의 포트는 거절한다. 새 프로세스가 준비 전에 종료돼도 다른 노드로 진행하지 않는다.
if cast chain-id --rpc-url "$flow_rpc" >/dev/null 2>&1; then flow_error=port-in-use; exit 1; fi
anvil --host 127.0.0.1 --port "$flow_port" --chain-id 31337 --timestamp 1700000000 --silent > "$flow_dir/anvil.log" 2>&1 &
flow_node_pid=$!
printf '%s\n' "$flow_node_pid" > "$flow_dir/anvil.pid"
flow_ready=0
for ((flow_attempt=0; flow_attempt<100; flow_attempt++)); do
    kill -0 "$flow_node_pid" 2>/dev/null || { flow_error=anvil-startup; exit 1; }
    if cast chain-id --rpc-url "$flow_rpc" > "$flow_dir/chain-id.log" 2>/dev/null; then flow_ready=1; break; fi
    if ((flow_signal != 0)); then exit "$flow_signal"; fi
    sleep 0.05
done
((flow_ready == 1)) || { flow_error=rpc-timeout; exit 1; }
[[ "$(< "$flow_dir/chain-id.log")" == 31337 ]]
[[ "$(cast block-number --rpc-url "$flow_rpc")" == 0 ]]
run accounts-rpc cast rpc eth_accounts --rpc-url "$flow_rpc"
run node-info cast rpc anvil_nodeInfo --rpc-url "$flow_rpc"
check accounts 'accounts(string)'
read_pair "$flow_dir/roles.abi" flow_provider flow_beneficiary
export FOUNDRY_BROADCAST="$flow_dir/broadcast"
run deploy forge script script/DeployLocal.s.sol:DeployLocal --sig 'run(address)' "$flow_provider" --sender "$flow_provider" --unlocked --broadcast --slow --rpc-url "$flow_rpc"
check deployment 'deployment(string)'
run decode-deployment-hashes cast abi-decode 'result()(bytes32,bytes32)' "$(< "$flow_dir/deployment-hashes.abi")"
{ read -r flow_first_hash; read -r flow_second_hash; } < "$flow_dir/decode-deployment-hashes.log"
run deployment-0 cast receipt "$flow_first_hash" --async --json --rpc-url "$flow_rpc"
run deployment-1 cast receipt "$flow_second_hash" --async --json --rpc-url "$flow_rpc"
for flow_deployment in 0 1; do
    if ((flow_deployment == 0)); then flow_deploy_hash="$flow_first_hash"; else flow_deploy_hash="$flow_second_hash"; fi
    capture flow_deploy_block "deployment-block-hash-$flow_deployment" cast receipt "$flow_deploy_hash" blockHash --async --rpc-url "$flow_rpc"
    run "block-deployment-$flow_deployment" cast block "$flow_deploy_block" --json --rpc-url "$flow_rpc"
done
check prepare 'prepare(string)'
read_pair "$flow_dir/addresses.abi" flow_token flow_vesting
flow_total=1000000000000000000000
send_action 0 "$flow_provider" "$flow_token" 'mint(address,uint256)' "$flow_provider" "$flow_total"
send_action 1 "$flow_provider" "$flow_vesting" 'createSchedule(address,uint256,uint64,uint64,uint64)' "$flow_beneficiary" "$flow_total" 0 1728000 8640000
send_action 2 "$flow_provider" "$flow_token" 'approve(address,uint256)' "$flow_vesting" "$flow_total"
send_action 3 "$flow_provider" "$flow_vesting" 'createSchedule(address,uint256,uint64,uint64,uint64)' 0x0000000000000000000000000000000000000000 "$flow_total" 0 1728000 8640000
capture flow_id_raw schedule-id cast call "$flow_vesting" 'nextScheduleId()' --rpc-url "$flow_rpc"
capture flow_id decode-id cast to-dec "$flow_id_raw"
send_action 4 "$flow_provider" "$flow_vesting" 'createSchedule(address,uint256,uint64,uint64,uint64)' "$flow_beneficiary" "$flow_total" 0 1728000 8640000
capture flow_start decode-start cast to-dec "$(< "$flow_dir/start.abi")"
if [[ "$flow_through" == full ]]; then
    at_day 19
    send_action 5 "$flow_beneficiary" "$flow_vesting" 'claim(uint256)' "$flow_id"
    at_day 30
    send_action 6 "$flow_beneficiary" "$flow_vesting" 'claim(uint256)' "$flow_id"
    capture flow_claim_block claim-block cast receipt "$flow_hash" blockNumber --rpc-url "$flow_rpc"
    capture flow_block_before block-before cast block-number --rpc-url "$flow_rpc"
    run duplicate forge script script/CheckLocal.s.sol:CheckLocal --sig 'duplicate(string)' "$flow_dir" --rpc-url "$flow_rpc" --fork-block-number "$flow_claim_block"
    capture flow_block_after block-after cast block-number --rpc-url "$flow_rpc"
    [[ "$flow_block_before" == "$flow_block_after" ]]
    printf 'fork-simulation\t%s\n' "$flow_claim_block" > "$flow_dir/duplicate.tsv"
    send_action 7 "$flow_provider" "$flow_vesting" 'claim(uint256)' "$flow_id"
    send_action 8 "$flow_beneficiary" "$flow_vesting" 'revoke(uint256)' "$flow_id"
    at_day 40
    send_action 9 "$flow_beneficiary" "$flow_vesting" 'claim(uint256)' "$flow_id"
    at_day 60
    send_action 10 "$flow_provider" "$flow_vesting" 'revoke(uint256)' "$flow_id"
    at_day 100
    send_action 11 "$flow_beneficiary" "$flow_vesting" 'claim(uint256)' "$flow_id"
fi
if ((flow_signal != 0)); then exit "$flow_signal"; fi
flow_status=complete
if [[ "$flow_through" == create ]]; then flow_status=creation-complete; fi
