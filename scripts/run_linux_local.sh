#!/usr/bin/env bash
set -euo pipefail

# Run a full local experiment on one Linux machine.
# Defaults to 16x10 so it is a safe first check; override SHARD_NUM=64 for 64x10.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

command -v python3 >/dev/null || {
  echo "python3 is required" >&2
  exit 1
}

SHARD_NUM="${SHARD_NUM:-16}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
if [[ -z "${PBFT_START_DELAY_MS:-}" ]]; then
  if ((SHARD_NUM * NODES_IN_SHARD >= 320)); then
    PBFT_START_DELAY_MS=60000
  else
    PBFT_START_DELAY_MS=5000
  fi
fi
PBFT_TIMEOUT_MS="${PBFT_TIMEOUT_MS:-300000}"
READINESS_TIMEOUT_MS="${READINESS_TIMEOUT_MS:-180000}"
SUPERVISOR_START_MARGIN_MS="${SUPERVISOR_START_MARGIN_MS:-0}"
WATCHDOG_SECONDS="${WATCHDOG_SECONDS:-3600}"
BUILD="${BUILD:-1}"
KILL_EXISTING="${KILL_EXISTING:-1}"
LOCALHOST_IPTABLE="${LOCALHOST_IPTABLE:-1}"
RUN_ROOT="${RUN_ROOT:-$REPO_ROOT/run-linux-local-${SHARD_NUM}x${NODES_IN_SHARD}-$(date +%Y%m%d-%H%M%S)}"

if [[ "$BUILD" == "1" ]]; then
  command -v go >/dev/null || {
    echo "go is required when BUILD=1" >&2
    exit 1
  }
fi

mkdir -p "$RUN_ROOT"
cp ipTable.json "$RUN_ROOT/ipTable.before.json"
cp paramsConfig.json "$RUN_ROOT/params-a.json"
cp paramsConfig.json "$RUN_ROOT/params-b.json"
cp paramsConfig.json "$RUN_ROOT/params-c.json"

pids=()
watchdog_pid=""
finished=0
emulator_pattern='(^|[[:space:]/])block-emulator-mod([[:space:]]|$)'

