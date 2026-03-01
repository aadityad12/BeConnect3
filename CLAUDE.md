# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

BeConnect is an offline-first emergency alert distribution system. A "gateway" device with internet fetches official alerts and broadcasts them locally via BLE to nearby phones — so people receive critical guidance even when cellular/Wi-Fi is down.

**Architecture model:** Cloud pull + offline push (one-way trusted alert dissemination).

**Platform:** Flutter (Dart) — targets both Android (API 26+) and iOS (14+).

## App Structure

Single Flutter app with two operating modes selectable at runtime:

- **Gateway mode** — fetches alerts from NWS GeoJSON API → BLE advertise metadata → GATT server serves full JSON packet on demand
- **Receiver mode** — BLE scan → filter by service UUID → GATT client connects → downloads + reassembles chunks → displays alert → persists locally

```
lib/
├── ble_constants.dart              # UUIDs, MANUFACTURER_ID, DEFAULT_CHUNK_SIZE
├── ble/
│   ├── ble_advertiser.dart         # Gateway: BLE advertise metadata
│   ├── gatt_server.dart            # Gateway: serve alert packet over GATT
│   ├── ble_scanner.dart            # Receiver: scan + filter; defines BeaconInfo
│   ├── gatt_client.dart            # Receiver: connect + chunked read (async/await)
│   └── chunk_utils.dart            # Chunk/reassemble; encode/decode frame format
├── network/
│   ├── alert_fetcher.dart          # Fetch NWS GeoJSON (http package)
│   └── alert_parser.dart          # Parse GeoJSON → AlertPacket
├── data/
│   ├── alert_packet.dart           # Data model + JSON serialization (json_serializable)
│   ├── alert_database.dart         # SQLite DB singleton (sqflite)
│   └── alert_dao.dart              # insert, pruneOldAlerts (keeps last 20)
├── service/
│   └── gateway_background_service.dart  # Keeps BLE advertising alive in background (flutter_background_service)
├── utils/
│   └── permissions.dart                 # requestBlePermissions() — called from ModeSelectScreen
├── ui/
│   ├── mode_select_screen.dart     # Entry point; handles all runtime permission requests
│   ├── gateway/
│   │   └── gateway_screen.dart     # Fetch/demo, preview, start/stop broadcasting
│   └── receiver/
│       ├── receiver_screen.dart    # Scan, list beacons, connect on tap
│       ├── beacon_list_item.dart   # List tile widget for BeaconInfo
│       └── alert_detail_screen.dart
└── demo/
    └── demo_alerts.dart            # Hardcoded fallback AlertPackets
```

## Key Dependencies (`pubspec.yaml`)

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_blue_plus: ^1.32.0      # BLE central + peripheral (Android & iOS)
  http: ^1.2.0                    # NWS API requests
  sqflite: ^2.3.0                 # Local SQLite persistence
  path_provider: ^2.1.0           # DB file path
  json_annotation: ^4.9.0         # JSON serialization
  flutter_background_service: ^5.0.5  # Background BLE advertising
  permission_handler: ^11.3.0     # Runtime permissions (Android & iOS)
  crypto: ^3.0.3                  # SHA-1 for alertId generation

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ^2.4.0
  json_serializable: ^6.8.0
```

## Build & Run

```bash
# Get dependencies
flutter pub get

# Generate JSON serialization code (one-shot)
dart run build_runner build --delete-conflicting-outputs

# Watch and regenerate on save (use during active development)
dart run build_runner watch --delete-conflicting-outputs

# Run on connected device (debug)
flutter run

# Build release APK (Android)
flutter build apk --release

# Build release IPA (iOS — requires macOS + Xcode)
flutter build ipa --release

# Run all tests
flutter test

# Run a single test file
flutter test test/chunk_utils_test.dart

