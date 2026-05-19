#!/usr/bin/env bash
set -euo pipefail

# Machine C: third quarter of shards. The supervisor runs on Machine A.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHARD_NUM="${SHARD_NUM:-64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export SHARD_NUM
export NODES_IN_SHARD
export SHARD_START="${SHARD_START:-$((SHARD_NUM / 2))}"
export SHARD_END="${SHARD_END:-$((3 * SHARD_NUM / 4 - 1))}"
export MACHINE_NAME="${MACHINE_NAME:-machine-c}"

exec "$SCRIPT_DIR/launch_machine_b.sh"
