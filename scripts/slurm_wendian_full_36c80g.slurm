#!/bin/bash
#SBATCH -A 2605251931
#SBATCH --job-name=be-full-36c80g
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=36
#SBATCH --mem=80G
#SBATCH --time=72:00:00
#SBATCH -o wendian-full-36c80g-%j.out
#SBATCH -e wendian-full-36c80g-%j.err
#SBATCH --export=ALL

set -euo pipefail

module load apps/python3
set +u
source ~/.bashrc
set -u

REPO_ROOT="${REPO_ROOT:-/scratch/nhan_hoang/block-emulator-mod}"
cd "$REPO_ROOT"

export NETWORK_SIZES="${NETWORK_SIZES:-4 8 16 32 48 64}"
export TXSIZE_SIZES="${TXSIZE_SIZES:-16}"
export TXSIZE_TOTAL_DATA_SIZES="${TXSIZE_TOTAL_DATA_SIZES:-100000 200000 400000 800000 1000000}"
export NODES_IN_SHARD="${NODES_IN_SHARD:-10}"
export REPEATS="${REPEATS:-30}"
export MODES="${MODES:-complete_bridge sparse_bridge broker}"
export WATCHDOG_SECONDS="${WATCHDOG_SECONDS:-900}"
export PORT_WAIT_SECONDS="${PORT_WAIT_SECONDS:-300}"
export MAX_ATTEMPTS_PER_REPEAT="${MAX_ATTEMPTS_PER_REPEAT:-5}"
export CHECKPOINT_RESULTS="${CHECKPOINT_RESULTS:-1}"
export AUTO_COMMIT_RESULTS="${AUTO_COMMIT_RESULTS:-0}"
export AUTO_PUSH_RESULTS="${AUTO_PUSH_RESULTS:-0}"
export RESULTS_DIR="${RESULTS_DIR:-/scratch/nhan_hoang/block-emulator-results/full-36c80g}"

go build -o block-emulator-mod .
BUILD_FIRST=0 ./scripts/run_linux_local_full_experiment.sh
