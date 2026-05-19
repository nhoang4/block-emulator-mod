#!/usr/bin/env bash
set -euo pipefail

# Machine A: launches the first shard range and then starts the supervisor.
# Run from the repo root or from this script's directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

command -v python3 >/dev/null || {
  echo "python3 is required by this launch script" >&2
  exit 1
}

BIN="${BIN:-./block-emulator-mod}"
CONFIG_FILE="${CONFIG_FILE:-paramsConfig.json}"
MACHINE_NAME="${MACHINE_NAME:-machine-a}"

SHARD_NUM="${SHARD_NUM:-64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
SHARD_START="${SHARD_START:-0}"
SHARD_END="${SHARD_END:-$(((SHARD_NUM + 2) / 3 - 1))}"

PBFT_TIMEOUT_MS="${PBFT_TIMEOUT_MS:-300000}"
PBFT_START_DELAY_MS="${PBFT_START_DELAY_MS:-180000}"
SUPERVISOR_START_MARGIN_MS="${SUPERVISOR_START_MARGIN_MS:-10000}"
READINESS_TIMEOUT_MS="${READINESS_TIMEOUT_MS:-300000}"
LOG_ROOT="${LOG_ROOT:-run_logs/${MACHINE_NAME}-$(date +%Y%m%d-%H%M%S)}"

# Optional experiment overrides. Leave unset to preserve paramsConfig.json values.
CONSENSUS_METHOD="${CONSENSUS_METHOD:-}"
BRIDGE_OVERLAY_ENABLED="${BRIDGE_OVERLAY_ENABLED:-}"
BRIDGE_OVERLAY_MIN_DEGREE="${BRIDGE_OVERLAY_MIN_DEGREE:-}"
BRIDGE_OVERLAY_MAX_DEGREE="${BRIDGE_OVERLAY_MAX_DEGREE:-}"
BRIDGE_OVERLAY_SEED="${BRIDGE_OVERLAY_SEED:-}"
BRIDGE_KEY_ROOT_DIR="${BRIDGE_KEY_ROOT_DIR:-}"
BLOCK_INTERVAL_MS="${BLOCK_INTERVAL_MS:-}"
BLOCK_SIZE="${BLOCK_SIZE:-}"
INJECT_SPEED="${INJECT_SPEED:-}"
TOTAL_DATA_SIZE="${TOTAL_DATA_SIZE:-}"
TX_BATCH_SIZE="${TX_BATCH_SIZE:-}"
DATASET_FILE="${DATASET_FILE:-}"

mkdir -p "$LOG_ROOT"
cp "$CONFIG_FILE" "$LOG_ROOT/paramsConfig.before.json"

pids=()
supervisor_pid=""

