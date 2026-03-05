"""Protocol constants — wire-compatible with BeConnect Flutter app."""

SERVICE_UUID      = "0000BCBC-0000-1000-8000-00805F9B34FB"
ALERT_CHAR_UUID   = "0000BCB1-0000-1000-8000-00805F9B34FB"
CONTROL_CHAR_UUID = "0000BCB2-0000-1000-8000-00805F9B34FB"
MANUFACTURER_ID   = 0x1234
CHUNK_SIZE        = 508   # 512 MTU − 4-byte frame header

ALLOWED_SEVERITIES = ("Extreme", "Severe", "Moderate", "Minor", "Unknown")
