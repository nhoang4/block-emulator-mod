#!/usr/bin/env bash
set -u -o pipefail

# Run graph-ready scaling experiments.
#
# Defaults are intentionally paper-oriented:
#   sizes: 4,8,16,32,48,64 shards
#   nodes/shard: 10
#   repeats: 30
#
# Example:
#   MODES="complete_bridge sparse_bridge broker" ./scripts/run_linux_scaling_matrix.sh
#
# Full ablation:
#   MODES="complete_bridge sparse_bridge tree_bridge binary_tree_bridge broker" ./scripts/run_linux_scaling_matrix.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SIZES="${SIZES:-4 8 16 32 48 64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
REPEATS="${REPEATS:-30}"
MODES="${MODES:-complete_bridge sparse_bridge broker}"
MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/scaling-matrix-$(date +%Y%m%d-%H%M%S)}"
SUMMARY_CSV="${SUMMARY_CSV:-$MATRIX_ROOT/summary.csv}"
STRICT="${STRICT:-0}"
BUILD_FIRST="${BUILD_FIRST:-1}"
WATCHDOG_SECONDS="${WATCHDOG_SECONDS:-3600}"

mkdir -p "$MATRIX_ROOT/runs"

echo "[matrix] root=$MATRIX_ROOT"
echo "[matrix] summary=$SUMMARY_CSV"
echo "[matrix] sizes=$SIZES"
echo "[matrix] nodes_in_shard=$NODES_IN_SHARD repeats=$REPEATS"
echo "[matrix] modes=$MODES"

mode_script() {
  case "$1" in
    complete_bridge) echo "$SCRIPT_DIR/run_linux_local.sh" ;;
    sparse_bridge) echo "$SCRIPT_DIR/run_linux_sparse_bridge.sh" ;;
    tree_bridge) echo "$SCRIPT_DIR/run_linux_tree_bridge.sh" ;;
    binary_tree_bridge) echo "$SCRIPT_DIR/run_linux_binary_tree_bridge.sh" ;;
    broker) echo "$SCRIPT_DIR/run_linux_broker.sh" ;;
    *)
      echo "[matrix] unknown mode: $1" >&2
      return 2
      ;;
  esac
}

run_mode_env() {
  local mode="$1"
  case "$mode" in
    complete_bridge)
      export CONSENSUS_METHOD=4
      export BRIDGE_OVERLAY_ENABLED=0
      export BRIDGE_OVERLAY_BUILD_MODE=0
      ;;
    *)
      unset CONSENSUS_METHOD BRIDGE_OVERLAY_ENABLED BRIDGE_OVERLAY_BUILD_MODE
      ;;
  esac
}

run_index=0
for size in $SIZES; do
  for mode in $MODES; do
    script="$(mode_script "$mode")" || exit 2
    for repeat in $(seq 1 "$REPEATS"); do
      run_index=$((run_index + 1))
      run_root="$MATRIX_ROOT/runs/${mode}-${size}x${NODES_IN_SHARD}-r$(printf "%02d" "$repeat")"
      started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      log_path="$run_root.runner.out"
      mkdir -p "$(dirname "$run_root")"

      echo "[matrix] run=$run_index mode=$mode size=${size}x${NODES_IN_SHARD} repeat=$repeat root=$run_root"

      run_mode_env "$mode"
      build_flag=0
      if [[ "$BUILD_FIRST" == "1" && "$run_index" == "1" ]]; then
        build_flag=1
      fi

      SHARD_NUM="$size" \
      NODES_IN_SHARD="$NODES_IN_SHARD" \
      RUN_ROOT="$run_root" \
      BUILD="$build_flag" \
      WATCHDOG_SECONDS="$WATCHDOG_SECONDS" \
      "$script" >"$log_path" 2>&1
      ec=$?
      finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      status="ok"
      if [[ "$ec" != "0" ]]; then
        status="failed"
      fi

      "$SCRIPT_DIR/summarize_experiment_run.py" \
        --run-root "$run_root" \
        --mode "$mode" \
        --shard-num "$size" \
        --nodes-in-shard "$NODES_IN_SHARD" \
        --repeat "$repeat" \
        --status "$status" \
        --exit-code "$ec" \
        --started-at "$started_at" \
        --finished-at "$finished_at" \
        --out "$SUMMARY_CSV"

      if [[ "$ec" != "0" ]]; then
        echo "[matrix] failed mode=$mode size=${size}x${NODES_IN_SHARD} repeat=$repeat; see $log_path" >&2
        if [[ "$STRICT" == "1" ]]; then
          exit "$ec"
        fi
      fi
    done
  done
done

echo "[matrix] complete"
echo "[matrix] summary: $SUMMARY_CSV"
