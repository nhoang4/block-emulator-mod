#!/usr/bin/env bash
set -euo pipefail

# Local Linux runner for Monoxide-style relay mode.
# Override SHARD_NUM/NODES_IN_SHARD the same way as run_linux_local.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SHARD_NUM="${SHARD_NUM:-16}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export SHARD_NUM
export NODES_IN_SHARD

export CONSENSUS_METHOD=3
export BRIDGE_OVERLAY_ENABLED=0
export RUN_ROOT="${RUN_ROOT:-$REPO_ROOT/run-linux-monoxide-${SHARD_NUM}x${NODES_IN_SHARD}-$(date +%Y%m%d-%H%M%S)}"

echo "[monoxide] ConsensusMethod=3 Relay"

exec "$SCRIPT_DIR/run_linux_local.sh"
