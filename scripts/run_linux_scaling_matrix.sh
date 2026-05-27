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
#   MODES="complete_bridge sparse_bridge binary_tree_bridge broker" ./scripts/run_linux_scaling_matrix.sh
#
# Transaction-size sweep at fixed 16x10:
#   SIZES=16 TOTAL_DATA_SIZES="100000 200000 400000 800000 1000000" \
#   MODES="complete_bridge sparse_bridge binary_tree_bridge broker" ./scripts/run_linux_scaling_matrix.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SIZES="${SIZES:-4 8 16 32 48 64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
REPEATS="${REPEATS:-30}"
MODES="${MODES:-complete_bridge sparse_bridge binary_tree_bridge broker}"
TOTAL_DATA_SIZES="${TOTAL_DATA_SIZES:-}"
MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/scaling-matrix-$(date +%Y%m%d-%H%M%S)}"
SUMMARY_CSV="${SUMMARY_CSV:-$MATRIX_ROOT/summary.csv}"
STRICT="${STRICT:-0}"
BUILD_FIRST="${BUILD_FIRST:-1}"
WATCHDOG_SECONDS="${WATCHDOG_SECONDS:-3600}"
RETRY_FAILED_RUNS="${RETRY_FAILED_RUNS:-1}"
MAX_ATTEMPTS_PER_REPEAT="${MAX_ATTEMPTS_PER_REPEAT:-3}"
AUTO_PUSH_RESULTS="${AUTO_PUSH_RESULTS:-0}"
CHECKPOINT_RESULTS="${CHECKPOINT_RESULTS:-$AUTO_PUSH_RESULTS}"
AUTO_COMMIT_RESULTS="${AUTO_COMMIT_RESULTS:-$AUTO_PUSH_RESULTS}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/results/scaling-matrix}"
RESULTS_REMOTE="${RESULTS_REMOTE:-origin}"
RESULTS_BRANCH="${RESULTS_BRANCH:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo main)}"
RESULTS_LABEL="${RESULTS_LABEL:-$(basename "$MATRIX_ROOT")}"

if [[ "$RETRY_FAILED_RUNS" != "1" ]]; then
  MAX_ATTEMPTS_PER_REPEAT=1
fi

mkdir -p "$MATRIX_ROOT/runs"

echo "[matrix] root=$MATRIX_ROOT"
echo "[matrix] summary=$SUMMARY_CSV"
echo "[matrix] sizes=$SIZES"
echo "[matrix] nodes_in_shard=$NODES_IN_SHARD repeats=$REPEATS"
echo "[matrix] modes=$MODES"
echo "[matrix] retry_failed_runs=$RETRY_FAILED_RUNS max_attempts_per_repeat=$MAX_ATTEMPTS_PER_REPEAT"
if [[ -n "$TOTAL_DATA_SIZES" ]]; then
  echo "[matrix] total_data_sizes=$TOTAL_DATA_SIZES"
elif [[ -n "${TOTAL_DATA_SIZE:-}" ]]; then
  echo "[matrix] total_data_size=$TOTAL_DATA_SIZE"
fi
echo "[matrix] checkpoint_results=$CHECKPOINT_RESULTS auto_commit_results=$AUTO_COMMIT_RESULTS"

checkpoint_results() {
  local checkpoint_name="$1"
  if [[ "$CHECKPOINT_RESULTS" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "$SUMMARY_CSV" ]]; then
    echo "[matrix] checkpoint skipped; summary missing: $SUMMARY_CSV" >&2
    return 0
  fi

  mkdir -p "$RESULTS_DIR"
  local result_copy="$RESULTS_DIR/${RESULTS_LABEL}-summary.csv"
  cp "$SUMMARY_CSV" "$result_copy"

  if [[ "$AUTO_COMMIT_RESULTS" != "1" ]]; then
    echo "[matrix] checkpoint copied: $checkpoint_name -> $result_copy"
    return 0
  fi

  git -C "$REPO_ROOT" add "$result_copy"
  if git -C "$REPO_ROOT" diff --cached --quiet -- "$result_copy"; then
    echo "[matrix] checkpoint unchanged: $checkpoint_name"
    return 0
  fi

  if git -C "$REPO_ROOT" commit -m "Checkpoint results $RESULTS_LABEL $checkpoint_name" -- "$result_copy"; then
    if git -C "$REPO_ROOT" push "$RESULTS_REMOTE" "$RESULTS_BRANCH"; then
      echo "[matrix] checkpoint pushed: $checkpoint_name -> $result_copy"
    else
      echo "[matrix] checkpoint push failed; result committed locally: $result_copy" >&2
    fi
  else
    echo "[matrix] checkpoint commit failed; summary remains at: $SUMMARY_CSV" >&2
  fi
}

