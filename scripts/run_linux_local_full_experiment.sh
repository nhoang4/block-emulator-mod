#!/usr/bin/env bash
set -euo pipefail

# Single-machine full experiment.
#
# Phase 1: network-size scaling capped at 32x10
#   sizes: 4, 8, 16, 32 shards
#
# Phase 2: transaction-size scaling at fixed 16x10
#   transaction sizes: 1, 2, 4, 8, 10 x 100000
#
# Both phases write to the same summary.csv. By default this wrapper copies a
# checkpoint summary after each 30-run parameter block, but does not commit/push.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export REPEATS="${REPEATS:-30}"
export MODES="${MODES:-complete_bridge sparse_bridge binary_tree_bridge broker}"
export MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/local-full-experiment-$(date +%Y%m%d-%H%M%S)}"
export SUMMARY_CSV="${SUMMARY_CSV:-$MATRIX_ROOT/summary.csv}"
export CHECKPOINT_RESULTS="${CHECKPOINT_RESULTS:-1}"
export AUTO_PUSH_RESULTS="${AUTO_PUSH_RESULTS:-0}"
export AUTO_COMMIT_RESULTS="${AUTO_COMMIT_RESULTS:-$AUTO_PUSH_RESULTS}"
export RETRY_FAILED_RUNS="${RETRY_FAILED_RUNS:-1}"
export MAX_ATTEMPTS_PER_REPEAT="${MAX_ATTEMPTS_PER_REPEAT:-3}"

NETWORK_SIZES="${NETWORK_SIZES:-4 8 16 32}"
TXSIZE_SIZES="${TXSIZE_SIZES:-16}"
TXSIZE_TOTAL_DATA_SIZES="${TXSIZE_TOTAL_DATA_SIZES:-100000 200000 400000 800000 1000000}"
FIRST_BUILD="${BUILD_FIRST:-1}"
RUN_ID="$(basename "$MATRIX_ROOT")"

export RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/results/local-full-experiment}"
export RESULTS_LABEL="${RESULTS_LABEL:-$RUN_ID}"

echo "[local-full] output_root=$MATRIX_ROOT"
echo "[local-full] summary=$SUMMARY_CSV"
echo "[local-full] modes=$MODES"
echo "[local-full] repeats=$REPEATS nodes_in_shard=$NODES_IN_SHARD"
echo "[local-full] retry_failed_runs=$RETRY_FAILED_RUNS max_attempts_per_repeat=$MAX_ATTEMPTS_PER_REPEAT"
echo "[local-full] checkpoint_results=$CHECKPOINT_RESULTS auto_commit_results=$AUTO_COMMIT_RESULTS"

echo "[local-full] phase 1/2: network-size scaling, sizes=$NETWORK_SIZES"
SIZES="$NETWORK_SIZES" \
TOTAL_DATA_SIZES="" \
BUILD_FIRST="$FIRST_BUILD" \
"$SCRIPT_DIR/run_linux_scaling_matrix.sh"

echo "[local-full] phase 2/2: transaction-size scaling, sizes=$TXSIZE_SIZES total_data_sizes=$TXSIZE_TOTAL_DATA_SIZES"
SIZES="$TXSIZE_SIZES" \
TOTAL_DATA_SIZES="$TXSIZE_TOTAL_DATA_SIZES" \
BUILD_FIRST=0 \
"$SCRIPT_DIR/run_linux_scaling_matrix.sh"

echo "[local-full] complete"
echo "[local-full] summary: $SUMMARY_CSV"
echo "[local-full] checkpoint copy: $RESULTS_DIR/${RESULTS_LABEL}-summary.csv"
