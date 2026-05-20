#!/usr/bin/env bash
set -euo pipefail

# Machine A wrapper for the transaction-size experiment.
# Fixed network size: 16 shards x 10 nodes/shard.
# Transaction sizes: 1, 2, 4, 8, 10 x 100000.
# Protocols: complete ShardBridge, sparse ShardBridge, binary-tree ShardBridge,
# and BrokerChain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export SIZES="${SIZES:-16}"
export NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export TOTAL_DATA_SIZES="${TOTAL_DATA_SIZES:-100000 200000 400000 800000 1000000}"
export MODES="${MODES:-complete_bridge sparse_bridge binary_tree_bridge broker}"
export REPEATS="${REPEATS:-30}"
export MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/distributed-txsize-16x10-$(date +%Y%m%d-%H%M%S)}"

echo "[txsize-16x10] sizes=$SIZES"
echo "[txsize-16x10] nodes_in_shard=$NODES_IN_SHARD"
echo "[txsize-16x10] total_data_sizes=$TOTAL_DATA_SIZES"
echo "[txsize-16x10] modes=$MODES"
echo "[txsize-16x10] repeats=$REPEATS"
echo "[txsize-16x10] output_root=$MATRIX_ROOT"

exec "$SCRIPT_DIR/run_linux_distributed_matrix_a.sh"
