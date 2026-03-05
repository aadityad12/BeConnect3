"""beacon CLI — create alerts and broadcast them over BLE."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from pathlib import Path

from .constants import ALLOWED_SEVERITIES
from .model import AlertPacket, build_alert, now_epoch, parse_epoch
from .storage import AlertStore


# ── Helpers ────────────────────────────────────────────────────────────────────

def _store(args: argparse.Namespace) -> AlertStore:
    d = Path(args.state_dir).expanduser() if args.state_dir else None
    return AlertStore(d)


def _print_alert(a: AlertPacket) -> None:
    print(f"  {a.alertId}  [{a.severity}]  {a.headline}")


def _bool(v: str) -> bool:
    if v.lower() in {"1", "true", "yes", "y"}:
        return True
    if v.lower() in {"0", "false", "no", "n"}:
        return False
    raise argparse.ArgumentTypeError(f"Not a boolean: {v!r}")


# ── Commands ───────────────────────────────────────────────────────────────────

def cmd_new(args: argparse.Namespace) -> int:
    store = _store(args)
    expires   = parse_epoch(args.expires)
    fetched   = parse_epoch(args.fetched_at) if args.fetched_at else now_epoch()
    alert = build_alert(
        headline=args.headline,
        severity=args.severity,
        expires=expires,
        instructions=args.instructions,
        source_url=args.source_url,
        verified=args.verified,
        fetched_at=fetched,
    )
    store.upsert(alert)
    print(f"Created alert {alert.alertId}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    alerts = _store(args).all()
    if not alerts:
        print("No alerts saved.")
        return 0
    current = _store(args).current()
    for a in alerts:
        marker = " ← current" if current and a.alertId == current.alertId else ""
        _print_alert(a)
        print(f"         expires={a.expires}  verified={a.verified}{marker}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    a = _store(args).get(args.alert_id)
    if a is None:
        print(f"Alert not found: {args.alert_id}", file=sys.stderr)
        return 1
    print(json.dumps(a.to_dict(), indent=2))
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    if not _store(args).delete(args.alert_id):
        print(f"Alert not found: {args.alert_id}", file=sys.stderr)
        return 1
    print(f"Deleted {args.alert_id}")
    return 0


def cmd_publish(args: argparse.Namespace) -> int:
    try:
        alert = _store(args).publish(args.alert_id)
        print(f"Published: [{alert.severity}] {alert.headline}")
        return 0
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


def cmd_broadcast(args: argparse.Namespace) -> int:
    """Start BLE advertising on the main thread (asyncio event loop)."""
    store = _store(args)
    alert = store.current()
    if alert is None:
        print(
            "No current alert. Run:\n"
            "  beacon new --headline '...' --severity Extreme "
            "--expires <epoch> --instructions '...' --source-url '...'\n"
            "  beacon publish <alert_id>",
            file=sys.stderr,
        )
        return 1

    if args.verbose:
        logging.basicConfig(
            level=logging.DEBUG,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )

    from .ble_server import BeConnectServer
    server = BeConnectServer(alert)

    # BLE runs in asyncio event loop on the main thread.
    try:
        asyncio.run(server.run())
    except KeyboardInterrupt:
        pass
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    store = _store(args)
    current = store.current()
    alerts  = store.all()
    print(f"State dir : {store.root}")
    print(f"Alerts    : {len(alerts)}")
    if current:
        print(f"Published : [{current.severity}] {current.headline}  (id={current.alertId})")
    else:
        print("Published : none")
    return 0


# ── Parser ─────────────────────────────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="beacon",
        description="BeConnect BLE beacon CLI — macOS & Windows",
    )
    p.add_argument("--state-dir", default=None, metavar="DIR",
                   help="Override state directory (default: ~/.beacon-cli)")

    sub = p.add_subparsers(dest="command", required=True)

    # new
    n = sub.add_parser("new", help="Create a new alert")
    n.add_argument("--headline",      required=True)
    n.add_argument("--severity",      required=True, choices=ALLOWED_SEVERITIES)
    n.add_argument("--expires",       required=True, help="Unix epoch seconds or ISO8601")
    n.add_argument("--instructions",  required=True)
    n.add_argument("--source-url",    required=True)
    n.add_argument("--verified",      type=_bool, default=False)
    n.add_argument("--fetched-at",    default=None)
    n.set_defaults(func=cmd_new)

    # list
    ls = sub.add_parser("list", help="List all saved alerts")
    ls.set_defaults(func=cmd_list)

    # show
    sh = sub.add_parser("show", help="Show one alert as JSON")
    sh.add_argument("alert_id")
    sh.set_defaults(func=cmd_show)

    # delete
    dl = sub.add_parser("delete", help="Delete an alert")
    dl.add_argument("alert_id")
    dl.set_defaults(func=cmd_delete)

    # publish
    pb = sub.add_parser("publish", help="Set the alert to broadcast")
    pb.add_argument("alert_id")
    pb.set_defaults(func=cmd_publish)

    # broadcast
    bc = sub.add_parser("broadcast", help="Start BLE advertising (Ctrl+C to stop)")
    bc.add_argument("-v", "--verbose", action="store_true", help="Debug BLE log output")
    bc.set_defaults(func=cmd_broadcast)

    # status
    st = sub.add_parser("status", help="Show state dir and published alert")
    st.set_defaults(func=cmd_status)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
