#!/usr/bin/env bash
set -u -o pipefail

# Coordinate graph-ready distributed experiments from Machine A.
# Machine A runs its shard slice plus the supervisor. Machines B/C/D run workers
# over SSH. Only Machine A writes/aggregates TPS, CL, and channel-count summaries.
#
# Required env on Machine A:
#   MACHINE_A_IP, MACHINE_B_HOST, MACHINE_C_HOST, MACHINE_D_HOST
#
# Optional when repo path differs on remotes:
#   REMOTE_REPO_ROOT_B, REMOTE_REPO_ROOT_C, REMOTE_REPO_ROOT_D
#
# Example smoke run:
#   MACHINE_A_IP=10.0.0.1 MACHINE_B_HOST=nh@10.0.0.2 MACHINE_C_HOST=nh@10.0.0.3 MACHINE_D_HOST=nh@10.0.0.4 \
#   REPEATS=1 MODES="complete_bridge sparse_bridge binary_tree_bridge broker" \
#   ./scripts/run_linux_distributed_matrix_a.sh
#
# Transaction-size sweep at fixed 16x10:
#   SIZES=16 TOTAL_DATA_SIZES="100000 200000 400000 800000 1000000" \
#   MODES="complete_bridge sparse_bridge binary_tree_bridge broker" ./scripts/run_linux_distributed_matrix_a.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SIZES="${SIZES:-4 8 16 32 48 64}"
NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
REPEATS="${REPEATS:-30}"
MODES="${MODES:-complete_bridge sparse_bridge binary_tree_bridge broker}"
TOTAL_DATA_SIZES="${TOTAL_DATA_SIZES:-}"
MATRIX_ROOT="${MATRIX_ROOT:-$REPO_ROOT/distributed-scaling-matrix-$(date +%Y%m%d-%H%M%S)}"
SUMMARY_CSV="${SUMMARY_CSV:-$MATRIX_ROOT/summary.csv}"
STRICT="${STRICT:-0}"
BUILD_FIRST="${BUILD_FIRST:-1}"
KILL_EXISTING="${KILL_EXISTING:-1}"
WATCHDOG_SECONDS="${WATCHDOG_SECONDS:-5400}"
SSH_OPTS="${SSH_OPTS:-}"

MACHINE_A_IP="${MACHINE_A_IP:-}"
MACHINE_B_HOST="${MACHINE_B_HOST:-}"
MACHINE_C_HOST="${MACHINE_C_HOST:-}"
MACHINE_D_HOST="${MACHINE_D_HOST:-}"

strip_user() {
  local host="$1"
  echo "${host##*@}"
}

MACHINE_B_IP="${MACHINE_B_IP:-$(strip_user "$MACHINE_B_HOST")}"
MACHINE_C_IP="${MACHINE_C_IP:-$(strip_user "$MACHINE_C_HOST")}"
MACHINE_D_IP="${MACHINE_D_IP:-$(strip_user "$MACHINE_D_HOST")}"

if [[ -z "$MACHINE_A_IP" || -z "$MACHINE_B_HOST" || -z "$MACHINE_C_HOST" || -z "$MACHINE_D_HOST" ]]; then
  echo "[distributed-matrix] set MACHINE_A_IP, MACHINE_B_HOST, MACHINE_C_HOST, and MACHINE_D_HOST" >&2
  exit 2
fi

REMOTE_REPO_ROOT_B="${REMOTE_REPO_ROOT_B:-$REPO_ROOT}"
REMOTE_REPO_ROOT_C="${REMOTE_REPO_ROOT_C:-$REPO_ROOT}"
REMOTE_REPO_ROOT_D="${REMOTE_REPO_ROOT_D:-$REPO_ROOT}"
REMOTE_MATRIX_ROOT_B="${REMOTE_MATRIX_ROOT_B:-$MATRIX_ROOT}"
REMOTE_MATRIX_ROOT_C="${REMOTE_MATRIX_ROOT_C:-$MATRIX_ROOT}"
REMOTE_MATRIX_ROOT_D="${REMOTE_MATRIX_ROOT_D:-$MATRIX_ROOT}"

mkdir -p "$MATRIX_ROOT/runs"
cp ipTable.json "$MATRIX_ROOT/ipTable.before.json"

q() {
  printf "%q" "$1"
}

ssh_remote() {
  local host="$1"
  shift
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$host" "$@"
}

