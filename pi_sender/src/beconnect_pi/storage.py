"""Local persistent storage for alerts and broadcaster state."""

from __future__ import annotations

import json
import os
import signal
from dataclasses import dataclass
from pathlib import Path

from .model import AlertPacket


@dataclass(frozen=True)
class StoragePaths:
    root: Path
    alerts_file: Path
    current_alert_file: Path
    pid_file: Path
    log_file: Path


class AlertStore:
    def __init__(self, state_dir: Path | None = None):
        root = state_dir or Path.home() / ".beconnect-pi"
        self.paths = StoragePaths(
            root=root,
            alerts_file=root / "alerts.json",
            current_alert_file=root / "current_alert.json",
            pid_file=root / "broadcaster.pid",
            log_file=root / "broadcaster.log",
        )
        self.paths.root.mkdir(parents=True, exist_ok=True)

    def _atomic_write_json(self, target: Path, payload: object) -> None:
        tmp = target.with_suffix(target.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        tmp.replace(target)

    def load_alerts(self) -> list[AlertPacket]:
        if not self.paths.alerts_file.exists():
            return []
        raw = json.loads(self.paths.alerts_file.read_text(encoding="utf-8"))
        return [AlertPacket.from_dict(item) for item in raw]

    def save_alerts(self, alerts: list[AlertPacket]) -> None:
        self._atomic_write_json(self.paths.alerts_file, [a.to_dict() for a in alerts])

    def get_alert(self, alert_id: str) -> AlertPacket | None:
        for alert in self.load_alerts():
            if alert.alertId == alert_id:
                return alert
        return None

    def upsert_alert(self, alert: AlertPacket) -> None:
        alerts = self.load_alerts()
        by_id = {a.alertId: a for a in alerts}
        by_id[alert.alertId] = alert
        self.save_alerts(sorted(by_id.values(), key=lambda a: a.fetchedAt, reverse=True))

    def delete_alert(self, alert_id: str) -> bool:
        alerts = self.load_alerts()
        filtered = [a for a in alerts if a.alertId != alert_id]
        if len(filtered) == len(alerts):
            return False
        self.save_alerts(filtered)
        return True

    def publish(self, alert_id: str) -> AlertPacket:
        alert = self.get_alert(alert_id)
        if alert is None:
            raise ValueError(f"Alert '{alert_id}' not found")
        self._atomic_write_json(self.paths.current_alert_file, alert.to_dict())
        return alert

    def get_current_alert(self) -> AlertPacket | None:
        if not self.paths.current_alert_file.exists():
            return None
        payload = json.loads(self.paths.current_alert_file.read_text(encoding="utf-8"))
        return AlertPacket.from_dict(payload)

    def current_alert_mtime(self) -> float | None:
        if not self.paths.current_alert_file.exists():
            return None
        return self.paths.current_alert_file.stat().st_mtime

    def read_pid(self) -> int | None:
        if not self.paths.pid_file.exists():
            return None
        try:
            return int(self.paths.pid_file.read_text(encoding="utf-8").strip())
        except ValueError:
            return None

    def write_pid(self, pid: int) -> None:
        self.paths.pid_file.write_text(f"{pid}\n", encoding="utf-8")

    def clear_pid(self) -> None:
        self.paths.pid_file.unlink(missing_ok=True)

    def is_pid_alive(self, pid: int) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def stop_pid(self, pid: int) -> None:
        os.kill(pid, signal.SIGTERM)
