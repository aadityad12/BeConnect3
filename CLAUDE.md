# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

BeConnect (app name: "Echo") is an offline-first emergency alert distribution system. Every device is a **unified autonomous mesh node** — it simultaneously advertises alerts via BLE GATT and scans for alerts from nearby nodes. No mode selection at runtime.

**Architecture model:** Cloud pull (NWS GeoJSON) + offline BLE gossip mesh (bidirectional relaying).

**Platform:** Flutter (Dart) — targets Android (API 26+) and iOS (14+).

## App Structure

```
lib/
├── main.dart                       # Init background service, mount HomeScreen
├── ble_constants.dart              # UUIDs, MANUFACTURER_ID, DEFAULT_CHUNK_SIZE
├── ble/
│   ├── ble_advertiser.dart         # Thin delegate → forwards to GattServer
│   ├── gatt_server.dart            # MethodChannel bridge to native (start/stop/restart advertising + GATT)
│   ├── ble_scanner.dart            # Scan + filter by serviceUuid; scanForMesh() isolate-safe
│   ├── gatt_client.dart            # Connect + chunked read (async/await)
│   └── chunk_utils.dart            # Chunk/reassemble; encode/decode frame format
├── network/
│   ├── alert_fetcher.dart          # Fetch NWS GeoJSON (http package)
│   └── alert_parser.dart          # Parse GeoJSON → AlertPacket
├── data/
│   ├── alert_packet.dart           # Data model + JSON serialization (json_serializable)
│   │                               # Fields: alertId, severity, headline, expires, instructions,
│   │                               #         sourceUrl, verified, fetchedAt, pinned, hopCount
│   ├── alert_packet.g.dart         # Generated — do NOT edit manually
│   ├── alert_database.dart         # SQLite DB singleton (sqflite)
│   └── alert_dao.dart              # insert, hasAlert, fetchAll, pruneOldAlerts (keeps last 20),
│                                   # deleteAlert, setPinned
├── service/
│   └── gateway_background_service.dart  # Background mesh loop (every 5 min); IPC bridge
├── utils/
│   └── permissions.dart                 # requestBlePermissions() — called from HomeScreen._bootstrap()
├── ui/
│   ├── home_screen.dart            # Unified UI: permissions → service → scan → list alerts
│   ├── receiver/
│   │   └── alert_detail_screen.dart    # AlertDetailScreen({required AlertPacket alert})
│   ├── theme/
│   │   └── severity_colors.dart        # Color helpers keyed by severity string
│   └── widgets/
│       ├── glass_container.dart        # Frosted-glass Container
│       └── glass_scaffold.dart         # Scaffold with animated gradient background
└── demo/
    └── demo_alerts.dart            # Hardcoded fallback AlertPackets (verified: false)
```

## Build & Run

```bash
# Get dependencies
flutter pub get

# Generate JSON serialization code (after editing alert_packet.dart)
dart run build_runner build --delete-conflicting-outputs

# Run on connected device (debug)
flutter run

# Analyze (lint)
flutter analyze

# Run all tests
flutter test

# Run a single test file
flutter test test/chunk_utils_test.dart

# Build release APK (Android)
flutter build apk --release

# Build release IPA (iOS — requires macOS + Xcode)
flutter build ipa --release
```

> **Generated file:** `lib/data/alert_packet.g.dart` is produced by `build_runner`. Re-run after any change to `alert_packet.dart`.

- **Android** Min SDK: **26**. Target SDK: **34**.
- **iOS** Deployment target: **14.0**.

## Key Dependencies (`pubspec.yaml`)

```yaml
flutter_blue_plus: ^1.32.0          # BLE central + peripheral
http: ^1.2.0                        # NWS API requests
sqflite: ^2.3.0                     # SQLite persistence
json_annotation: ^4.9.0
flutter_background_service: ^5.0.5  # Background BLE mesh loop
permission_handler: ^11.3.0
crypto: ^3.0.3                      # SHA-1 for alertId generation
```

## Critical Architectural Constraint: Two Flutter Engines

`GattServer` uses `MethodChannel('com.beconnect.beconnect/ble')`, registered **only** in the main Flutter engine (MainActivity / AppDelegate). The `flutter_background_service` background isolate runs a **separate engine** — calling `GattServer` there throws `MissingPluginException`.

**Rule:** All `GattServer.start/stop/restart` calls must stay in `HomeScreen` (main isolate). The background isolate communicates via IPC events instead.

### IPC event flow

| Direction | Event | Payload |
|---|---|---|
| background → main | `serviceStarted` | (none) |
| background → main | `meshAlert` | `{alertJson: String}` |
| main → background | `notifyAlert` | `{alertJson: String}` |

`HomeScreen` subscribes via `GatewayBackgroundService.service.on(eventName).listen(...)`.

## Startup Sequence (`HomeScreen._bootstrap`)

