#!/usr/bin/env bash
set -euo pipefail

# Run on Machine A before starting distributed experiments.
# It verifies that Machine A can reach B/C/D over SSH and that each machine has
# the repo, dataset, helper scripts, and Go toolchain needed by the launcher.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MACHINE_A_IP="${MACHINE_A_IP:-}"
MACHINE_B_HOST="${MACHINE_B_HOST:-}"
MACHINE_C_HOST="${MACHINE_C_HOST:-}"
MACHINE_D_HOST="${MACHINE_D_HOST:-}"
SSH_OPTS="${SSH_OPTS:-}"
DATASET_FILE="${DATASET_FILE:-$(python3 - <<'PY'
import json
with open("paramsConfig.json", encoding="utf-8") as f:
    print(json.load(f).get("DatasetFile", ""))
PY
)}"

REMOTE_REPO_ROOT_B="${REMOTE_REPO_ROOT_B:-$REPO_ROOT}"
REMOTE_REPO_ROOT_C="${REMOTE_REPO_ROOT_C:-$REPO_ROOT}"
REMOTE_REPO_ROOT_D="${REMOTE_REPO_ROOT_D:-$REPO_ROOT}"

if [[ -z "$MACHINE_A_IP" || -z "$MACHINE_B_HOST" || -z "$MACHINE_C_HOST" || -z "$MACHINE_D_HOST" ]]; then
  echo "[preflight] set MACHINE_A_IP, MACHINE_B_HOST, MACHINE_C_HOST, and MACHINE_D_HOST" >&2
  exit 2
fi

if [[ ! -f "$DATASET_FILE" ]]; then
  echo "[preflight] local dataset missing on Machine A: $DATASET_FILE" >&2
  exit 2
fi

echo "[preflight] Machine A repo: $REPO_ROOT"
echo "[preflight] Machine A IP: $MACHINE_A_IP"
echo "[preflight] dataset: $DATASET_FILE"

check_remote() {
  local label="$1"
  local host="$2"
  local repo="$3"
  local script_suffix
  script_suffix="$(printf "%s" "$label" | tr '[:upper:]' '[:lower:]')"

  echo "[preflight] checking Machine $label: $host repo=$repo"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$host" "cd '$repo' && \
    test -x ./scripts/launch_four_machine_${script_suffix}.sh && \
    test -x ./scripts/launch_machine_b.sh && \
    test -x ./scripts/summarize_experiment_run.py && \
    test -f '$DATASET_FILE' && \
    command -v go >/dev/null && \
    go version >/dev/null && \
    echo ok"
}

check_remote "B" "$MACHINE_B_HOST" "$REMOTE_REPO_ROOT_B"
check_remote "C" "$MACHINE_C_HOST" "$REMOTE_REPO_ROOT_C"
check_remote "D" "$MACHINE_D_HOST" "$REMOTE_REPO_ROOT_D"

tmp_iptable="$(mktemp)"
cp ipTable.json "$tmp_iptable"
cleanup() {
  rm -f "$tmp_iptable"
}
trap cleanup EXIT

machine_b_ip="${MACHINE_B_IP:-${MACHINE_B_HOST##*@}}"
machine_c_ip="${MACHINE_C_IP:-${MACHINE_C_HOST##*@}}"
machine_d_ip="${MACHINE_D_IP:-${MACHINE_D_HOST##*@}}"

"$SCRIPT_DIR/configure_four_machine_iptable.py" \
  --machine-a-ip "$MACHINE_A_IP" \
  --machine-b-ip "$machine_b_ip" \
  --machine-c-ip "$machine_c_ip" \
  --machine-d-ip "$machine_d_ip" \
  --shard-num "${SHARD_NUM:-64}" \
  --nodes-in-shard "${NODES_IN_SHARD:-10}" \
  --iptable "$tmp_iptable"

echo "[preflight] ok: distributed launcher prerequisites look ready"
