#!/usr/bin/env python3
import argparse
import csv
import re
from decimal import Decimal, InvalidOperation
from pathlib import Path


FIELDS = [
    "started_at",
    "finished_at",
    "mode",
    "shard_num",
    "nodes_in_shard",
    "repeat",
    "status",
    "exit_code",
    "run_root",
    "tps",
    "avg_cl_sec",
    "wall_sec",
    "total_tx",
    "normal_tx",
    "stage1_tx",
    "stage2_tx",
    "ctx_tx",
    "ctx_ratio",
    "epoch0_channels",
    "post_epoch_channel_avg",
    "post_epoch_channel_min",
    "post_epoch_channel_max",
    "post_epoch_channel_count",
    "channel_model",
    "notes",
]


def dec(value):
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError):
        return None


def decimal_str(value, places=None):
    if value is None:
        return ""
    if places is None:
        return format(value, "f")
    q = Decimal(1).scaleb(-places)
    return format(value.quantize(q), "f")


def read_second_row(path):
    if not path.exists():
        return None
    with path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        return None
    return rows[1]


def parse_channels(run_root, mode, shard_num):
    complete = shard_num * (shard_num - 1) // 2
    if mode == "complete_bridge":
        return complete, Decimal(complete), complete, complete, 1, "complete"
    if mode == "broker":
        return "", "", "", "", 0, "n/a"

    supervisor = run_root / "machine-a" / "supervisor.out"
    epoch0 = ""
    selected = []
    if supervisor.exists():
        for line in supervisor.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = re.search(r"broadcast bridge overlay epoch 0 .* edges (\d+)", line)
            if m:
                epoch0 = int(m.group(1))
            m = re.search(r"bridge overlay epoch (\d+) selected (\d+) edges", line)
            if m and int(m.group(1)) >= 1:
                selected.append(int(m.group(2)))

    if not selected:
        return epoch0, "", "", "", 0, "overlay"

    avg = Decimal(sum(selected)) / Decimal(len(selected))
    return epoch0, avg, min(selected), max(selected), len(selected), "overlay"


def summarize(args):
    run_root = Path(args.run_root).resolve()
    result_dir = run_root / "machine-a" / "expTest" / "result" / "supervisor_measureOutput"
    avg_row = read_second_row(result_dir / "Average_TPS.csv")
    cl_row = read_second_row(result_dir / "Transaction_Confirm_Latency.csv")
    ctx_row = read_second_row(result_dir / "CrossTransaction_ratio.csv")

    notes = []
    status = args.status
    if avg_row is None:
        notes.append("missing Average_TPS.csv")
    if cl_row is None:
        notes.append("missing Transaction_Confirm_Latency.csv")
    if ctx_row is None:
        notes.append("missing CrossTransaction_ratio.csv")

    total_tx = dec(avg_row[1]) if avg_row and len(avg_row) > 1 else None
    normal_tx = avg_row[2] if avg_row and len(avg_row) > 2 else ""
    stage1_tx = avg_row[3] if avg_row and len(avg_row) > 3 else ""
    stage2_tx = avg_row[4] if avg_row and len(avg_row) > 4 else ""
    start_ms = dec(avg_row[5]) if avg_row and len(avg_row) > 5 else None
    end_ms = dec(avg_row[6]) if avg_row and len(avg_row) > 6 else None
    tps = dec(avg_row[7]) if avg_row and len(avg_row) > 7 else None
    wall_sec = (end_ms - start_ms) / Decimal(1000) if start_ms is not None and end_ms is not None else None

    sum_all_cl = dec(cl_row[9]) if cl_row and len(cl_row) > 9 else None
    avg_cl_sec = sum_all_cl / total_tx if sum_all_cl is not None and total_tx not in (None, Decimal(0)) else None

    ctx_tx = ctx_row[2] if ctx_row and len(ctx_row) > 2 else ""
    ctx_ratio = dec(ctx_row[6]) if ctx_row and len(ctx_row) > 6 else None

    epoch0_channels, post_avg, post_min, post_max, post_count, channel_model = parse_channels(
        run_root, args.mode, int(args.shard_num)
    )

    row = {
        "started_at": args.started_at,
        "finished_at": args.finished_at,
        "mode": args.mode,
        "shard_num": args.shard_num,
        "nodes_in_shard": args.nodes_in_shard,
        "repeat": args.repeat,
        "status": status,
        "exit_code": args.exit_code,
        "run_root": str(run_root),
        "tps": decimal_str(tps),
        "avg_cl_sec": decimal_str(avg_cl_sec, 6),
        "wall_sec": decimal_str(wall_sec, 3),
        "total_tx": decimal_str(total_tx),
        "normal_tx": normal_tx,
        "stage1_tx": stage1_tx,
        "stage2_tx": stage2_tx,
        "ctx_tx": ctx_tx,
        "ctx_ratio": decimal_str(ctx_ratio),
        "epoch0_channels": epoch0_channels,
        "post_epoch_channel_avg": decimal_str(post_avg, 3) if isinstance(post_avg, Decimal) else post_avg,
        "post_epoch_channel_min": post_min,
        "post_epoch_channel_max": post_max,
        "post_epoch_channel_count": post_count,
        "channel_model": channel_model,
        "notes": "; ".join(notes),
    }

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not out_path.exists()
    with out_path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        if write_header:
            writer.writeheader()
        writer.writerow(row)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--shard-num", required=True)
    parser.add_argument("--nodes-in-shard", required=True)
    parser.add_argument("--repeat", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--exit-code", required=True)
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--finished-at", required=True)
    parser.add_argument("--out", required=True)
    summarize(parser.parse_args())


if __name__ == "__main__":
    main()
