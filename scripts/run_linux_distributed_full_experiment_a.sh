#!/usr/bin/env bash
set -euo pipefail

# Machine A wrapper for the full distributed experiment.
#
# Phase 1: network-size scaling
#   sizes: 4, 8, 16, 32, 48, 64 shards
#
# Phase 2: transaction-size scaling at fixed 16x10
#   transaction sizes: 1, 2, 4, 8, 10 x 100000
#
# Both phases write to the same summary.csv under MATRIX_ROOT.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export REPEATS="${REPEATS:-30}"
export MODES="${MODES:-complete_bridge sparse_bridge binary_tree_bridge broker}"
export MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/distributed-full-experiment-$(date +%Y%m%d-%H%M%S)}"
export SUMMARY_CSV="${SUMMARY_CSV:-$MATRIX_ROOT/summary.csv}"

NETWORK_SIZES="${NETWORK_SIZES:-4 8 16 32 48 64}"
TXSIZE_SIZES="${TXSIZE_SIZES:-16}"
TXSIZE_TOTAL_DATA_SIZES="${TXSIZE_TOTAL_DATA_SIZES:-100000 200000 400000 800000 1000000}"
FIRST_BUILD="${BUILD_FIRST:-1}"

echo "[full-experiment] output_root=$MATRIX_ROOT"
echo "[full-experiment] summary=$SUMMARY_CSV"
echo "[full-experiment] modes=$MODES"
echo "[full-experiment] repeats=$REPEATS nodes_in_shard=$NODES_IN_SHARD"

echo "[full-experiment] phase 1/2: network-size scaling, sizes=$NETWORK_SIZES"
SIZES="$NETWORK_SIZES" \
TOTAL_DATA_SIZES="" \
BUILD_FIRST="$FIRST_BUILD" \
"$SCRIPT_DIR/run_linux_distributed_matrix_a.sh"

echo "[full-experiment] phase 2/2: transaction-size scaling, sizes=$TXSIZE_SIZES total_data_sizes=$TXSIZE_TOTAL_DATA_SIZES"
SIZES="$TXSIZE_SIZES" \
TOTAL_DATA_SIZES="$TXSIZE_TOTAL_DATA_SIZES" \
BUILD_FIRST=0 \
"$SCRIPT_DIR/run_linux_distributed_matrix_a.sh"

echo "[full-experiment] complete"
echo "[full-experiment] summary: $SUMMARY_CSV"
