# RE3 — Echo

> **Offline-first emergency alert distribution over Bluetooth Low Energy.**
> No internet. No cell service. No infrastructure required.

RE3 (displayed in-app as **Echo**) is a mesh-networking alert system that lets a single device with internet access fetch official emergency alerts and silently propagate them to every nearby phone — even when cellular and Wi-Fi are completely down. A Raspberry Pi or any phone acts as the originating beacon; every phone that receives an alert automatically becomes a relay node, spreading the alert further through the crowd.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Architecture](#architecture)
3. [BLE Protocol](#ble-protocol)
4. [Data Model](#data-model)
5. [Hop Counting](#hop-counting)
6. [App Features](#app-features)
7. [Project Structure](#project-structure)
8. [Dependencies](#dependencies)
9. [Build & Run](#build--run)
10. [Raspberry Pi Sender](#raspberry-pi-sender)
11. [Platform Notes](#platform-notes)
12. [Debugging BLE](#debugging-ble)
13. [Demo Walkthrough](#demo-walkthrough)

---

## How It Works

```
┌─────────────────┐    BLE GATT     ┌──────────────┐    BLE GATT     ┌──────────────┐
│  Raspberry Pi   │ ──────────────► │   Phone A    │ ──────────────► │   Phone B    │
│  (or Phone w/   │  alert JSON     │  hop 1       │  re-broadcasts  │  hop 2       │
│   internet)     │  in chunks      │  (no Wi-Fi)  │  alert          │  (no Wi-Fi)  │
│                 │                 │              │                 │              │
│ NWS API fetch   │                 │ Stores alert │                 │ Stores alert │
│ + GATT server   │                 │ Re-advertises│                 │ Re-advertises│
└─────────────────┘                 └──────────────┘                 └──────────────┘
        ▲
        │ HTTPS
┌───────────────┐
│  NWS GeoJSON  │
│  alerts/active│
└───────────────┘
```

1. A **source device** (Pi or phone with internet) fetches live alerts from the National Weather Service API.
2. It advertises the alert over BLE using a custom GATT server, chunking the JSON payload across multiple characteristic reads.
3. Any nearby phone running RE3 **scans** for the service UUID, connects, downloads and reassembles the chunks, and saves the alert to local SQLite.
4. That phone then **re-advertises** the same alert — becoming a relay node in the gossip mesh.
5. Each relay increments the **hop counter**, so recipients can see exactly how many devices the alert traveled through to reach them.
6. A deduplication check (`alertIdHash` in BLE advertisement + SQLite lookup) prevents infinite relay loops.

---

## Architecture

RE3 uses a **unified mesh node** model. Every device simultaneously acts as both broadcaster and scanner — there are no fixed gateway or receiver roles.

### Two Execution Contexts

| Context | Runs |
|---|---|
| **Main Flutter isolate** | UI, `GattServer` (MethodChannel → native BLE), foreground BLE scan, NWS fetch |
| **Background isolate** (`flutter_background_service`) | Autonomous 5-minute mesh loop: scan → deduplicate → download → persist → notify main |

> **Critical constraint:** `GattServer` uses a `MethodChannel` registered only in the main Flutter engine (`MainActivity` / `AppDelegate`). Calling it from the background isolate throws `MissingPluginException`. All GATT server operations must stay in the main isolate.

### IPC Between Isolates

```
Background ──► 'serviceStarted' ──► Main  (activates MESH ACTIVE badge + pulse)
Background ──► 'meshAlert'      ──► Main  (calls GattServer.restart, reloads DB)
Main       ──► 'notifyAlert'    ──► Background  (keeps background DB in sync after NWS fetch)
```

### Background Mesh Loop (runs immediately, then every 5 minutes)

```
scanForMesh(15 seconds)
  └─ for each beacon found:
       └─ alertIdHash already in DB? ──yes──► skip  (loop prevention)
                                     ──no───► GattClient.downloadAlert()
                                                └─ hopCount + 1
                                                └─ persist to SQLite
                                                └─ emit 'meshAlert' IPC → main isolate
                                                └─ break  (one new alert per cycle)
```

---

## BLE Protocol

### Service & Characteristic UUIDs

| Role | UUID |
|---|---|
| Service | `0000BCBC-0000-1000-8000-00805F9B34FB` |
| Alert characteristic (READ) | `0000BCB1-0000-1000-8000-00805F9B34FB` |
| Control characteristic (WRITE) | `0000BCB2-0000-1000-8000-00805F9B34FB` |
| Manufacturer ID | `0x1234` |

### Advertisement Payload

Packed into the 31-byte BLE advertisement alongside the service UUID:

```
[severity   : 1 byte ]   0=Extreme, 1=Severe, 2=Moderate, 3=Minor, 4=Unknown
[alertIdHash: 4 bytes]   first 4 bytes of SHA-1(headline + expires)
[fetchedAt  : 4 bytes]   Unix epoch, big-endian
```

Receivers filter on the service UUID and parse the manufacturer data to get severity and `alertIdHash` — enough to decide whether to connect — without touching GATT.

### GATT Chunk Transfer

```
Receiver                                  GATT Server (gateway)
   │                                             │
   │── connect() + requestMtu(512) ─────────────►│
   │◄─── mtuChanged(512) ────────────────────────│
   │── discoverServices() ──────────────────────►│
   │                                             │
   │  repeat for i = 0 .. totalChunks - 1:       │
   │── write(controlChar, [i >> 8, i & 0xFF]) ──►│  ← "give me chunk i"
   │── read(alertChar) ─────────────────────────►│
   │◄─── [i:2 BE][total:2 BE][payload:≤508 B] ───│
   │                                             │
   │── disconnect() ────────────────────────────►│
   │                                             │
   reassemble → gzip decompress → JSON → AlertPacket
```

**Frame format:**

```
┌──────────────┬────────────────┬──────────────────────────┐
│ chunkIndex   │  totalChunks   │  payload                 │
│  2 bytes BE  │  2 bytes BE    │  up to 508 bytes         │
└──────────────┴────────────────┴──────────────────────────┘
```

- Native (gateway) chunk size: **508 bytes** (512 MTU − 4-byte header)
- Pre-negotiation default: **17 bytes** (used by receiver before `onMtuChanged` fires)
- Gateway gzip-compresses the JSON before chunking; receiver auto-detects gzip via magic bytes `0x1f 0x8b`
- GATT error 133 on Android is normal on first connect — `GattClient` automatically retries once after 600ms

---

## Data Model

```dart
@JsonSerializable()
class AlertPacket {
  final String alertId;       // First 8 hex chars of SHA-1(headline + expires)
  final String severity;      // "Extreme" | "Severe" | "Moderate" | "Minor" | "Unknown"
  final String headline;
  final int    expires;       // Unix epoch seconds
  final String instructions;
  final String sourceUrl;
  final bool   verified;      // true = fetched from NWS; false = demo or relayed unverified
  final int    fetchedAt;     // Unix epoch seconds
  final bool   pinned;        // User-pinned; survives the 20-alert prune
  final int    hopCount;      // 0 = origin; incremented +1 per BLE relay hop
}
```

### SQLite Schema — Version 3

```sql
CREATE TABLE alerts (
  alertId       TEXT    PRIMARY KEY,
  severity      TEXT    NOT NULL,
  headline      TEXT    NOT NULL,
  expires       INTEGER NOT NULL,
  instructions  TEXT    NOT NULL,
  sourceUrl     TEXT    NOT NULL,
  verified      INTEGER NOT NULL,
  fetchedAt     INTEGER NOT NULL,
  pinned        INTEGER NOT NULL DEFAULT 0,
  hopCount      INTEGER NOT NULL DEFAULT 0
);
```

- Prunes to the **20 most recent** alerts automatically after every insert.
- Pinned alerts are excluded from pruning.
- Ordered by: pinned DESC, fetchedAt DESC.
- Migration history: v1 → v2 added `pinned`; v2 → v3 added `hopCount`.

---

## Hop Counting

| Scenario | Stored `hopCount` |
|---|---|
| NWS fetch / demo load directly on this device | **0** |
| Pi → Phone A (direct receive) | **1** |
| Pi → Phone A → Phone B | **2** |
| Pi → A → B → C | **3** |

The Pi's JSON payload does not include `hopCount`; the Dart model's `@JsonKey(defaultValue: 0)` handles the missing field, so any phone receiving directly from the Pi stores `hopCount: 1` (0 + 1).

The increment happens inside `GattClient` after download and JSON deserialization:

```dart
return AlertPacket(
  ...parsed fields...,
  hopCount: parsed.hopCount + 1,
);
```

The alert detail screen renders this as a visual node chain:

```
  🟢 ───────── ⚪ ───────── 📱
origin        relay       you
(Pi/NWS)   (1 device)   (hop 2)
```

Nodes: green tower = origin, white bluetooth circles = relay phones, blue phone = this device.

---

## App Features

### Home Screen (titled "Echo")

| Feature | Description |
|---|---|
| Auto-scan on launch | 15-second foreground scan runs immediately after permissions are granted |
| Manual re-scan FAB | Bluetooth search FAB in the bottom corner; scales in with elastic-out animation after 350ms |
| NWS fetch | Cloud icon in AppBar fetches up to 5 active alerts from the National Weather Service |
| Demo mode | Flask icon loads hardcoded sample alerts (Extreme + Severe) for offline testing |
| Pull to refresh | Refreshes the local database display |
| MESH ACTIVE badge | Appears in the AppBar with a breathing green glow when the background service is alive |
| Staggered alert cards | Cards slide up and fade in with 50ms stagger per card |
| Severity glow | Extreme and Severe cards have a pulsing colored outer glow |
| Press scale | Cards scale to 0.97× on press for tactile feedback |
| Long-press context menu | Pin/unpin or delete an alert (newest alert is protected from deletion) |
| "You're all caught up" | Subtle footer message at the bottom of the list |

### Alert Detail Screen

| Feature | Description |
|---|---|
| Severity banner | Colored glass panel with icon and severity label; Extreme/Severe have outer glow |
| Read Aloud | Full-width button + AppBar icon; speaks severity + headline + instructions via native TTS |
| TTS engine | iOS: `AVSpeechSynthesizer`; Android: `TextToSpeech`; speech rate 0.45× for clarity |
| Auto-stop | TTS stops automatically when navigating back |
| Relay path | Visual node chain showing origin → relay hops → this device |
| Hop count text | Plain-English description ("Received directly from source beacon", "Relayed through N devices…") |
| Expiry time | Formatted local date/time |
| Metadata | Source, Alert ID, received via |

### Design System

- **Dark glassmorphism** — dark navy base (`#0D0F1A`), two animated warm gradient blobs (17s and 19s drift cycles) behind all content, `BackdropFilter` blur on fixed surfaces only (AppBar, modals, banners).
- **Severity color scale** — 5 levels from soft yellow (Minor) through amber → orange → red → deep crimson (Extreme). Every card, badge, border, and glow is dynamically colored by severity.
- **Page transitions** — Fade + 4% slide-up applied to both iOS and Android, replacing the default platform slide-from-right.
- **No blur inside list items** — `BackdropFilter` is deliberately excluded from `ListView`/`SliverList` children to prevent jank.

---

## Project Structure

```
lib/
├── main.dart                          # App entry, ThemeData, page transitions
├── ble_constants.dart                 # Service UUIDs, manufacturer ID, severity byte mapping
├── ble/
│   ├── ble_advertiser.dart            # Thin delegate → GattServer
│   ├── ble_scanner.dart               # BLE scan + filter; BeaconInfo model
│   ├── gatt_client.dart               # Connect, chunked download, hopCount increment
│   ├── gatt_server.dart               # MethodChannel bridge: start / stop / restart
│   └── chunk_utils.dart               # Frame encode / decode / reassemble
├── network/
│   ├── alert_fetcher.dart             # NWS GeoJSON HTTP client (10s timeout)
│   └── alert_parser.dart              # GeoJSON features → AlertPacket list
├── data/
│   ├── alert_packet.dart              # Data model + json_serializable annotations
│   ├── alert_packet.g.dart            # ⚠️ Generated — do not edit
│   ├── alert_database.dart            # SQLite singleton, schema v3, auto-migration
│   └── alert_dao.dart                 # insert, hasAlert, fetchAll, setPinned, delete, prune
├── service/
│   └── gateway_background_service.dart  # Background isolate, mesh loop, IPC events
├── utils/
│   └── permissions.dart               # requestBlePermissions() — iOS + Android
├── ui/
│   ├── home_screen.dart               # Main screen: cards, FAB, scan, mesh badge
│   ├── theme/
│   │   └── severity_colors.dart       # main(), tint(), border(), hasGlow() helpers
│   ├── widgets/
│   │   ├── glass_scaffold.dart        # Dark bg + animated drifting blobs
│   │   └── glass_container.dart       # Reusable blurred glass panel widget
│   └── receiver/
│       └── alert_detail_screen.dart   # Detail: TTS, hop chain, metadata
└── demo/
    └── demo_alerts.dart               # Hardcoded fallback AlertPackets

android/app/src/main/kotlin/.../
└── MainActivity.kt                    # BluetoothLeAdvertiser + BluetoothGattServer
                                       # 508-byte chunks, per-device chunk index tracking

ios/Runner/
└── AppDelegate.swift                  # CBPeripheralManager, same 508-byte chunks
                                       # Starts advertising after peripheralManagerDidUpdateState

assets/
└── icon/
    └── app_icon.png                   # 1024×1024 source — flutter_launcher_icons generates all sizes

pi_sender/
├── src/beconnect_pi/
│   ├── model.py                       # AlertPacket dataclass + helpers
│   ├── constants.py                   # Protocol UUIDs + manufacturer data packing
│   ├── protocol.py                    # Chunk/frame encoding, JSON serialization
│   ├── storage.py                     # File persistence in ~/.beconnect-pi/
│   ├── ble_server.py                  # BlueZ D-Bus GATT server
│   ├── broadcaster.py                 # Background daemon + hot-swap polling (2s)
│   └── cli.py                         # beconnect-pi CLI (alert, publish, broadcast, status)
└── tests/
    ├── test_model.py
    ├── test_metadata.py
    └── test_protocol.py
```

---

## Dependencies

### Flutter — Runtime

| Package | Version | Purpose |
|---|---|---|
| `flutter_blue_plus` | ^1.32.0 | BLE central (scan) + peripheral (advertise) on Android & iOS |
| `http` | ^1.2.0 | NWS GeoJSON API requests |
| `sqflite` | ^2.3.0 | Local SQLite persistence |
| `path_provider` | ^2.1.0 | Database file path resolution |
| `json_annotation` | ^4.9.0 | `@JsonSerializable` annotations |
| `flutter_background_service` | ^5.0.5 | Background isolate + foreground notification (Android) |
| `permission_handler` | ^11.3.0 | Runtime BLE + location + notification permissions |
| `crypto` | ^3.0.3 | SHA-1 for `alertId` generation |
| `flutter_tts` | ^4.0.2 | Native iOS `AVSpeechSynthesizer` / Android `TextToSpeech` |

### Flutter — Dev

| Package | Purpose |
|---|---|
| `build_runner` | Code generation runner |
| `json_serializable` | Generates `alert_packet.g.dart` from annotations |
| `flutter_launcher_icons` | Generates all required icon sizes from a single 1024×1024 source |

### Pi Sender — Python

| Package | Purpose |
|---|---|
| `dbus-next` | BlueZ D-Bus interface for GATT server on Linux |
| `streamlit` *(optional)* | Web-based operator UI |
| `pytest` *(dev)* | Unit test runner |

---

## Build & Run

### Prerequisites

- Flutter SDK ≥ 3.6.2 on your `PATH`
- Dart SDK ≥ 3.6.2 (bundled with Flutter)
- For iOS builds: macOS + Xcode 15+
- For Android builds: Android Studio + SDK Platform 34

### One-Time Setup

```bash
# Install Dart/Flutter dependencies
flutter pub get

# Regenerate JSON serialization code
# (Only needed after editing alert_packet.dart)
dart run build_runner build --delete-conflicting-outputs

# Regenerate app icons
# (Only needed after replacing assets/icon/app_icon.png)
dart run flutter_launcher_icons
```

### Daily Commands

```bash
# Run on connected device (debug)
flutter run

# Lint — must report 0 issues
flutter analyze

# Unit tests
flutter test

# Watch mode for JSON codegen during development
dart run build_runner watch --delete-conflicting-outputs
```

### Release Builds

```bash
# Android APK
flutter build apk --release

# Android App Bundle (Play Store)
flutter build appbundle --release

# iOS IPA (requires macOS + Xcode)
flutter build ipa --release
```

### Platform Targets

| Platform | Minimum | Target |
|---|---|---|
| Android | API 26 (Android 8.0) | API 34 (Android 14) |
| iOS | 14.0 | latest |

---

## Raspberry Pi Sender

`pi_sender/` is a self-contained Python package that is fully wire-compatible with the Flutter app. Same BLE UUIDs, same GATT chunked protocol, same advertisement format — a Flutter phone can receive from a Pi and vice versa without any code changes.

### Pi Setup

```bash
# Requirements: Python 3.10+, BlueZ, D-Bus
sudo apt-get update
sudo apt-get install -y bluetooth bluez python3-dbus python3-venv

cd pi_sender
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
```

### CLI Reference

```bash
# Create an alert
beconnect-pi alert new \
  --headline "Severe Thunderstorm Warning" \
  --severity Severe \
  --expires 1893456000 \
  --instructions "Move indoors immediately. Avoid windows." \
  --source-url "local://operator" \
  --verified false

# List all stored alerts
beconnect-pi alert list

# Edit a field on an existing alert
beconnect-pi alert edit <alert_id> --severity Extreme

# Publish an alert (sets it as the active broadcast)
beconnect-pi publish <alert_id>

# Start broadcasting in the background (daemon)
beconnect-pi broadcast start

# Start in foreground for debugging
beconnect-pi broadcast start --foreground

# Stop the background broadcaster
beconnect-pi broadcast stop

# Check current status
beconnect-pi status
```

### State Files

All state lives in `~/.beconnect-pi/`:

| File | Contents |
|---|---|
| `alerts.json` | All saved alerts |
| `current_alert.json` | The currently published alert |
| `broadcaster.pid` | PID of the background daemon |
| `broadcaster.log` | Daemon log output |

The broadcaster polls `current_alert.json` every 2 seconds, so running `beconnect-pi publish` while the daemon is running **hot-swaps** the alert without a restart.

### Pi Tests

```bash
cd pi_sender
python -m pytest tests/ -v
```

### Optional Streamlit Operator UI

```bash
pip install -e ".[ui]"
streamlit run streamlit_app.py
# Opens a web UI at http://localhost:8501
```

---

## Platform Notes

### Android

- BLE advertising requires a **physical device** — Android emulators do not support `BluetoothLeAdvertiser`.
- The background service runs as a **foreground service** with a persistent notification. This is mandatory on Android 14+ (`foregroundServiceType: connectedDevice`).
- `ACCESS_FINE_LOCATION` is required for BLE scanning even when `usesPermissionFlags="neverForLocation"` is set — some devices enforce it at the system level.
- Impeller is disabled in the manifest (`EnableImpeller = false`) for compatibility with `flutter_background_service` rendering.

### iOS

- BLE scanning requires the app to be in the **foreground** unless `bluetooth-central` background mode is active (it is, per `Info.plist`).
- `CBPeripheralManager` silently drops custom manufacturer data when advertising. The service UUID is still broadcast and is sufficient for receiver-side filtering.
- The iOS Simulator does **not** support Bluetooth — always test on a physical iPhone.
- iOS may suspend background BLE advertising after ~3 minutes unless the device is actively charging and the app holds a background task. The `bluetooth-peripheral` background mode extends this but does not guarantee indefinite operation.

### Text-to-Speech

| Platform | Engine | Notes |
|---|---|---|
| iOS | `AVSpeechSynthesizer` | Always available, no permissions or `Info.plist` keys required |
| Android | `android.speech.tts.TextToSpeech` | Present on all standard Android installs; no permissions required |

Speech rate is intentionally set to **0.45×** (slightly below default) for clear, deliberate reading — optimized for comprehension during an emergency.

---

## Debugging BLE

| Symptom | Likely cause | Fix |
|---|---|---|
| Scan returns no results (Android) | `ACCESS_FINE_LOCATION` denied or location services off | Grant permission in Settings; enable Location |
| Scan returns no results (iOS) | App backgrounded or BT permission not granted | Bring app to foreground; check `NSBluetoothAlwaysUsageDescription` in `Info.plist` |
| Advertising fails silently (Android) | Device doesn't support multiple advertisements | Call `BluetoothAdapter.isMultipleAdvertisementSupported()`; use physical device |
| GATT error 133 on first connect | Common Android race condition | Already handled — `GattClient` retries once after 600ms |
| Chunks reassemble to garbled JSON | Chunk size mismatch between sender and receiver | Confirm native gateway uses 508-byte payload (512 MTU − 4 header bytes) |
| Background service not running | Permissions not granted or battery optimization enabled | Grant all permissions; disable battery optimization for the app in Android Settings |
| `MissingPluginException` in background | `GattServer.start()` called from background isolate | `GattServer` must only be called from the main isolate; use IPC events instead |

---

## Demo Walkthrough

End-to-end demo: from zero to alert displayed on a second phone in under 60 seconds.

### Requirements

- One device as the source (Pi **or** a phone with Wi-Fi)
- One or more receiver phones with Bluetooth ON and Wi-Fi OFF

---

### Option A — Raspberry Pi as Source

```bash
# On the Pi:
beconnect-pi alert new \
  --headline "Demo Tornado Warning — seek shelter now" \
  --severity Extreme \
  --expires $(date -d "+2 hours" +%s 2>/dev/null || date -v+2H +%s) \
  --instructions "Go to the lowest floor of a sturdy building. Avoid windows." \
  --source-url "local://demo" \
  --verified false

beconnect-pi publish <alert_id_from_above>
beconnect-pi broadcast start --foreground
```

### Option B — Phone as Source

1. Open RE3 on a phone with Wi-Fi ON.
2. Tap the **cloud icon** (NWS fetch) or the **flask icon** (demo alerts).
3. The app begins advertising automatically.

---

### Receiving

1. Open RE3 on a second phone with **Wi-Fi OFF** and **Bluetooth ON**.
2. The app auto-scans within the first 15 seconds of launch.
3. The alert card appears — tap it to see the detail screen.
4. Tap **Read Aloud** to hear the alert read by the native TTS engine.

---

### Observing the Mesh Relay

1. Let Phone A (hop 1) remain open.
2. Bring a third phone (Phone C) within range of Phone A, but out of range of the Pi.
3. Phone C receives the alert with `hopCount: 2`.
4. The relay path in the detail screen shows: `🟢 ── ⚪ ── 📱` (origin → Phone A → Phone C).

---

## License

Internal / hackathon project. Not for public distribution.
