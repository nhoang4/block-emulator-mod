#!/usr/bin/env python3
"""Assign shard node addresses across four machines.

Machine A gets the first quarter of shards and runs the supervisor.
Machines B, C, and D run worker shards only.
"""

import argparse
import json
from pathlib import Path


SUPERVISOR_SHARD = "2147483647"


def shard_range(shard_num: int, worker_index: int, worker_count: int = 4) -> tuple[int, int]:
    start = worker_index * shard_num // worker_count
    end = (worker_index + 1) * shard_num // worker_count - 1
    return start, end


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--machine-a-ip", required=True, help="LAN/private IP for Machine A")
    parser.add_argument("--machine-b-ip", required=True, help="LAN/private IP for Machine B")
    parser.add_argument("--machine-c-ip", required=True, help="LAN/private IP for Machine C")
    parser.add_argument("--machine-d-ip", required=True, help="LAN/private IP for Machine D")
    parser.add_argument("--shard-num", type=int, default=64, help="number of shards to assign")
    parser.add_argument("--nodes-in-shard", type=int, default=10, help="nodes per shard to assign")
    parser.add_argument("--iptable", default="ipTable.json", help="ipTable file to update")
    parser.add_argument("--supervisor-port", default="38800", help="supervisor TCP port on Machine A")
    args = parser.parse_args()

    path = Path(args.iptable)
    with path.open("r", encoding="utf-8") as f:
        ip_table = json.load(f)

    machine_ips = [
        args.machine_a_ip,
        args.machine_b_ip,
        args.machine_c_ip,
        args.machine_d_ip,
    ]

    for worker_index, host in enumerate(machine_ips):
        start, end = shard_range(args.shard_num, worker_index)
        for shard_id in range(start, end + 1):
            shard_key = str(shard_id)
            if shard_key not in ip_table:
                raise SystemExit(f"{path} has no shard entry {shard_key}")
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
    for name, host, worker_index in zip(("A", "B", "C", "D"), machine_ips, range(4)):
        start, end = shard_range(args.shard_num, worker_index)
        print(f"machine {name} {host} shards: {start}..{end}")
    print(f"supervisor: {ip_table[SUPERVISOR_SHARD]['0']}")


if __name__ == "__main__":
    main()
