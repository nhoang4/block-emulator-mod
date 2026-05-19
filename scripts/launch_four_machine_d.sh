#!/usr/bin/env bash
set -euo pipefail

# Machine D: final quarter of shards. The supervisor runs on Machine A.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHARD_NUM="${SHARD_NUM:-64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export SHARD_NUM
export NODES_IN_SHARD
export SHARD_START="${SHARD_START:-$((3 * SHARD_NUM / 4))}"
export SHARD_END="${SHARD_END:-$((SHARD_NUM - 1))}"
export MACHINE_NAME="${MACHINE_NAME:-machine-d}"

exec "$SCRIPT_DIR/launch_machine_b.sh"