cleanup() {
  local ec=$?
  trap - EXIT INT TERM
  if [[ -n "${supervisor_pid:-}" ]]; then
    kill "$supervisor_pid" 2>/dev/null || true
  fi
  if ((${#pids[@]} > 0)); then
    kill "${pids[@]}" 2>/dev/null || true
  fi
  cp "$LOG_ROOT/paramsConfig.before.json" "$CONFIG_FILE" 2>/dev/null || true
  exit "$ec"
}
trap cleanup EXIT INT TERM

python3 - "$CONFIG_FILE" "$LOG_ROOT/expTest" "$SHARD_NUM" "$NODES_IN_SHARD" "$PBFT_TIMEOUT_MS" "$PBFT_START_DELAY_MS" <<'PY'
import json
import os
import sys

config_path, exp_dir, shard_num, nodes_in_shard, pbft_timeout, pbft_start_delay = sys.argv[1:]
with open(config_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
cfg["ShardNum"] = int(shard_num)
cfg["NodesInShard"] = int(nodes_in_shard)
cfg["ExpDataRootDir"] = exp_dir
cfg["PbftViewChangeTimeOut"] = int(pbft_timeout)
cfg["PbftStartDelay"] = int(pbft_start_delay)

def set_int(key, env_key):
    value = os.environ.get(env_key, "")
    if value != "":
        cfg[key] = int(value)

def set_string(key, env_key):
    value = os.environ.get(env_key, "")
    if value != "":
        cfg[key] = value

for key, env_key in (
    ("ConsensusMethod", "CONSENSUS_METHOD"),
    ("BridgeOverlayEnabled", "BRIDGE_OVERLAY_ENABLED"),
    ("BridgeOverlayBuildMode", "BRIDGE_OVERLAY_BUILD_MODE"),
    ("BridgeOverlayMinDegree", "BRIDGE_OVERLAY_MIN_DEGREE"),
    ("BridgeOverlayMaxDegree", "BRIDGE_OVERLAY_MAX_DEGREE"),
    ("BridgeOverlaySeed", "BRIDGE_OVERLAY_SEED"),
    ("Block_Interval", "BLOCK_INTERVAL_MS"),
    ("BlockSize", "BLOCK_SIZE"),
    ("InjectSpeed", "INJECT_SPEED"),
    ("TotalDataSize", "TOTAL_DATA_SIZE"),
    ("TxBatchSize", "TX_BATCH_SIZE"),
):
    set_int(key, env_key)

set_string("BridgeKeyRootDir", "BRIDGE_KEY_ROOT_DIR")
set_string("DatasetFile", "DATASET_FILE")

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

export PARAMS_CONFIG="$CONFIG_FILE"
cp "$CONFIG_FILE" "$LOG_ROOT/paramsConfig.used.json"

echo "[$MACHINE_NAME] launching shards ${SHARD_START}..${SHARD_END}, nodes 0..$((NODES_IN_SHARD - 1))"
echo "[$MACHINE_NAME] shard_num=$SHARD_NUM nodes_in_shard=$NODES_IN_SHARD pbft_timeout_ms=$PBFT_TIMEOUT_MS pbft_start_delay_ms=$PBFT_START_DELAY_MS"
echo "[$MACHINE_NAME] params_config=$PARAMS_CONFIG"

for ((s = SHARD_START; s <= SHARD_END; s++)); do
  for ((n = 0; n < NODES_IN_SHARD; n++)); do
    "$BIN" -n "$n" -N "$NODES_IN_SHARD" -s "$s" -S "$SHARD_NUM" >"$LOG_ROOT/node_s${s}_n${n}.out" 2>&1 &
    pids+=("$!")
  done
done

echo "[$MACHINE_NAME] workers started: ${#pids[@]}"

python3 - "$SHARD_NUM" "$NODES_IN_SHARD" "$READINESS_TIMEOUT_MS" <<'PY'
import json
import socket
import sys
import time

shard_num = int(sys.argv[1])
nodes_in_shard = int(sys.argv[2])
timeout = int(sys.argv[3]) / 1000.0

with open("ipTable.json", "r", encoding="utf-8") as f:
    ip_table = json.load(f)

targets = []
for sid in range(shard_num):
    for nid in range(nodes_in_shard):
        host, port = ip_table[str(sid)][str(nid)].rsplit(":", 1)
        targets.append((sid, nid, host, int(port)))

deadline = time.time() + timeout
while time.time() < deadline:
    missing = []
    for sid, nid, host, port in targets:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(0.5)
        try:
            sock.connect((host, port))
        except OSError:
            missing.append((sid, nid, host, port))
        finally:
            sock.close()
    if not missing:
        print(f"[machine-a] readiness: all {len(targets)} node ports are reachable")
        sys.exit(0)
    preview = ", ".join(f"s{sid}n{nid}@{host}:{port}" for sid, nid, host, port in missing[:8])
    print(f"[machine-a] readiness: waiting on {len(missing)}/{len(targets)} ports; first: {preview}", flush=True)
    time.sleep(5)

preview = ", ".join(f"s{sid}n{nid}@{host}:{port}" for sid, nid, host, port in missing[:20])
print(f"[machine-a] readiness timeout; still missing {len(missing)} ports: {preview}", file=sys.stderr)
sys.exit(2)
PY

elapsed_ms=$((SECONDS * 1000))
supervisor_start_at_ms=$((PBFT_START_DELAY_MS - SUPERVISOR_START_MARGIN_MS))
if ((supervisor_start_at_ms < 0)); then
  supervisor_start_at_ms=0
fi
while ((elapsed_ms < supervisor_start_at_ms)); do
  remaining_ms=$((supervisor_start_at_ms - elapsed_ms))
  echo "[$MACHINE_NAME] waiting $((remaining_ms / 1000))s before supervisor start"
  sleep 5
  elapsed_ms=$((SECONDS * 1000))
done

"$BIN" -c -N "$NODES_IN_SHARD" -S "$SHARD_NUM" >"$LOG_ROOT/supervisor.out" 2>&1 &
supervisor_pid="$!"
echo "[$MACHINE_NAME] supervisor started: pid=$supervisor_pid"

supervisor_status=0
wait "$supervisor_pid" || supervisor_status=$?
echo "[$MACHINE_NAME] supervisor exited: status=$supervisor_status"

deadline=$((SECONDS + 120))
while ((${#pids[@]} > 0)); do
  alive=()
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive+=("$pid")
    fi
  done
  pids=()
  if ((${#alive[@]} > 0)); then
    pids=("${alive[@]}")
  fi
  ((${#pids[@]} == 0)) && break
  if ((SECONDS > deadline)); then
    echo "[$MACHINE_NAME] killing remaining local workers: ${#pids[@]}"
    kill "${pids[@]}" 2>/dev/null || true
    break
  fi
  sleep 2
done

if ((${#pids[@]} > 0)); then
  wait "${pids[@]}" 2>/dev/null || true
fi
cp "$LOG_ROOT/paramsConfig.before.json" "$CONFIG_FILE"
trap - EXIT INT TERM

echo "[$MACHINE_NAME] done. logs: $LOG_ROOT"
exit "$supervisor_status"
