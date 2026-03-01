from __future__ import annotations

import io
import os
import signal
import sys
import time
from pathlib import Path
from typing import Tuple

import streamlit as st

from beconnect_pi.constants import ALLOWED_SEVERITIES
from beconnect_pi.model import AlertPacket, build_alert, parse_epoch
from beconnect_pi.storage import AlertStore


def _get_store(state_dir: str | None = None) -> AlertStore:
    return AlertStore(Path(state_dir).expanduser() if state_dir else None)


def _running_pid(store: AlertStore) -> int | None:
    """Mirror CLI logic to resolve a live broadcaster PID."""
    pid = store.read_pid()
    if pid is None:
        return None
    if not store.is_pid_alive(pid):
        store.clear_pid()
        return None
    return pid


def start_broadcaster(store: AlertStore, poll_interval: float = 2.0) -> Tuple[bool, str]:
    """Start the BLE broadcaster in a background process."""
    existing = _running_pid(store)
    if existing:
        return False, f"Broadcaster already running (pid={existing})"

    if store.get_current_alert() is None:
        return (
            False,
            f"No current alert at {store.paths.current_alert_file}. "
            "Publish an alert before starting the broadcaster.",
        )

    # Spawn the same background process as the CLI.
    import subprocess  # imported lazily to avoid issues in limited environments

    store.paths.log_file.parent.mkdir(parents=True, exist_ok=True)

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
                str(poll_interval),
            ],
            stdin=subprocess.DEVNULL,
            stdout=logf,
            stderr=logf,
            start_new_session=True,
        )

    # Give it a moment to fail fast if there is a startup error.
    time.sleep(0.25)
    if proc.poll() is not None:
        return (
            False,
            f"Broadcaster failed to start. Check log file at {store.paths.log_file}",
        )

    store.write_pid(proc.pid)
    return True, f"Broadcaster started (pid={proc.pid}). Logs: {store.paths.log_file}"


def stop_broadcaster(store: AlertStore) -> Tuple[bool, str]:
    """Stop the BLE broadcaster background process."""
    pid = _running_pid(store)
    if pid is None:
        return True, "Broadcaster is not running."

    os.kill(pid, signal.SIGTERM)
    for _ in range(25):
        if not store.is_pid_alive(pid):
            break
        time.sleep(0.1)

    if store.is_pid_alive(pid):
        return False, f"Broadcaster still running (pid={pid})"

    store.clear_pid()
    return True, "Broadcaster stopped."


def get_broadcast_status(store: AlertStore) -> str:
    """Return a human-readable broadcaster status summary."""
    pid = _running_pid(store)
    current = store.get_current_alert()

    out = io.StringIO()
    if pid:
        out.write(f"Broadcaster: running (pid={pid})\n")
    else:
        out.write("Broadcaster: stopped\n")

    if current:
        out.write(
            f"Current alert: {current.alertId} "
            f"[{current.severity}] {current.headline}\n"
        )
    else:
        out.write("Current alert: none\n")

    out.write(f"State dir: {store.paths.root}\n")
    return out.getvalue()


def _render_alert_row(alert: AlertPacket, store: AlertStore) -> None:
    col_headline, col_publish, col_delete = st.columns([5, 2, 2])
    with col_headline:
        st.markdown(
            f"**[{alert.severity}]** {alert.headline}  \n"
            f"`id={alert.alertId}` · expires={alert.expires}"
        )
    with col_publish:
        if st.button("Publish", key=f"pub-{alert.alertId}"):
            try:
                store.publish(alert.alertId)
                st.success(f"Published alert {alert.alertId}")
            except Exception as exc:  # noqa: BLE001
                st.error(f"Failed to publish alert: {exc}")
    with col_delete:
        if st.button("Delete", key=f"del-{alert.alertId}"):
            if store.delete_alert(alert.alertId):
                st.warning(f"Deleted alert {alert.alertId}")
            else:
                st.error("Alert not found; refresh the page.")


def page_alerts(store: AlertStore) -> None:
    st.header("Alerts")

    alerts = store.load_alerts()
    if alerts:
        st.subheader("Saved alerts")
        for alert in alerts:
            _render_alert_row(alert, store)
            st.markdown("---")
    else:
        st.info("No alerts saved yet. Use the form below to create one.")

    st.subheader("Create new alert")
    with st.form("new_alert"):
        headline = st.text_input("Headline", "")
        severity = st.selectbox("Severity", ALLOWED_SEVERITIES, index=0)
        expires_raw = st.text_input(
            "Expires (Unix seconds or ISO8601)", help="Example: 1767225600 or 2026-01-31T00:00:00Z"
        )
        instructions = st.text_area("Instructions")
        source_url = st.text_input("Source URL", "local://operator")
        verified = st.checkbox("Verified", value=False)
        submitted = st.form_submit_button("Save alert")

    if submitted:
        try:
            expires = parse_epoch(expires_raw)
            alert = build_alert(
                headline=headline,
                severity=severity,
                expires=expires,
                instructions=instructions,
                source_url=source_url,
                verified=verified,
            )
            store.upsert_alert(alert)
            st.success(f"Saved alert {alert.alertId}")
        except Exception as exc:  # noqa: BLE001
            st.error(f"Failed to save alert: {exc}")


def page_broadcast(store: AlertStore) -> None:
    st.header("Broadcast control")

    col_start, col_stop, col_refresh = st.columns(3)
    with col_start:
        if st.button("Start broadcaster"):
            ok, msg = start_broadcaster(store)
            (st.success if ok else st.error)(msg)
    with col_stop:
        if st.button("Stop broadcaster"):
            ok, msg = stop_broadcaster(store)
            (st.success if ok else st.error)(msg)
    with col_refresh:
        if st.button("Refresh status"):
            st.session_state["_last_status"] = get_broadcast_status(store)

    status_text = st.session_state.get("_last_status", get_broadcast_status(store))
    st.subheader("Status")
    st.code(status_text, language="text")

    st.subheader("Broadcaster log (tail)")
    if store.paths.log_file.exists():
        try:
            lines = store.paths.log_file.read_text(encoding="utf-8").splitlines()
            tail = "\n".join(lines[-200:])
            st.text_area("broadcaster.log", tail, height=240)
        except Exception as exc:  # noqa: BLE001
            st.error(f"Failed to read log file: {exc}")
    else:
        st.info("No log file yet. Start the broadcaster to generate logs.")


def main() -> None:
    st.set_page_config(page_title="BeConnect Pi Sender", layout="wide")

    state_dir = os.environ.get("BECONNECT_PI_STATE_DIR")  # optional override
    store = _get_store(state_dir)

    st.sidebar.title("BeConnect Pi Sender")
    page = st.sidebar.radio("Section", ["Alerts", "Broadcast"])

    if page == "Alerts":
        page_alerts(store)
    else:
        page_broadcast(store)


if __name__ == "__main__":
    main()

