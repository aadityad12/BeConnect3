# beacon_cli — Cross-Platform BLE Relay Node

> Turn any macOS or Windows machine into a **Relay node** for the Echo emergency alert mesh.
> No Raspberry Pi required — just Python and Bluetooth.

`beacon_cli` is a standalone Python package that is **fully wire-compatible** with the Echo app. Same BLE service UUIDs, same GATT chunked transfer protocol, same advertisement format. A nearby phone running Echo will detect it, download the alert, and relay it further — no app changes needed.

---

## Requirements

| Requirement | Version |
|---|---|
| Python | 3.10+ |
| macOS | 12+ (Monterey) with Bluetooth hardware |
| Windows | 10 / 11 with Bluetooth adapter |
| `bless` library | ≥ 0.2.2 (installed automatically) |

> **Linux users:** Use [`pi_sender/`](../pi_sender/) instead — it uses BlueZ D-Bus and is optimized for Raspberry Pi.

---

## Installation

```bash
cd beacon_cli
python3 -m venv .venv

# macOS / Linux
source .venv/bin/activate

# Windows
.venv\Scripts\activate

pip install -e .
```

Once installed, the `beacon` command is available anywhere inside the virtual environment.

---

## Quick Start

```bash
# 1. Create an alert
beacon new \
  --headline "Tornado Warning — Seek shelter immediately" \
  --severity Extreme \
  --expires 1893456000 \
  --instructions "Go to the lowest floor. Stay away from windows." \
  --source-url "local://operator"

# 2. Set it as the active broadcast
beacon publish <alert_id>

# 3. Start advertising over BLE  (Ctrl+C to stop)
beacon broadcast
```

Nearby phones running Echo will detect the beacon, download the alert, and display it — even with Wi-Fi and cellular completely off.

---

## Command Reference

### `beacon new` — Create an alert

```
beacon new --headline TEXT
           --severity  (Extreme|Severe|Moderate|Minor|Unknown)
           --expires   EPOCH_OR_ISO8601
           --instructions TEXT
           --source-url URL
           [--verified (true|false)]   default: false
           [--fetched-at EPOCH]        default: now
```

Creates a new alert and saves it to the local state directory. Prints the generated `alert_id`.

**Example:**

```bash
beacon new \
  --headline "Flash Flood Warning" \
  --severity Severe \
  --expires 1893456000 \
  --instructions "Move to higher ground immediately. Do not walk through floodwaters." \
  --source-url "local://nws-mirror" \
  --verified false
```

**Severity levels** (controls the color and glow on the receiving Echo device):

| Value | Color on Echo |
|---|---|
| `Extreme` | Deep crimson + pulsing glow |
| `Severe` | Red-orange + pulsing glow |
| `Moderate` | Amber |
| `Minor` | Soft yellow |
| `Unknown` | Grey |

**`--expires`** accepts either a Unix epoch integer (`1893456000`) or an ISO 8601 string (`2030-01-01T00:00:00`).

---

### `beacon list` — List all saved alerts

```
beacon list
```

Shows all alerts in the state directory, with an arrow marking the currently published one.

**Example output:**

```
  a3f2c1d0  [Extreme]  Tornado Warning — Seek shelter immediately
           expires=1893456000  verified=False  ← current
  b8e91a2f  [Severe]   Flash Flood Warning
           expires=1893456000  verified=False
```

---

### `beacon show` — Inspect an alert as JSON

```
beacon show <alert_id>
```

Prints the full alert as pretty-printed JSON — useful for debugging the exact payload that will be sent over BLE.

**Example:**

```bash
beacon show a3f2c1d0
```

```json
{
  "alertId": "a3f2c1d0",
  "severity": "Extreme",
  "headline": "Tornado Warning — Seek shelter immediately",
  "expires": 1893456000,
  "instructions": "Go to the lowest floor. Stay away from windows.",
  "sourceUrl": "local://operator",
  "verified": false,
  "fetchedAt": 1709654321,
  "hopCount": 0
}
```

---

### `beacon delete` — Remove an alert

```
beacon delete <alert_id>
```

Permanently removes the alert from the state directory. If the deleted alert was the currently published one, the broadcast will stop serving any alert until a new one is published.

**Example:**

```bash
beacon delete a3f2c1d0
```

---

### `beacon publish` — Set the active broadcast

```
beacon publish <alert_id>
```

