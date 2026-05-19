#!/usr/bin/env bash
set -euo pipefail

# Machine A: first quarter of shards plus supervisor.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHARD_NUM="${SHARD_NUM:-64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export SHARD_NUM
export NODES_IN_SHARD
export SHARD_START="${SHARD_START:-0}"
export SHARD_END="${SHARD_END:-$((SHARD_NUM / 4 - 1))}"
export MACHINE_NAME="${MACHINE_NAME:-machine-a}"

exec "$SCRIPT_DIR/launch_machine_a.sh"
