"""Chunk framing utilities compatible with Android ChunkUtils.kt."""

from __future__ import annotations

import json

from .constants import DEFAULT_CHUNK_SIZE
from .model import AlertPacket


def chunk(data: bytes, chunk_size: int = DEFAULT_CHUNK_SIZE) -> list[bytes]:
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    return [data[i : i + chunk_size] for i in range(0, len(data), chunk_size)]


def reassemble(chunks: list[bytes]) -> bytes:
    return b"".join(chunks)


def encode_chunk(index: int, total: int, payload: bytes) -> bytes:
    if index < 0 or total < 0:
        raise ValueError("index and total must be >= 0")
    return bytes(
        [
            (index >> 8) & 0xFF,
            index & 0xFF,
            (total >> 8) & 0xFF,
            total & 0xFF,
        ]
    ) + payload


def decode_chunk_index(frame: bytes) -> int:
    if len(frame) < 4:
        raise ValueError("frame too short")
    return ((frame[0] & 0xFF) << 8) | (frame[1] & 0xFF)


def decode_total_chunks(frame: bytes) -> int:
    if len(frame) < 4:
        raise ValueError("frame too short")
    return ((frame[2] & 0xFF) << 8) | (frame[3] & 0xFF)


def decode_payload(frame: bytes) -> bytes:
    if len(frame) < 4:
        raise ValueError("frame too short")
    return frame[4:]


def serialize_alert(alert: AlertPacket) -> bytes:
    return json.dumps(alert.to_dict(), separators=(",", ":")).encode("utf-8")


def build_frames(alert: AlertPacket, chunk_size: int = DEFAULT_CHUNK_SIZE) -> list[bytes]:
    parts = chunk(serialize_alert(alert), chunk_size)
    total = len(parts)
    return [encode_chunk(i, total, payload) for i, payload in enumerate(parts)]