cleanup_local() {
  pkill -TERM -f '(^|[[:space:]/])block-emulator-mod([[:space:]]|$)' 2>/dev/null || true
}

cleanup_remote() {
  local host="$1"
  ssh_remote "$host" "pkill -TERM -f '(^|[[:space:]/])block-emulator-mod([[:space:]]|$)' 2>/dev/null || true"
}

cleanup_all() {
  cleanup_local
  cleanup_remote "$MACHINE_B_HOST"
  cleanup_remote "$MACHINE_C_HOST"
  cleanup_remote "$MACHINE_D_HOST"
}

restore_iptable() {
  if [[ -f "$MATRIX_ROOT/ipTable.before.json" ]]; then
    cp "$MATRIX_ROOT/ipTable.before.json" ipTable.json
  fi
}

finish() {
  local ec=$?
  trap - EXIT INT TERM
  if [[ "$ec" != "0" ]]; then
    cleanup_all
  fi
  restore_iptable
  exit "$ec"
}

trap finish EXIT INT TERM

sync_iptable() {
  local host="$1"
  local repo="$2"
  # shellcheck disable=SC2086
  scp $SSH_OPTS ipTable.json "$host:$repo/ipTable.json" >/dev/null
}

configure_and_sync_iptable() {
  local size="$1"
  python3 "$SCRIPT_DIR/configure_four_machine_iptable.py" \
    --machine-a-ip "$MACHINE_A_IP" \
    --machine-b-ip "$MACHINE_B_IP" \
    --machine-c-ip "$MACHINE_C_IP" \
    --machine-d-ip "$MACHINE_D_IP" \
    --shard-num "$size" \
    --nodes-in-shard "$NODES_IN_SHARD" \
    --iptable ipTable.json \
    >"$MATRIX_ROOT/iptable-${size}.out"

  sync_iptable "$MACHINE_B_HOST" "$REMOTE_REPO_ROOT_B" || return $?
  sync_iptable "$MACHINE_C_HOST" "$REMOTE_REPO_ROOT_C" || return $?
  sync_iptable "$MACHINE_D_HOST" "$REMOTE_REPO_ROOT_D" || return $?
}

mode_env() {
  case "$1" in
    complete_bridge)
      echo "CONSENSUS_METHOD=4 BRIDGE_OVERLAY_ENABLED=0 BRIDGE_OVERLAY_BUILD_MODE=0"
      ;;
    sparse_bridge)
      echo "CONSENSUS_METHOD=4 BRIDGE_OVERLAY_ENABLED=1 BRIDGE_OVERLAY_BUILD_MODE=0 BRIDGE_OVERLAY_MIN_DEGREE=${BRIDGE_OVERLAY_MIN_DEGREE:-2} BRIDGE_OVERLAY_MAX_DEGREE=${BRIDGE_OVERLAY_MAX_DEGREE:-10} BRIDGE_OVERLAY_SEED=${BRIDGE_OVERLAY_SEED:-1}"
      ;;
    tree_bridge)
      echo "CONSENSUS_METHOD=4 BRIDGE_OVERLAY_ENABLED=1 BRIDGE_OVERLAY_BUILD_MODE=1 BRIDGE_OVERLAY_MIN_DEGREE=${BRIDGE_OVERLAY_MIN_DEGREE:-2} BRIDGE_OVERLAY_MAX_DEGREE=${BRIDGE_OVERLAY_MAX_DEGREE:-10} BRIDGE_OVERLAY_SEED=${BRIDGE_OVERLAY_SEED:-1}"
      ;;
    binary_tree_bridge)
      echo "CONSENSUS_METHOD=4 BRIDGE_OVERLAY_ENABLED=1 BRIDGE_OVERLAY_BUILD_MODE=2"
      ;;
    broker)
      echo "CONSENSUS_METHOD=2 BRIDGE_OVERLAY_ENABLED=0 BRIDGE_OVERLAY_BUILD_MODE=0"
      ;;
    *)
      echo "[distributed-matrix] unknown mode: $1" >&2
      return 2
      ;;
  esac
}

optional_env() {
  local out=""
  for name in BLOCK_INTERVAL_MS BLOCK_SIZE INJECT_SPEED TX_BATCH_SIZE DATASET_FILE BRIDGE_KEY_ROOT_DIR; do
    if [[ -n "${!name:-}" ]]; then
      out+=" $name=$(q "${!name}")"
    fi
  done
  echo "$out"
}

