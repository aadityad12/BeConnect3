"""Broadcaster runtime loop with live current_alert reload."""

from __future__ import annotations

import asyncio
import logging
import signal
from pathlib import Path

from .storage import AlertStore

LOGGER = logging.getLogger(__name__)


class BroadcastRunner:
    def __init__(self, state_dir: Path | None = None, poll_interval: float = 2.0):
        self.store = AlertStore(state_dir)
        self.poll_interval = poll_interval
        self._stop = asyncio.Event()

    async def run(self) -> None:
        # Lazy import keeps non-BLE CLI operations usable before BLE deps are installed.
        from .ble_server import BluezBeConnectServer

        alert = self.store.get_current_alert()
        if alert is None:
            raise RuntimeError(
                f"No current alert found at {self.store.paths.current_alert_file}. Use `beconnect-pi publish <alert_id>`."
            )

        server = BluezBeConnectServer(alert)
        await server.start()
        self.store.write_pid(self._pid())

        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, self._stop.set)
            except NotImplementedError:
                pass

        LOGGER.info("Broadcast loop active; watching %s", self.store.paths.current_alert_file)

        try:
            last_mtime = self.store.current_alert_mtime()
            while not self._stop.is_set():
                await asyncio.sleep(self.poll_interval)
                current_mtime = self.store.current_alert_mtime()
                if current_mtime is None or current_mtime == last_mtime:
                    continue

                updated = self.store.get_current_alert()
                if updated is None:
                    LOGGER.warning("current_alert.json disappeared; keeping previous alert in memory")
                    continue

                await server.update_alert(updated)
                last_mtime = current_mtime
        finally:
            await server.stop()
            self.store.clear_pid()
            LOGGER.info("Broadcast loop stopped")

    def request_stop(self) -> None:
        self._stop.set()

    @staticmethod
    def _pid() -> int:
        import os

        return os.getpid()


def run_foreground(state_dir: Path | None = None, poll_interval: float = 2.0) -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    runner = BroadcastRunner(state_dir=state_dir, poll_interval=poll_interval)
    asyncio.run(runner.run())
