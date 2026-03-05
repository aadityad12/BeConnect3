"""Persistent state: alerts + current published alert."""

from __future__ import annotations

import json
from pathlib import Path

from .model import AlertPacket

_DEFAULT_DIR = Path.home() / ".beacon-cli"


class AlertStore:
    def __init__(self, state_dir: Path | None = None):
        self.root = (state_dir or _DEFAULT_DIR).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self._alerts_file = self.root / "alerts.json"
        self._current_file = self.root / "current_alert.json"

    # ── Alerts ─────────────────────────────────────────────────────────────────

    def _load_raw(self) -> dict[str, dict]:
        if not self._alerts_file.exists():
            return {}
        try:
            return json.loads(self._alerts_file.read_text())
        except (json.JSONDecodeError, OSError):
            return {}

    def _save_raw(self, data: dict[str, dict]) -> None:
        self._alerts_file.write_text(json.dumps(data, indent=2))

    def upsert(self, alert: AlertPacket) -> None:
        data = self._load_raw()
        data[alert.alertId] = alert.to_dict()
        self._save_raw(data)

    def get(self, alert_id: str) -> AlertPacket | None:
        data = self._load_raw()
        raw = data.get(alert_id)
        return AlertPacket.from_dict(raw) if raw else None

    def all(self) -> list[AlertPacket]:
        return [AlertPacket.from_dict(v) for v in self._load_raw().values()]

    def delete(self, alert_id: str) -> bool:
        data = self._load_raw()
        if alert_id not in data:
            return False
        del data[alert_id]
        self._save_raw(data)
        if self.current() and self.current().alertId == alert_id:
            self._current_file.unlink(missing_ok=True)
        return True

    # ── Current (published) alert ───────────────────────────────────────────────

    def publish(self, alert_id: str) -> AlertPacket:
        alert = self.get(alert_id)
        if alert is None:
            raise ValueError(f"Alert not found: {alert_id}")
        self._current_file.write_text(json.dumps(alert.to_dict(), indent=2))
        return alert

    def current(self) -> AlertPacket | None:
        if not self._current_file.exists():
            return None
        try:
            return AlertPacket.from_dict(json.loads(self._current_file.read_text()))
        except (json.JSONDecodeError, ValueError, OSError):
            return None