remote_prepare_run() {
  local host="$1"
  local repo="$2"
  local remote_run_root="$3"
  local machine="$4"
  local config="$remote_run_root/params-${machine}.json"
  local cmd="cd $(q "$repo") && mkdir -p $(q "$remote_run_root") && cp paramsConfig.json $(q "$config")"
  ssh_remote "$host" "$cmd"
}

remote_launch() {
  local host="$1"
  local repo="$2"
  local remote_run_root="$3"
  local machine="$4"
  local wrapper="$5"
  local envs="$6"
  local config="$remote_run_root/params-${machine}.json"
  local log_root="$remote_run_root/machine-${machine}"
  local launch_out="$remote_run_root/machine-${machine}.launch.out"
  local cmd
  cmd="cd $(q "$repo") && env $envs CONFIG_FILE=$(q "$config") LOG_ROOT=$(q "$log_root") ./scripts/$wrapper >$(q "$launch_out") 2>&1"
  ssh_remote "$host" "$cmd" &
}

build_all_once() {
  echo "[distributed-matrix] building local binary"
  go build -o block-emulator-mod . || return $?
  for spec in \
    "$MACHINE_B_HOST|$REMOTE_REPO_ROOT_B|B" \
    "$MACHINE_C_HOST|$REMOTE_REPO_ROOT_C|C" \
    "$MACHINE_D_HOST|$REMOTE_REPO_ROOT_D|D"; do
    IFS='|' read -r host repo name <<<"$spec"
    echo "[distributed-matrix] building remote machine $name: $host"
    ssh_remote "$host" "cd $(q "$repo") && go build -o block-emulator-mod ." || return $?
  done
}

echo "[distributed-matrix] root=$MATRIX_ROOT"
echo "[distributed-matrix] summary=$SUMMARY_CSV"
echo "[distributed-matrix] sizes=$SIZES"
echo "[distributed-matrix] nodes_in_shard=$NODES_IN_SHARD repeats=$REPEATS"
echo "[distributed-matrix] modes=$MODES"
if [[ -n "$TOTAL_DATA_SIZES" ]]; then
  echo "[distributed-matrix] total_data_sizes=$TOTAL_DATA_SIZES"
elif [[ -n "${TOTAL_DATA_SIZE:-}" ]]; then
  echo "[distributed-matrix] total_data_size=$TOTAL_DATA_SIZE"
fi
echo "[distributed-matrix] A_IP=$MACHINE_A_IP B=$MACHINE_B_HOST C=$MACHINE_C_HOST D=$MACHINE_D_HOST"

if [[ "$BUILD_FIRST" == "1" ]]; then
  build_all_once || exit $?
fi

data_size_values=()
if [[ -n "$TOTAL_DATA_SIZES" ]]; then
  # shellcheck disable=SC2206
  data_size_values=($TOTAL_DATA_SIZES)
elif [[ -n "${TOTAL_DATA_SIZE:-}" ]]; then
  data_size_values=("$TOTAL_DATA_SIZE")
else
  data_size_values=("default")
fi

