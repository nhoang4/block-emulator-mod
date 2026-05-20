#!/usr/bin/env bash
set -euo pipefail

# Single-machine wrapper for the transaction-size experiment.
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
export MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/txsize-16x10-$(date +%Y%m%d-%H%M%S)}"
export AUTO_PUSH_RESULTS="${AUTO_PUSH_RESULTS:-0}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/results/txsize-16x10}"
RESULTS_REMOTE="${RESULTS_REMOTE:-origin}"
RESULTS_BRANCH="${RESULTS_BRANCH:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo main)}"

echo "[txsize-16x10-local] sizes=$SIZES"
echo "[txsize-16x10-local] nodes_in_shard=$NODES_IN_SHARD"
echo "[txsize-16x10-local] total_data_sizes=$TOTAL_DATA_SIZES"
echo "[txsize-16x10-local] modes=$MODES"
echo "[txsize-16x10-local] repeats=$REPEATS"
echo "[txsize-16x10-local] output_root=$MATRIX_ROOT"
echo "[txsize-16x10-local] auto_push_results=$AUTO_PUSH_RESULTS"

"$SCRIPT_DIR/run_linux_scaling_matrix.sh"

summary="$MATRIX_ROOT/summary.csv"
if [[ ! -f "$summary" ]]; then
  echo "[txsize-16x10-local] missing summary: $summary" >&2
  exit 2
fi

if [[ "$AUTO_PUSH_RESULTS" == "1" ]]; then
  run_id="$(basename "$MATRIX_ROOT")"
  mkdir -p "$RESULTS_DIR"
  result_copy="$RESULTS_DIR/${run_id}-summary.csv"
  cp "$summary" "$result_copy"

  git -C "$REPO_ROOT" add "$result_copy"
  if git -C "$REPO_ROOT" diff --cached --quiet -- "$result_copy"; then
    echo "[txsize-16x10-local] result summary unchanged; skipping commit"
  else
    if git -C "$REPO_ROOT" commit -m "Add txsize 16x10 results $run_id"; then
      if git -C "$REPO_ROOT" push "$RESULTS_REMOTE" "$RESULTS_BRANCH"; then
        echo "[txsize-16x10-local] pushed result summary: $result_copy"
      else
        echo "[txsize-16x10-local] push failed; result summary remains committed locally: $result_copy" >&2
      fi
    else
      echo "[txsize-16x10-local] commit failed; result summary remains on disk: $result_copy" >&2
    fi
  fi
else
  echo "[txsize-16x10-local] summary: $summary"
  echo "[txsize-16x10-local] set AUTO_PUSH_RESULTS=1 to copy, commit, and push the final summary"
fi
