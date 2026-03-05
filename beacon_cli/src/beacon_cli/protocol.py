"""GATT chunk framing — wire-compatible with BeConnect Flutter/Android/iOS."""

from __future__ import annotations

import json

from .constants import CHUNK_SIZE
from .model import AlertPacket


def build_frames(alert: AlertPacket, chunk_size: int = CHUNK_SIZE) -> list[bytes]:
    """Serialize alert → JSON → split into framed chunks.

    Frame layout: [chunkIndex:2 BE][totalChunks:2 BE][payload:≤chunk_size]
    """
    raw = json.dumps(alert.to_dict(), separators=(",", ":")).encode()
    payloads = [raw[i : i + chunk_size] for i in range(0, max(len(raw), 1), chunk_size)]
    total = len(payloads)
    frames = []
    for i, payload in enumerate(payloads):
        header = bytes([
            (i >> 8) & 0xFF, i & 0xFF,
            (total >> 8) & 0xFF, total & 0xFF,
        ])
        frames.append(header + payload)
    return frames