run_index=0
for size in $SIZES; do
  for data_size in "${data_size_values[@]}"; do
    data_size_env=""
    data_size_label=""
    requested_total_data_size=""
    if [[ "$data_size" != "default" ]]; then
      data_size_env=" TOTAL_DATA_SIZE=$(q "$data_size")"
      data_size_label="-tx${data_size}"
      requested_total_data_size="$data_size"
    fi

    for mode in $MODES; do
      envs="SHARD_NUM=$size NODES_IN_SHARD=$NODES_IN_SHARD PBFT_TIMEOUT_MS=${PBFT_TIMEOUT_MS:-300000} PBFT_START_DELAY_MS=${PBFT_START_DELAY_MS:-60000} READINESS_TIMEOUT_MS=${READINESS_TIMEOUT_MS:-300000} SUPERVISOR_START_MARGIN_MS=${SUPERVISOR_START_MARGIN_MS:-10000}"
      mode_envs="$(mode_env "$mode")" || exit 2
      envs="$envs $mode_envs$(optional_env)$data_size_env"

      for repeat in $(seq 1 "$REPEATS"); do
        run_index=$((run_index + 1))
        run_name="${mode}-${size}x${NODES_IN_SHARD}${data_size_label}-r$(printf "%02d" "$repeat")"
        run_root="$MATRIX_ROOT/runs/$run_name"
        started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        mkdir -p "$run_root"
        cp paramsConfig.json "$run_root/params-a.json"

        remote_run_root_b="$REMOTE_MATRIX_ROOT_B/runs/$run_name"
        remote_run_root_c="$REMOTE_MATRIX_ROOT_C/runs/$run_name"
        remote_run_root_d="$REMOTE_MATRIX_ROOT_D/runs/$run_name"

        echo "[distributed-matrix] run=$run_index mode=$mode size=${size}x${NODES_IN_SHARD} total_data_size=${requested_total_data_size:-default} repeat=$repeat"

        if [[ "$KILL_EXISTING" == "1" ]]; then
          cleanup_all
          sleep 2
        fi

        configure_and_sync_iptable "$size" || exit $?
        cp ipTable.json "$run_root/ipTable.used.json"

        remote_prepare_run "$MACHINE_B_HOST" "$REMOTE_REPO_ROOT_B" "$remote_run_root_b" "b" || exit $?
        remote_prepare_run "$MACHINE_C_HOST" "$REMOTE_REPO_ROOT_C" "$remote_run_root_c" "c" || exit $?
        remote_prepare_run "$MACHINE_D_HOST" "$REMOTE_REPO_ROOT_D" "$remote_run_root_d" "d" || exit $?

        remote_launch "$MACHINE_B_HOST" "$REMOTE_REPO_ROOT_B" "$remote_run_root_b" "b" "launch_four_machine_b.sh" "$envs"
        b_pid=$!
        remote_launch "$MACHINE_C_HOST" "$REMOTE_REPO_ROOT_C" "$remote_run_root_c" "c" "launch_four_machine_c.sh" "$envs"
        c_pid=$!
        remote_launch "$MACHINE_D_HOST" "$REMOTE_REPO_ROOT_D" "$remote_run_root_d" "d" "launch_four_machine_d.sh" "$envs"
        d_pid=$!

        sleep 2

        a_ec=0
        env $envs CONFIG_FILE="$run_root/params-a.json" LOG_ROOT="$run_root/machine-a" \
          ./scripts/launch_four_machine_a.sh >"$run_root/machine-a.launch.out" 2>&1 &
        a_pid=$!

        deadline=$((SECONDS + WATCHDOG_SECONDS))
        while kill -0 "$a_pid" 2>/dev/null; do
          if ((SECONDS >= deadline)); then
            echo "[distributed-matrix] watchdog timeout after ${WATCHDOG_SECONDS}s: $run_name" | tee -a "$run_root/machine-a.launch.out" >&2
            kill "$a_pid" 2>/dev/null || true
            cleanup_all
            a_ec=124
            break
          fi
          sleep 10
        done
        if [[ "$a_ec" == "0" ]]; then
          wait "$a_pid" || a_ec=$?
        else
          wait "$a_pid" 2>/dev/null || true
        fi

        b_ec=0
        c_ec=0
        d_ec=0
        wait "$b_pid" || b_ec=$?
        wait "$c_pid" || c_ec=$?
        wait "$d_pid" || d_ec=$?

        finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        status="ok"
        if [[ "$a_ec" != "0" || "$b_ec" != "0" || "$c_ec" != "0" || "$d_ec" != "0" ]]; then
          status="failed"
        fi
        exit_code="a=$a_ec;b=$b_ec;c=$c_ec;d=$d_ec"

        "$SCRIPT_DIR/summarize_experiment_run.py" \
          --run-root "$run_root" \
          --mode "$mode" \
          --shard-num "$size" \
          --nodes-in-shard "$NODES_IN_SHARD" \
          --repeat "$repeat" \
          --requested-total-data-size "$requested_total_data_size" \
          --status "$status" \
          --exit-code "$exit_code" \
          --started-at "$started_at" \
          --finished-at "$finished_at" \
          --out "$SUMMARY_CSV"

        if [[ "$status" != "ok" ]]; then
          echo "[distributed-matrix] failed $run_name exit_code=$exit_code" >&2
          if [[ "$STRICT" == "1" ]]; then
            exit 1
          fi
        fi
      done
    done
  done
done

echo "[distributed-matrix] complete"
echo "[distributed-matrix] summary: $SUMMARY_CSV"
