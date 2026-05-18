#!/usr/bin/env bash
set -euo pipefail

# Machine C: launches the final shard range. The supervisor runs on Machine A.
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
MACHINE_NAME="${MACHINE_NAME:-machine-c}"

SHARD_NUM="${SHARD_NUM:-64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
SHARD_START="${SHARD_START:-$(((2 * SHARD_NUM + 2) / 3))}"
SHARD_END="${SHARD_END:-$((SHARD_NUM - 1))}"

PBFT_TIMEOUT_MS="${PBFT_TIMEOUT_MS:-300000}"
PBFT_START_DELAY_MS="${PBFT_START_DELAY_MS:-180000}"
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

cleanup() {
  local ec=$?
  trap - EXIT INT TERM
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
echo "[$MACHINE_NAME] waiting for stop signal from Machine A supervisor"

wait "${pids[@]}" 2>/dev/null || true
cp "$LOG_ROOT/paramsConfig.before.json" "$CONFIG_FILE"
trap - EXIT INT TERM

echo "[$MACHINE_NAME] done. logs: $LOG_ROOT"