# Analyze (lint)
flutter analyze
```

Open in Android Studio or VS Code with the Flutter extension. Ensure the Flutter SDK is on your `PATH`.

> **Generated files:** `lib/data/alert_packet.g.dart` is produced by `build_runner` from `alert_packet.dart`. Do not edit `.g.dart` files manually — re-run `build_runner build` instead.

- **Android** Min SDK: **26**. Target SDK: **34**.
- **iOS** Deployment target: **14.0**.

## BLE Architecture Details

### Constants (`ble_constants.dart`)
```dart
const serviceUuid      = '0000BCBC-0000-1000-8000-00805F9B34FB';
const alertCharUuid    = '0000BCB1-0000-1000-8000-00805F9B34FB'; // read: chunked alert data
const controlCharUuid  = '0000BCB2-0000-1000-8000-00805F9B34FB'; // write: requested chunk index
const manufacturerId   = 0x1234;
const defaultChunkSize = 17; // conservative pre-MTU-negotiation size
```

### Advertising payload (31-byte limit)
Uses `flutter_blue_plus` `AdvertiseData` with `serviceUuid` + manufacturer-specific data:
```
[severity 1-byte] + rest of metadata bytes
```
`BleScanner` filters on `serviceUuid` and parses manufacturer data for the severity byte.

> **iOS note:** CoreBluetooth does not allow advertising raw manufacturer-specific data or custom service UUIDs in the foreground the same way Android does. On iOS, the gateway must use `CBPeripheralManager` via the plugin's peripheral API; the advertised packet will include the service UUID but manufacturer data may be stripped when the app is backgrounded. Receiver-side scanning on iOS requires the app to be in the foreground or use a background mode entitlement.

### GATT chunk transfer protocol
1. Receiver connects → `requestMtu(512)` → `discoverServices`
2. For each chunk: receiver writes 2-byte big-endian index to `controlCharUuid`, then reads `alertCharUuid`
3. Frame format: `[chunkIndex: 2 bytes BE][totalChunks: 2 bytes BE][payload: N bytes]`
4. After all chunks received, receiver reassembles bytes → JSON-deserializes → `AlertPacket`

`GattClient` uses `async`/`await` with `StreamController`/`Completer` for callback-to-future bridging. `GATT_ERROR 133` on Android on first connect is common — retry once after 600ms.

### Background advertising
`GatewayBackgroundService` wraps BLE advertise + GATT server using `flutter_background_service` with a persistent foreground notification on Android (`foregroundServiceType: connectedDevice`) and a background task on iOS (limited — iOS may suspend after ~3 min unless the `bluetooth-peripheral` background mode is enabled in `Info.plist`).

Start/stop via:
```dart
GatewayBackgroundService.start(alert);
GatewayBackgroundService.stop();
```

### Permissions

All runtime permissions are requested via `requestBlePermissions()` in `lib/utils/permissions.dart`, called from `ModeSelectScreen` before navigating to either mode:

**Android**
- SDK 31+: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`
- SDK 33+: `POST_NOTIFICATIONS`
- Always: `ACCESS_FINE_LOCATION`

**iOS** — add to `Info.plist`:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>BeConnect uses Bluetooth to send and receive emergency alerts.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>BeConnect uses Bluetooth to broadcast emergency alerts to nearby devices.</string>
<!-- For background BLE advertising: -->
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
</array>
```

`AndroidManifest.xml` permissions are handled automatically by `flutter_blue_plus` and `permission_handler` via manifest merging; verify they are present in `android/app/src/main/AndroidManifest.xml`.

## Data Model

`AlertPacket` is the data model used for both SQLite persistence and JSON serialization for BLE transfer. Generated with `json_serializable`.

```dart
@JsonSerializable()
class AlertPacket {
  final String alertId;       // first 8 chars of SHA-1(headline+expires)
  final String severity;      // "Extreme" | "Severe" | "Moderate" | "Minor" | "Unknown"
  final String headline;
  final int expires;           // Unix epoch seconds
  final String instructions;
  final String sourceUrl;
  final bool verified;         // true only if fetched from NWS
  final int fetchedAt;         // Unix epoch seconds