Sets the specified alert as the one that will be advertised over BLE. If `broadcast` is already running, you can run `publish` while it is active — the broadcast picks up the new alert within seconds.

**Example:**

```bash
beacon publish b8e91a2f
# Published: [Severe] Flash Flood Warning
```

---

### `beacon broadcast` — Start BLE advertising

```
beacon broadcast [-v | --verbose]
```

Starts the BLE GATT peripheral and begins advertising the currently published alert. Press **Ctrl+C** to stop.

| Flag | Description |
|---|---|
| `-v`, `--verbose` | Enable debug-level BLE log output (useful for troubleshooting) |

The broadcaster:
1. Reads the currently published alert from the state directory.
2. Chunks the JSON payload into 508-byte frames (512 MTU − 4 header bytes).
3. Starts a GATT server with the BeConnect service UUID (`0000BCBC-…`).
4. Advertises manufacturer data encoding the severity byte and `alertIdHash`.
5. Serves chunk requests from any connecting Echo device.

**Example:**

```bash
# Normal mode
beacon broadcast

# Debug mode — shows BLE stack events
beacon broadcast --verbose
```

> On macOS, you may see a system dialog asking to allow Bluetooth access the first time you run `broadcast`. Click **Allow**.

---

### `beacon status` — Show current state

```
beacon status
```

Prints the state directory path, how many alerts are saved, and which alert is currently published.

**Example output:**

```
State dir : /Users/yourname/.beacon-cli
Alerts    : 3
Published : [Extreme] Tornado Warning — Seek shelter immediately  (id=a3f2c1d0)
```

---

## Global Options

```
beacon [--state-dir DIR] <command>
```

| Option | Default | Description |
|---|---|---|
| `--state-dir DIR` | `~/.beacon-cli` | Override the directory where alerts and state files are stored |

This is useful for running multiple independent instances or for CI/testing:

```bash
beacon --state-dir /tmp/test-state new --headline "Test" ...
beacon --state-dir /tmp/test-state broadcast
```

---

## State Files

All state lives in `~/.beacon-cli/` (or the directory specified by `--state-dir`):

| File | Contents |
|---|---|
| `alerts.json` | All saved alerts as a JSON array |
| `current_alert.json` | The currently published alert (updated by `beacon publish`) |

---

## BLE Protocol Details

`beacon_cli` is wire-compatible with the Echo app and the `pi_sender` Raspberry Pi implementation.

| Constant | Value |
|---|---|
| Service UUID | `0000BCBC-0000-1000-8000-00805F9B34FB` |
| Alert characteristic (READ) | `0000BCB1-0000-1000-8000-00805F9B34FB` |
| Control characteristic (WRITE) | `0000BCB2-0000-1000-8000-00805F9B34FB` |
| Manufacturer ID | `0x1234` |
| BLE device name | `BeConnect` |
| Chunk size | 508 bytes (512 MTU − 4-byte frame header) |

**Frame header format:**
```
[chunkIndex: 2 bytes BE][totalChunks: 2 bytes BE][payload: ≤508 bytes]
```

**Manufacturer data format:**
```
[severity: 1 byte][alertIdHash: 4 bytes][fetchedAt: 4 bytes]
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No current alert` on broadcast | Run `beacon publish <id>` first |
| `ModuleNotFoundError: bless` | Activate the venv: `source .venv/bin/activate` |
| macOS Bluetooth permission dialog | Click Allow; if it doesn't appear, check System Settings → Privacy → Bluetooth |
| Phone doesn't detect the beacon | Ensure `beacon broadcast` is running and the phone has Bluetooth ON and the Echo app in the foreground |
| `broadcast` exits immediately | Run with `--verbose` to see the BLE error; ensure no other process is holding the Bluetooth adapter |
| Windows: adapter not found | Ensure a Bluetooth adapter is present and not disabled in Device Manager |

---

## Project Layout

```
beacon_cli/
├── pyproject.toml              # Package metadata; installs the 'beacon' CLI entry point
└── src/
    └── beacon_cli/
        ├── cli.py              # Argument parser + command handlers
        ├── ble_server.py       # bless GATT peripheral (asyncio)
        ├── model.py            # AlertPacket dataclass + builder
        ├── constants.py        # UUIDs, manufacturer ID, severity byte map
        ├── protocol.py         # Chunk / frame encoding
        └── storage.py          # JSON file persistence in state directory
```
