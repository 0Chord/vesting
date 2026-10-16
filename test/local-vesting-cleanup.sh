#!/usr/bin/env bash
# 실제 새 Anvil에서 정상/실패 정리 시작의 첫 SIGTERM과 원래 오류 보존을 검사한다.
set -euo pipefail
cleanup_test_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$cleanup_test_root"
mkdir -p cache/local-vesting
cleanup_test_dir="$(mktemp -d "$cleanup_test_root/cache/local-vesting/cleanup-test-XXXXXXXX")"
cleanup_test_pids=()
# 회귀가 생겨도 시험 실행의 기록에서 확인한 자기 노드만 회수한다.
cleanup_test_finish() {
    for cleanup_test_pid in "${cleanup_test_pids[@]:-}"; do
        [[ -n "$cleanup_test_pid" ]] || continue
        kill -TERM "$cleanup_test_pid" 2>/dev/null || true
    done
}
trap cleanup_test_finish EXIT
# 제품에 훅을 넣지 않는다. 시험 프로세스의 kill 직전에 신호가 오는 시점만 고정한다.
cat > "$cleanup_test_dir/hook.bash" <<'HOOK'
kill() {
    if [[ "${1:-}" == -TERM && -n "${flow_node_pid:-}" && "${2:-}" == "$flow_node_pid" ]]; then
        builtin kill -TERM "$$"
    fi
    builtin kill "$@"
}
forge() {
    if [[ "${CLEANUP_TEST_MODE:-}" == failure && "$*" == *'--sig verify(string,uint8,bytes32)'* ]]; then
        printf 'intentional cleanup test: original tool failure\n' >&2
        return 23
    fi
    command forge "$@"
}
HOOK
cleanup_test_index=0
for cleanup_test_mode in success failure; do
    cleanup_test_port=$(( ${LOCAL_TEST_PORT_BASE:-18565} + cleanup_test_index ))
    cleanup_test_index=$((cleanup_test_index + 1))
    cleanup_test_code=0
    if BASH_ENV="$cleanup_test_dir/hook.bash" CLEANUP_TEST_MODE="$cleanup_test_mode" \
        bash script/local-vesting-flow.sh --through create --port "$cleanup_test_port" > "$cleanup_test_dir/$cleanup_test_mode.log" 2>&1; then
        cleanup_test_code=0
    else
        cleanup_test_code=$?
    fi
    cleanup_test_run="$(sed -n 's/^실행 기록: //p' "$cleanup_test_dir/$cleanup_test_mode.log" | head -1)"
    [[ -n "$cleanup_test_run" ]]
    cleanup_test_pid="$(< "$cleanup_test_run/anvil.pid")"
    cleanup_test_pids+=("$cleanup_test_pid")
    [[ -f "$cleanup_test_run/summary.txt" ]]
    grep -qx 'status=failed' "$cleanup_test_run/summary.txt"
    grep -qx 'shutdown_code=143' "$cleanup_test_run/summary.txt"
    grep -qx 'anvil_stopped=true' "$cleanup_test_run/summary.txt"
    if [[ "$cleanup_test_mode" == success ]]; then
        [[ "$cleanup_test_code" == 143 ]]
        grep -qx 'error=' "$cleanup_test_run/summary.txt"
        [[ "$(wc -l < "$cleanup_test_run/transactions.tsv" | tr -d ' ')" == 5 ]]
    else
        [[ "$cleanup_test_code" == 23 ]]
        grep -qx 'error=verify-0' "$cleanup_test_run/summary.txt"
    fi
    # 시험용 보조 정리 전에 제품이 실제 PID·RPC를 종료했는지 확인한다.
    if kill -0 "$cleanup_test_pid" 2>/dev/null; then printf '노드가 남아 있음\n' >&2; exit 1; fi
    if cast chain-id --rpc-url "http://127.0.0.1:$cleanup_test_port" --rpc-timeout 2 >/dev/null 2>&1; then exit 1; fi
    printf '%s 정리 중 첫 신호·기록·노드 종료 검증 통과\n' "$cleanup_test_mode"
done
printf '종료 회귀 2개 통과. 기록: %s\n' "$cleanup_test_dir"
