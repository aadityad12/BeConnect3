"""BLE GATT peripheral server using bless (macOS CoreBluetooth + Windows WinRT).

BLE transmission runs in the asyncio event loop on the main thread.
The bless library handles platform-specific threading internally.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from typing import Any

from bless import (
    BlessGATTCharacteristic,
    BlessServer,
    GATTAttributePermissions,
    GATTCharacteristicProperties,
)

from .constants import ALERT_CHAR_UUID, CHUNK_SIZE, CONTROL_CHAR_UUID, SERVICE_UUID
from .model import AlertPacket
from .protocol import build_frames

log = logging.getLogger(__name__)

# Normalize UUID for comparison: lowercase, no dashes.
def _uuid_key(uuid: str) -> str:
    return uuid.lower().replace("-", "")

_ALERT_KEY   = _uuid_key(ALERT_CHAR_UUID)
_CONTROL_KEY = _uuid_key(CONTROL_CHAR_UUID)


class BeConnectServer:
    """GATT server that advertises one alert at a time.

    Usage (runs until cancelled):
        server = BeConnectServer(alert)
        await server.run()   # blocks; Ctrl+C → clean shutdown
    """

    def __init__(self, alert: AlertPacket) -> None:
        self._alert  = alert
        self._frames = build_frames(alert, CHUNK_SIZE)
        # Per-server chunk index (one connection at a time is the normal case)
        self._chunk_idx = 0
        self._server: BlessServer | None = None

    # ── Public interface ────────────────────────────────────────────────────────

    async def run(self) -> None:
        """Start advertising and block until KeyboardInterrupt or task cancel."""
        loop = asyncio.get_running_loop()

        # bless ≥ 0.2.2: pass loop= for macOS CoreBluetooth compatibility
        self._server = BlessServer(name="BeConnect", loop=loop)
        self._server.read_request_func  = self._on_read
        self._server.write_request_func = self._on_write

        await self._server.add_new_service(SERVICE_UUID)

        # Alert characteristic — READ, served dynamically via read_request_func.
        # value=None tells CoreBluetooth to always invoke the handler (dynamic).
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            ALERT_CHAR_UUID,
            GATTCharacteristicProperties.read,
            None,
            GATTAttributePermissions.readable,
        )

        # Control characteristic — WRITE only, no cached value.
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            CONTROL_CHAR_UUID,
            GATTCharacteristicProperties.write
            | GATTCharacteristicProperties.write_without_response,
            None,
            GATTAttributePermissions.writeable,
        )

        await self._server.start()
        chunks = len(self._frames)
        log.info(
            "BLE advertising started  alert=%s  severity=%s  chunks=%d",
            self._alert.alertId,
            self._alert.severity,
            chunks,
        )
        print(
            f"  Broadcasting: [{self._alert.severity}] {self._alert.headline}\n"
            f"  Alert ID : {self._alert.alertId}   chunks: {chunks}\n"
            f"  Press Ctrl+C to stop."
        )

        try:
            # Keep the event loop alive; bless callbacks fire in this loop.
            while True:
                await asyncio.sleep(1)
        except (asyncio.CancelledError, KeyboardInterrupt):
            pass
        finally:
            await self._shutdown()

    async def _shutdown(self) -> None:
        if self._server is not None:
            await self._server.stop()
            self._server = None
        log.info("BLE advertising stopped")
        print("\nBLE stopped.")

    # ── GATT callbacks (called from bless internals, scheduled on event loop) ──

    def _on_read(self, characteristic: BlessGATTCharacteristic, **_: Any) -> bytearray:
        if _uuid_key(str(characteristic.uuid)) == _ALERT_KEY:
            idx = self._chunk_idx
            if 0 <= idx < len(self._frames):
                frame = self._frames[idx]
                log.debug("READ chunk %d/%d  (%d bytes)", idx + 1, len(self._frames), len(frame))
                return bytearray(frame)
        return bytearray()

    def _on_write(self, characteristic: BlessGATTCharacteristic, value: Any, **_: Any) -> None:
        if _uuid_key(str(characteristic.uuid)) == _CONTROL_KEY:
            raw = bytes(value) if not isinstance(value, (bytes, bytearray)) else value
            if len(raw) >= 2:
                self._chunk_idx = ((raw[0] & 0xFF) << 8) | (raw[1] & 0xFF)
                log.debug("WRITE chunk request %d", self._chunk_idx)