1. `requestBlePermissions()` — all BLE + location + notification permissions
2. `GatewayBackgroundService.start()` — idempotent; launches background mesh isolate
3. Subscribe to IPC events (`serviceStarted`, `meshAlert`)
4. Check `isRunning()` for hot-restart case (service won't re-emit `serviceStarted`)
5. `_loadAlerts()` — populate list from SQLite
6. `_runForegroundScan()` — immediate 15-second foreground BLE scan

## BLE Architecture Details

### Constants (`ble_constants.dart`)
```dart
const serviceUuid      = '0000BCBC-0000-1000-8000-00805F9B34FB';
const alertCharUuid    = '0000BCB1-0000-1000-8000-00805F9B34FB'; // read: chunked alert data
const controlCharUuid  = '0000BCB2-0000-1000-8000-00805F9B34FB'; // write: requested chunk index
const manufacturerId   = 0x1234;
```

### BLE manufacturer data format
`[severity: 1 byte][alertIdHash: 4 bytes][fetchedAt: 4 bytes]`

`alertIdHash` = first 8 hex chars of SHA-1(headline+expires) — used for loop prevention via `dao.hasAlert()`.

### GATT chunk transfer protocol
1. Receiver connects → `requestMtu(512)` → `discoverServices`
2. For each chunk: write 2-byte big-endian index to `controlCharUuid`, read `alertCharUuid`
3. Frame format: `[chunkIndex: 2 bytes BE][totalChunks: 2 bytes BE][payload: ≤508 bytes]`
4. Reassemble bytes → JSON-deserialize → `AlertPacket`

Native chunk size is **508 bytes** (512 MTU − 4-byte header). `GATT_ERROR 133` on Android on first connect is common — `GattClient` retries once after 600ms.

### Gossip mesh loop (background)
Every 5 minutes (and once on startup): `BleScanner.scanForMesh()` → for each beacon, check `alertIdHash` against DB → download unknown alerts via `GattClient.downloadAlert()` → persist → emit `meshAlert` IPC event → HomeScreen calls `GattServer.restart()`. One new alert relayed per cycle to avoid flooding.

## Native Layer (Platform Channel)

- **Android:** `android/app/src/main/kotlin/com/beconnect/beconnect/MainActivity.kt` — `BluetoothLeAdvertiser` + `BluetoothGattServer`; chunks JSON at 508 bytes; tracks per-device requested chunk index in `pendingChunkIndex`.
- **iOS:** `ios/Runner/AppDelegate.swift` — `CBPeripheralManager`; same 508-byte chunks; starts advertising after `peripheralManagerDidUpdateState` fires `.poweredOn`.

Methods: `startAdvertising({alertJson, severityByte})` and `stopAdvertising`.

## Data Model (`AlertPacket`)

| Field | Type | Notes |
|---|---|---|
| `alertId` | `String` | First 8 chars of SHA-1(headline+expires) |
| `severity` | `String` | `"Extreme"│"Severe"│"Moderate"│"Minor"│"Unknown"` |
| `headline` | `String` | |
| `expires` | `int` | Unix epoch seconds |
| `instructions` | `String` | |
| `sourceUrl` | `String` | |
| `verified` | `bool` | `true` only if fetched from NWS |
| `fetchedAt` | `int` | Unix epoch seconds |
| `pinned` | `bool` | Pinned alerts sort first; cannot be deleted |
| `hopCount` | `int` | 0 = originated here; +1 per BLE relay hop |

## NWS API

```
GET https://api.weather.gov/alerts/active?status=actual&message_type=alert&limit=5
Accept: application/geo+json
User-Agent: BeConnect/1.0 (hackathon@beconnect.app)
```
No API key required. `demoAlerts` in `demo_alerts.dart` provides fallback packets with `verified = false`.

## Raspberry Pi Sender (`pi_sender/`)

Standalone Python component — wire-compatible with the Flutter mesh (same UUIDs, GATT protocol, advertisement format). Acts as an always-on seeder node.

```bash
cd pi_sender
python3 -m venv .venv && source .venv/bin/activate
pip install -e .

beconnect-pi alert new --headline "..." --severity Extreme --expires <epoch> \
    --instructions "..." --source-url "local://operator" --verified false
beconnect-pi publish <alert_id>
beconnect-pi broadcast start        # background daemon
beconnect-pi broadcast stop
beconnect-pi status

# Tests
python -m pytest tests/
```

State files: `~/.beconnect-pi/` (`alerts.json`, `current_alert.json`, `broadcaster.pid`). Re-running `publish` hot-swaps the alert without restarting the daemon.

## BLE Debugging Tips

- **No scan results (Android):** Verify `ACCESS_FINE_LOCATION` is granted and location services are enabled.
- **No scan results (iOS):** App must be in foreground or have `bluetooth-central` background mode.
- **Advertising fails silently (Android):** Check `isMultipleAdvertisementSupported()`; emulators do not support BLE advertising.
- **Advertising on iOS:** CoreBluetooth silently drops manufacturer-specific data; service UUID still broadcasts. iOS Simulator does not support BLE.
- **GATT 133 (Android):** Retry the full connect sequence once after 600ms — already handled in `GattClient`.
- **`flutter_blue_plus` state:** Always check `FlutterBluePlus.adapterState` before scanning/advertising.
- **"Timed out waiting for CONFIGURATION_BUILD_DIR":** Transient Xcode bug; fix: `pkill Xcode`, then re-run.

## iOS `Info.plist` Requirements

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>BeConnect uses Bluetooth to send and receive emergency alerts.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>BeConnect uses Bluetooth to broadcast emergency alerts to nearby devices.</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
</array>
```
