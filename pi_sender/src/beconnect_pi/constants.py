"""Protocol constants shared across Pi sender components."""

from __future__ import annotations

import struct
from dataclasses import dataclass

SERVICE_UUID = "0000BCBC-0000-1000-8000-00805F9B34FB"
ALERT_CHAR_UUID = "0000BCB1-0000-1000-8000-00805F9B34FB"
CONTROL_CHAR_UUID = "0000BCB2-0000-1000-8000-00805F9B34FB"
MANUFACTURER_ID = 0x1234
DEFAULT_CHUNK_SIZE = 17
ALLOWED_SEVERITIES = ("Extreme", "Severe", "Moderate", "Minor", "Unknown")


@dataclass(frozen=True)
class ProtocolConstants:
    service_uuid: str = SERVICE_UUID
    alert_char_uuid: str = ALERT_CHAR_UUID
    control_char_uuid: str = CONTROL_CHAR_UUID
    manufacturer_id: int = MANUFACTURER_ID
    default_chunk_size: int = DEFAULT_CHUNK_SIZE


def severity_to_byte(severity: str) -> int:
    return {
        "Extreme": 4,
        "Severe": 3,
        "Moderate": 2,
        "Minor": 1,
        "Unknown": 0,
    }.get(severity, 0)


def java_string_hashcode(value: str) -> int:
    h = 0
    for ch in value:
        h = (31 * h + ord(ch)) & 0xFFFFFFFF
    if h & 0x80000000:
        return h - 0x100000000
    return h


def metadata_payload(alert_id: str, severity: str, fetched_at: int) -> bytes:
    """Mimic Android gateway metadata byte packing exactly.

    Layout (9 bytes):
      [severity:1][alertIdHash:4 little-endian byte order][fetchedAt:4 big-endian]
    """

    sev = severity_to_byte(severity) & 0xFF
    h = java_string_hashcode(alert_id)
    hash_u32 = h & 0xFFFFFFFF
    hash_le = bytes(
        [
            hash_u32 & 0xFF,
            (hash_u32 >> 8) & 0xFF,
            (hash_u32 >> 16) & 0xFF,
            (hash_u32 >> 24) & 0xFF,
        ]
    )
    fetched_be = struct.pack(">i", int(fetched_at))
    return bytes([sev]) + hash_le + fetched_be
