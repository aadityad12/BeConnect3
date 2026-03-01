import struct

from beconnect_pi.constants import java_string_hashcode, metadata_payload, severity_to_byte


def test_severity_mapping() -> None:
    assert severity_to_byte("Extreme") == 4
    assert severity_to_byte("Severe") == 3
    assert severity_to_byte("Moderate") == 2
    assert severity_to_byte("Minor") == 1
    assert severity_to_byte("Unknown") == 0


def test_metadata_payload_layout() -> None:
    alert_id = "abc12345"
    fetched_at = 1735689600
    payload = metadata_payload(alert_id, "Severe", fetched_at)

    assert len(payload) == 9
    assert payload[0] == 3

    h = java_string_hashcode(alert_id) & 0xFFFFFFFF
    expected_hash = bytes([h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF, (h >> 24) & 0xFF])
    assert payload[1:5] == expected_hash
    assert payload[5:9] == struct.pack(">i", fetched_at)