cleanup() {
  local ec=$?
  trap - EXIT INT TERM
  if [[ -n "${watchdog_pid:-}" ]]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  if [[ "$finished" != "1" ]]; then
    if ((${#pids[@]} > 0)); then
      kill "${pids[@]}" 2>/dev/null || true
    fi
    pgrep -f "$emulator_pattern" | xargs -r kill -TERM 2>/dev/null || true
  fi
  cp "$RUN_ROOT/ipTable.before.json" ipTable.json 2>/dev/null || true
  exit "$ec"
}
trap cleanup EXIT INT TERM

if [[ "$KILL_EXISTING" == "1" ]]; then
  pgrep -f "$emulator_pattern" | xargs -r kill -TERM 2>/dev/null || true
  sleep 2
fi

if [[ "$BUILD" == "1" ]]; then
  echo "[local] building block-emulator-mod"
  go build -o block-emulator-mod .
fi

dataset_file="${DATASET_FILE:-$(python3 - <<'PY'
import json
with open("paramsConfig.json", encoding="utf-8") as f:
    print(json.load(f).get("DatasetFile", ""))
PY
)}"
if [[ -n "$dataset_file" && ! -f "$dataset_file" ]]; then
  echo "[local] missing dataset: $dataset_file" >&2
  echo "[local] copy it into place or set DATASET_FILE=/path/to/file" >&2
  exit 2
fi

if [[ "$LOCALHOST_IPTABLE" == "1" ]]; then
  python3 - "$SHARD_NUM" "$NODES_IN_SHARD" <<'PY'
import json
import sys

shard_num = int(sys.argv[1])
nodes_in_shard = int(sys.argv[2])
supervisor_shard = "2147483647"

with open("ipTable.json", "r", encoding="utf-8") as f:
    ip_table = json.load(f)

for sid in range(shard_num):
    shard = ip_table[str(sid)]
    for nid in range(nodes_in_shard):
        _, port = shard[str(nid)].rsplit(":", 1)
        shard[str(nid)] = f"127.0.0.1:{port}"

ip_table.setdefault(supervisor_shard, {})
ip_table[supervisor_shard]["0"] = "127.0.0.1:38800"

with open("ipTable.json", "w", encoding="utf-8") as f:
    json.dump(ip_table, f, indent=2)
    f.write("\n")
PY
fi

common_env=(
  SHARD_NUM="$SHARD_NUM"
  NODES_IN_SHARD="$NODES_IN_SHARD"
  PBFT_START_DELAY_MS="$PBFT_START_DELAY_MS"
  PBFT_TIMEOUT_MS="$PBFT_TIMEOUT_MS"
  READINESS_TIMEOUT_MS="$READINESS_TIMEOUT_MS"
  SUPERVISOR_START_MARGIN_MS="$SUPERVISOR_START_MARGIN_MS"
)

optional_env=(
  CONSENSUS_METHOD
  BRIDGE_OVERLAY_ENABLED
  BRIDGE_OVERLAY_MIN_DEGREE
  BRIDGE_OVERLAY_MAX_DEGREE
  BRIDGE_OVERLAY_SEED
  BRIDGE_KEY_ROOT_DIR
  BLOCK_INTERVAL_MS
  BLOCK_SIZE
  INJECT_SPEED
  TOTAL_DATA_SIZE
  TX_BATCH_SIZE
  DATASET_FILE
)
for name in "${optional_env[@]}"; do
  if [[ -n "${!name:-}" ]]; then
    common_env+=("$name=${!name}")
  fi
done

echo "[local] run_root=$RUN_ROOT"
echo "[local] shards=$SHARD_NUM nodes_per_shard=$NODES_IN_SHARD"
echo "[local] start delay=${PBFT_START_DELAY_MS}ms timeout=${PBFT_TIMEOUT_MS}ms"

env "${common_env[@]}" CONFIG_FILE="$RUN_ROOT/params-b.json" LOG_ROOT="$RUN_ROOT/machine-b" ./scripts/launch_machine_b.sh >"$RUN_ROOT/machine-b.launch.out" 2>&1 &
pids+=("$!")

env "${common_env[@]}" CONFIG_FILE="$RUN_ROOT/params-c.json" LOG_ROOT="$RUN_ROOT/machine-c" ./scripts/launch_machine_c.sh >"$RUN_ROOT/machine-c.launch.out" 2>&1 &
pids+=("$!")

sleep 2

env "${common_env[@]}" CONFIG_FILE="$RUN_ROOT/params-a.json" LOG_ROOT="$RUN_ROOT/machine-a" ./scripts/launch_machine_a.sh >"$RUN_ROOT/machine-a.launch.out" 2>&1 &
pids+=("$!")

(
  sleep "$WATCHDOG_SECONDS"
  echo "[local] watchdog timeout after ${WATCHDOG_SECONDS}s; terminating run" >>"$RUN_ROOT/watchdog.out"
  kill "${pids[@]}" 2>/dev/null || true
  pgrep -f "$emulator_pattern" | xargs -r kill -TERM 2>/dev/null || true
) &
watchdog_pid="$!"

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=$?
done

finished=1
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

echo "[local] statuses complete; exit status=$status"
echo "[local] logs: $RUN_ROOT"

result_dir="$RUN_ROOT/machine-a/expTest/result/supervisor_measureOutput"
if [[ -d "$result_dir" ]]; then
  for file in Average_TPS Transaction_Confirm_Latency CrossTransaction_ratio Tx_number; do
    path="$result_dir/$file.csv"
    if [[ -f "$path" ]]; then
      echo "== $file =="
      cat "$path"
    fi
  done
else
  echo "[local] no result directory found yet: $result_dir" >&2
fi

exit "$status"
