#!/usr/bin/env bash
set -euo pipefail

# Single-machine 16x10 transaction-size sweep with result auto-push enabled.
# Pushes only results/txsize-16x10/<run-id>-summary.csv, not the run logs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export AUTO_PUSH_RESULTS=1
exec "$SCRIPT_DIR/run_linux_txsize_16x10.sh"