mode_script() {
  case "$1" in
    complete_bridge) echo "$SCRIPT_DIR/run_linux_local.sh" ;;
    sparse_bridge) echo "$SCRIPT_DIR/run_linux_sparse_bridge.sh" ;;
    tree_bridge) echo "$SCRIPT_DIR/run_linux_tree_bridge.sh" ;;
    binary_tree_bridge) echo "$SCRIPT_DIR/run_linux_binary_tree_bridge.sh" ;;
    broker) echo "$SCRIPT_DIR/run_linux_broker.sh" ;;
    monoxide | relay) echo "$SCRIPT_DIR/run_linux_monoxide.sh" ;;
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
data_size_values=()
if [[ -n "$TOTAL_DATA_SIZES" ]]; then
  # shellcheck disable=SC2206
  data_size_values=($TOTAL_DATA_SIZES)
elif [[ -n "${TOTAL_DATA_SIZE:-}" ]]; then
  data_size_values=("$TOTAL_DATA_SIZE")
else
  data_size_values=("default")
fi

for size in $SIZES; do
  for data_size in "${data_size_values[@]}"; do
    data_size_label=""
    requested_total_data_size=""
    if [[ "$data_size" != "default" ]]; then
      data_size_label="-tx${data_size}"
      requested_total_data_size="$data_size"
    fi

    for mode in $MODES; do
      script="$(mode_script "$mode")" || exit 2
      for repeat in $(seq 1 "$REPEATS"); do
        attempt=1
        repeat_ok=0
        while ((attempt <= MAX_ATTEMPTS_PER_REPEAT)); do
          run_index=$((run_index + 1))
          attempt_suffix=""
          if ((attempt > 1)); then
            attempt_suffix="-a$(printf "%02d" "$attempt")"
          fi
          run_root="$MATRIX_ROOT/runs/${mode}-${size}x${NODES_IN_SHARD}${data_size_label}-r$(printf "%02d" "$repeat")${attempt_suffix}"
          started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          log_path="$run_root.runner.out"
          mkdir -p "$(dirname "$run_root")"

          echo "[matrix] run=$run_index mode=$mode size=${size}x${NODES_IN_SHARD} total_data_size=${requested_total_data_size:-default} repeat=$repeat attempt=$attempt/$MAX_ATTEMPTS_PER_REPEAT root=$run_root"

          run_mode_env "$mode"
          build_flag=0
          if [[ "$BUILD_FIRST" == "1" && "$run_index" == "1" ]]; then
            build_flag=1
          fi

          if [[ -n "$requested_total_data_size" ]]; then
            TOTAL_DATA_SIZE="$requested_total_data_size" \
              SHARD_NUM="$size" \
              NODES_IN_SHARD="$NODES_IN_SHARD" \
              RUN_ROOT="$run_root" \
              BUILD="$build_flag" \
              WATCHDOG_SECONDS="$WATCHDOG_SECONDS" \
              "$script" >"$log_path" 2>&1
          else
            SHARD_NUM="$size" \
              NODES_IN_SHARD="$NODES_IN_SHARD" \
              RUN_ROOT="$run_root" \
              BUILD="$build_flag" \
              WATCHDOG_SECONDS="$WATCHDOG_SECONDS" \
              "$script" >"$log_path" 2>&1
          fi
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
            --attempt "$attempt" \
            --requested-total-data-size "$requested_total_data_size" \
            --status "$status" \
            --exit-code "$ec" \
            --started-at "$started_at" \
            --finished-at "$finished_at" \
            --out "$SUMMARY_CSV"

          if [[ "$ec" == "0" ]]; then
            repeat_ok=1
            break
          fi

          echo "[matrix] failed mode=$mode size=${size}x${NODES_IN_SHARD} total_data_size=${requested_total_data_size:-default} repeat=$repeat attempt=$attempt; see $log_path" >&2
          if [[ "$STRICT" == "1" ]]; then
            exit "$ec"
          fi
          if ((attempt >= MAX_ATTEMPTS_PER_REPEAT)); then
            break
          fi
          attempt=$((attempt + 1))
          echo "[matrix] retrying repeat=$repeat attempt=$attempt/$MAX_ATTEMPTS_PER_REPEAT"
        done
        if [[ "$repeat_ok" != "1" ]]; then
          echo "[matrix] exhausted attempts for mode=$mode size=${size}x${NODES_IN_SHARD} total_data_size=${requested_total_data_size:-default} repeat=$repeat" >&2
        fi
      done
      checkpoint_results "${mode}-${size}x${NODES_IN_SHARD}${data_size_label}"
    done
  done
done

echo "[matrix] complete"
echo "[matrix] summary: $SUMMARY_CSV"
