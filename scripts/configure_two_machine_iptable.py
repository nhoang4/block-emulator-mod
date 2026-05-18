#!/usr/bin/env python3
"""Assign shard node addresses across two machines.

Machine A gets shards [0, split). Machine B gets shards [split, shard_num).
The supervisor always runs on Machine A.
"""

import argparse
import json
from pathlib import Path


SUPERVISOR_SHARD = "2147483647"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--machine-a-ip", required=True, help="LAN/private IP for Machine A")
    parser.add_argument("--machine-b-ip", required=True, help="LAN/private IP for Machine B")
    parser.add_argument("--shard-num", type=int, default=64, help="number of shards to assign")
    parser.add_argument("--nodes-in-shard", type=int, default=10, help="nodes per shard to assign")
    parser.add_argument("--iptable", default="ipTable.json", help="ipTable file to update")
    parser.add_argument(
        "--supervisor-port",
        default="38800",
        help="supervisor TCP port on Machine A",
    )
    args = parser.parse_args()

    path = Path(args.iptable)
    with path.open("r", encoding="utf-8") as f:
        ip_table = json.load(f)

    split = args.shard_num // 2
    for shard_id in range(args.shard_num):
        shard_key = str(shard_id)
        if shard_key not in ip_table:
            raise SystemExit(f"{path} has no shard entry {shard_key}")
        host = args.machine_a_ip if shard_id < split else args.machine_b_ip
        for node_id in range(args.nodes_in_shard):
            node_key = str(node_id)
            if node_key not in ip_table[shard_key]:
                raise SystemExit(f"{path} has no node entry shard={shard_id} node={node_id}")
            _, port = ip_table[shard_key][node_key].rsplit(":", 1)
            ip_table[shard_key][node_key] = f"{host}:{port}"

    ip_table.setdefault(SUPERVISOR_SHARD, {})
    ip_table[SUPERVISOR_SHARD]["0"] = f"{args.machine_a_ip}:{args.supervisor_port}"

    with path.open("w", encoding="utf-8") as f:
        json.dump(ip_table, f, indent=2)
        f.write("\n")

    print(f"updated {path}")
    print(f"machine A shards: 0..{split - 1}")
    print(f"machine B shards: {split}..{args.shard_num - 1}")
    print(f"supervisor: {ip_table[SUPERVISOR_SHARD]['0']}")


if __name__ == "__main__":
    main()
