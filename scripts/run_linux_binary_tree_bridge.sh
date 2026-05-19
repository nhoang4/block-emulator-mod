#!/usr/bin/env bash
set -euo pipefail

# Local Linux runner for ShardBridge with a deterministic binary-tree PC overlay.
# Epoch 0 remains complete; later epochs use parent(i) = floor((i - 1) / 2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SHARD_NUM="${SHARD_NUM:-16}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export SHARD_NUM
export NODES_IN_SHARD

export CONSENSUS_METHOD=4
export BRIDGE_OVERLAY_ENABLED=1
export BRIDGE_OVERLAY_BUILD_MODE=2
export RUN_ROOT="${RUN_ROOT:-$REPO_ROOT/run-linux-binary-tree-bridge-${SHARD_NUM}x${NODES_IN_SHARD}-$(date +%Y%m%d-%H%M%S)}"

echo "[binary-tree-bridge] ConsensusMethod=4 BridgeOverlayEnabled=1 BridgeOverlayBuildMode=2"
echo "[binary-tree-bridge] topology=parent(i)=floor((i-1)/2)"

exec "$SCRIPT_DIR/run_linux_local.sh"