  // ...factory AlertPacket.fromJson / toJson generated by build_runner
}
```

## NWS API

```
GET https://api.weather.gov/alerts/active?status=actual&message_type=alert&limit=5
Accept: application/geo+json
User-Agent: BeConnect/1.0 (hackathon@beconnect.app)
```
Response: GeoJSON `features[]`; each feature's `properties` has `severity`, `headline`, `instruction`, `expires` (ISO-8601), `@id`. No API key required.

Demo fallback: `demo_alerts.dart` provides hardcoded packets with `verified = false`.

## MVP Scope Boundaries

**In scope:** Gateway fetch → advertise → GATT serve; Receiver scan → download → display → SQLite (last 20 alerts); Demo mode; single-hop BLE; Android + iOS.

**Explicitly out of scope:**
- Multi-hop BLE mesh routing
- Cryptographic PKI / signature verification beyond `verified` boolean
- User-generated alert messages
- Real-time continuous sync

**Nice-to-haves (only if core is done):**
- `flutter_tts` read-aloud (offline, uses platform TTS)
- Two-language toggle with hardcoded translations

## BLE Debugging Tips

- **Scanning returns no results (Android):** Verify `ACCESS_FINE_LOCATION` is granted and location services are enabled (required even with `neverForLocation`).
- **Scanning returns no results (iOS):** BLE scanning requires the app to be in the foreground unless the `bluetooth-central` background mode is enabled. Verify `NSBluetoothAlwaysUsageDescription` is in `Info.plist`.
- **Advertising fails silently (Android):** Check `BluetoothAdapter.isMultipleAdvertisementSupported()` via `flutter_blue_plus`. Emulators do not support BLE advertising — use physical devices.
- **Advertising on iOS:** CoreBluetooth silently drops manufacturer-specific data when advertising; the service UUID will still be broadcast. Test on a physical iPhone — the iOS Simulator does not support BLE.
- **MTU negotiation:** `GattClient` calls `requestMtu(512)` on connect; await `onMtuChanged` before reading. Default MTU is 23 (20 usable bytes).
- **GATT 133 error (Android):** Retry the full connect sequence once after 600ms.
- **`flutter_blue_plus` state:** Always check `FlutterBluePlus.adapterState` before scanning/advertising and prompt the user to enable Bluetooth if needed.

## Raspberry Pi Sender (`pi_sender/`)

A standalone Python component that acts as a gateway running on a Raspberry Pi. Wire-compatible with the Flutter receiver — same BLE UUIDs, same GATT chunked protocol, same advertisement format.

**Setup (on Pi):**
```bash
cd pi_sender
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
```

**CLI workflow:**
```bash
# Create an alert
beconnect-pi alert new --headline "..." --severity Extreme --expires <epoch> --instructions "..." --source-url "local://operator" --verified false

# List / edit alerts
beconnect-pi alert list
beconnect-pi alert edit <alert_id> --severity Severe

# Publish one alert for broadcast, then start the BLE broadcaster
beconnect-pi publish <alert_id>
beconnect-pi broadcast start          # background daemon
beconnect-pi broadcast start --foreground  # debug
beconnect-pi broadcast stop
beconnect-pi status
```

State files live in `~/.beconnect-pi/` (`alerts.json`, `current_alert.json`, `broadcaster.pid`, `broadcaster.log`). The broadcaster polls `current_alert.json` every ~2 s, so re-running `publish` hot-swaps the alert without restarting the daemon.

**Pi tests:**
```bash
cd pi_sender && python -m pytest tests/
```

## Demo Script (End-to-End)

1. Both phones have the app installed (Android or iOS, mixed is fine).
2. Gateway phone: Wi-Fi ON → "Gateway Mode" → "Fetch Alert" (or "Demo Mode") → "Start Broadcasting".
3. Receiver phone: disable Wi-Fi, Bluetooth ON → "Receiver Mode" → "Scan" → beacon appears.
4. Tap beacon → downloads and displays alert with severity + headline + instructions.
5. Target: under 60 seconds from scan to displayed alert.
