#!/usr/bin/env bash
set -euo pipefail

# Local Linux runner for ShardBridge with the sparse PC overlay enabled.
# Override SHARD_NUM/NODES_IN_SHARD the same way as run_linux_local.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SHARD_NUM="${SHARD_NUM:-16}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export SHARD_NUM
export NODES_IN_SHARD

export CONSENSUS_METHOD=4
export BRIDGE_OVERLAY_ENABLED=1
export BRIDGE_OVERLAY_MIN_DEGREE="${BRIDGE_OVERLAY_MIN_DEGREE:-2}"
export BRIDGE_OVERLAY_MAX_DEGREE="${BRIDGE_OVERLAY_MAX_DEGREE:-10}"
export BRIDGE_OVERLAY_SEED="${BRIDGE_OVERLAY_SEED:-1}"
export RUN_ROOT="${RUN_ROOT:-$REPO_ROOT/run-linux-sparse-bridge-${SHARD_NUM}x${NODES_IN_SHARD}-$(date +%Y%m%d-%H%M%S)}"

echo "[sparse-bridge] ConsensusMethod=4 BridgeOverlayEnabled=1"
echo "[sparse-bridge] degree range=${BRIDGE_OVERLAY_MIN_DEGREE}..${BRIDGE_OVERLAY_MAX_DEGREE} seed=${BRIDGE_OVERLAY_SEED}"

exec "$SCRIPT_DIR/run_linux_local.sh"
