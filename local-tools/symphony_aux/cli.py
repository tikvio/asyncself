"""Local diagnostics for the webhook accelerator."""

from __future__ import annotations

import argparse
import json

from .config import load_config
from .inbox import Inbox


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("mode")
    sub.add_parser("check-config")
    sub.add_parser("status")
    replay = sub.add_parser("replay")
    replay.add_argument("--job", type=int, required=True)
    replay.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    config = load_config(args.config, require_secrets=False)
    if args.command == "mode":
        print(config.mode)
        return 0
    if args.command == "check-config":
        print(json.dumps({
            "profile": config.profile,
            "mode": config.mode,
            "allowed_sources": config.allowed_sources,
            "linear_consumers": config.linear_consumers,
            "receiver": f"{config.receiver_host}:{config.receiver_port}",
            "storage_dir": str(config.storage_dir),
            "secret_variables_present": config.secret_presence(),
        }, sort_keys=True))
        return 0
    inbox = Inbox(config.inbox_path)
    inbox.initialize()
    if args.command == "status":
        print(json.dumps({"mode": config.mode, **inbox.status()}, sort_keys=True))
        return 0
    if not args.execute:
        print(f"dry-run: would replay job {args.job}")
        return 0
    if not inbox.replay(args.job):
        raise RuntimeError("job not found")
    print(f"replayed job {args.job}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
