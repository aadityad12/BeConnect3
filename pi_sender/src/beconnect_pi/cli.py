"""CLI entrypoint for beconnect-pi."""

from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from .broadcaster import run_foreground
from .constants import ALLOWED_SEVERITIES
from .model import AlertPacket, build_alert, now_epoch, parse_epoch
from .storage import AlertStore


def _bool_arg(value: str) -> bool:
    lowered = value.lower().strip()
    if lowered in {"1", "true", "yes", "y", "on"}:
        return True
    if lowered in {"0", "false", "no", "n", "off"}:
        return False
    raise argparse.ArgumentTypeError(f"Invalid boolean value: {value}")


def _store_from_args(args: argparse.Namespace) -> AlertStore:
    return AlertStore(Path(args.state_dir).expanduser() if args.state_dir else None)


def _print_alert_compact(alert: AlertPacket) -> None:
    print(
        f"{alert.alertId}\t{alert.severity}\t{alert.expires}\t"
        f"verified={alert.verified}\t{alert.headline}"
    )


def cmd_alert_new(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    expires = parse_epoch(args.expires)
    fetched_at = parse_epoch(args.fetched_at) if args.fetched_at else now_epoch()

    alert = build_alert(
        headline=args.headline,
        severity=args.severity,
        expires=expires,
        instructions=args.instructions,
        source_url=args.source_url,
        verified=args.verified,
        alert_id=args.alert_id,
        fetched_at=fetched_at,
    )
    store.upsert_alert(alert)
    print(f"Created alert {alert.alertId}")
    return 0


def cmd_alert_edit(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    alert = store.get_alert(args.alert_id)
    if alert is None:
        print(f"Alert not found: {args.alert_id}", file=sys.stderr)
        return 1

    updates = {
        "severity": args.severity,
        "headline": args.headline,
        "instructions": args.instructions,
        "sourceUrl": args.source_url,
        "verified": args.verified,
        "expires": parse_epoch(args.expires) if args.expires else None,
    }

    payload = alert.to_dict()
    for key, value in updates.items():
        if value is not None:
            payload[key] = value

    updated = AlertPacket.from_dict(payload)
    store.upsert_alert(updated)
    print(f"Updated alert {updated.alertId}")
    return 0


def cmd_alert_list(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    alerts = store.load_alerts()
    if not alerts:
        print("No alerts saved")
        return 0
    for alert in alerts:
        _print_alert_compact(alert)
    return 0


def cmd_alert_show(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    alert = store.get_alert(args.alert_id)
    if alert is None:
        print(f"Alert not found: {args.alert_id}", file=sys.stderr)
        return 1
    print(json.dumps(alert.to_dict(), indent=2))
    return 0


def cmd_alert_delete(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    deleted = store.delete_alert(args.alert_id)
    if not deleted:
        print(f"Alert not found: {args.alert_id}", file=sys.stderr)
        return 1
    print(f"Deleted alert {args.alert_id}")
    return 0


def cmd_publish(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    alert = store.publish(args.alert_id)
    print(f"Published alert {alert.alertId}: {alert.headline}")
    return 0


def _running_pid(store: AlertStore) -> int | None:
    pid = store.read_pid()
    if pid is None:
        return None
    if not store.is_pid_alive(pid):
        store.clear_pid()
        return None
    return pid


def cmd_broadcast_start(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    existing = _running_pid(store)
    if existing:
        print(f"Broadcaster already running (pid={existing})")
        return 0

    if store.get_current_alert() is None:
        print(
            f"No current alert at {store.paths.current_alert_file}. Run `beconnect-pi publish <alert_id>` first.",
            file=sys.stderr,
        )
        return 1

    if args.foreground:
        run_foreground(state_dir=store.paths.root, poll_interval=args.poll_interval)
        return 0

    with store.paths.log_file.open("a", encoding="utf-8") as logf:
        proc = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "beconnect_pi",
                "_broadcast-run",
                "--state-dir",
                str(store.paths.root),
                "--poll-interval",
                str(args.poll_interval),
            ],
            stdin=subprocess.DEVNULL,
            stdout=logf,
            stderr=logf,
            start_new_session=True,
        )

    time.sleep(0.25)
    if proc.poll() is not None:
        print(
            f"Broadcaster failed to start. Check log: {store.paths.log_file}",
            file=sys.stderr,
        )
        return 1

    store.write_pid(proc.pid)
    print(f"Broadcaster started (pid={proc.pid})")
    print(f"Logs: {store.paths.log_file}")
    return 0


def cmd_broadcast_stop(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    pid = _running_pid(store)
    if pid is None:
        print("Broadcaster is not running")
        return 0

    os.kill(pid, signal.SIGTERM)
    for _ in range(25):
        if not store.is_pid_alive(pid):
            break
        time.sleep(0.1)

    if store.is_pid_alive(pid):
        print(f"Broadcaster still running (pid={pid})", file=sys.stderr)
        return 1

    store.clear_pid()
    print("Broadcaster stopped")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    store = _store_from_args(args)
    pid = _running_pid(store)
    current = store.get_current_alert()

    if pid:
        print(f"Broadcaster: running (pid={pid})")
    else:
        print("Broadcaster: stopped")

    if current:
        print(f"Current alert: {current.alertId} [{current.severity}] {current.headline}")
    else:
        print("Current alert: none")
    print(f"State dir: {store.paths.root}")
    return 0


def cmd_internal_broadcast_run(args: argparse.Namespace) -> int:
    run_foreground(
        state_dir=Path(args.state_dir).expanduser() if args.state_dir else None,
        poll_interval=args.poll_interval,
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="beconnect-pi")
    parser.add_argument("--state-dir", default=None, help="Override state directory (default: ~/.beconnect-pi)")

    sub = parser.add_subparsers(dest="command", required=True)

    alert = sub.add_parser("alert", help="Create/edit/list/show/delete alerts")
    alert_sub = alert.add_subparsers(dest="alert_command", required=True)

    alert_new = alert_sub.add_parser("new", help="Create an alert")
    alert_new.add_argument("--alert-id", default=None)
    alert_new.add_argument("--headline", required=True)
    alert_new.add_argument("--severity", required=True, choices=ALLOWED_SEVERITIES)
    alert_new.add_argument("--expires", required=True, help="Unix seconds or ISO8601")
    alert_new.add_argument("--instructions", required=True)
    alert_new.add_argument("--source-url", required=True)
    alert_new.add_argument("--verified", type=_bool_arg, default=False)
    alert_new.add_argument("--fetched-at", default=None, help="Unix seconds or ISO8601")
    alert_new.set_defaults(func=cmd_alert_new)

    alert_edit = alert_sub.add_parser("edit", help="Edit an alert")
    alert_edit.add_argument("alert_id")
    alert_edit.add_argument("--headline", default=None)
    alert_edit.add_argument("--severity", default=None, choices=ALLOWED_SEVERITIES)
    alert_edit.add_argument("--expires", default=None, help="Unix seconds or ISO8601")
    alert_edit.add_argument("--instructions", default=None)
    alert_edit.add_argument("--source-url", default=None)
    alert_edit.add_argument("--verified", type=_bool_arg, default=None)
    alert_edit.set_defaults(func=cmd_alert_edit)

    alert_list = alert_sub.add_parser("list", help="List alerts")
    alert_list.set_defaults(func=cmd_alert_list)

    alert_show = alert_sub.add_parser("show", help="Show one alert")
    alert_show.add_argument("alert_id")
    alert_show.set_defaults(func=cmd_alert_show)

    alert_delete = alert_sub.add_parser("delete", help="Delete one alert")
    alert_delete.add_argument("alert_id")
    alert_delete.set_defaults(func=cmd_alert_delete)

    publish = sub.add_parser("publish", help="Publish alert to current_alert.json")
    publish.add_argument("alert_id")
    publish.set_defaults(func=cmd_publish)

    broadcast = sub.add_parser("broadcast", help="Control BLE broadcaster")
    broadcast_sub = broadcast.add_subparsers(dest="broadcast_command", required=True)

    bstart = broadcast_sub.add_parser("start", help="Start broadcaster")
    bstart.add_argument("--foreground", action="store_true", help="Run in foreground")
    bstart.add_argument("--poll-interval", type=float, default=2.0)
    bstart.set_defaults(func=cmd_broadcast_start)

    bstop = broadcast_sub.add_parser("stop", help="Stop broadcaster")
    bstop.set_defaults(func=cmd_broadcast_stop)

    status = sub.add_parser("status", help="Show broadcaster status")
    status.set_defaults(func=cmd_status)

    # Internal command used by background launcher.
    internal = sub.add_parser("_broadcast-run")
    internal.add_argument("--state-dir", default=None)
    internal.add_argument("--poll-interval", type=float, default=2.0)
    internal.set_defaults(func=cmd_internal_broadcast_run)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "_broadcast-run":
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )

    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
