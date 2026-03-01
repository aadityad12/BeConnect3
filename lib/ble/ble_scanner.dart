import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../ble_constants.dart';

/// Represents a discovered BeConnect gateway beacon.
class BeaconInfo {
  final BluetoothDevice device;
  final String deviceName;
  final String severity;
  final int rssi;

  const BeaconInfo({
    required this.device,
    required this.deviceName,
    required this.severity,
    required this.rssi,
  });
}

/// Scans for BLE beacons advertising the BeConnect service UUID.
class BleScanner {
  static final _beaconsController =
      StreamController<List<BeaconInfo>>.broadcast();

  /// Live stream of discovered BeConnect beacons.
  static Stream<List<BeaconInfo>> get beaconsStream =>
      _beaconsController.stream;

  static final Map<String, BeaconInfo> _beacons = {};
  static StreamSubscription<List<ScanResult>>? _sub;

  static Future<void> startScan() async {
    _beacons.clear();
    _beaconsController.add([]);

    _sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        // Secondary filter: confirm our service UUID is present
        final hasService = r.advertisementData.serviceUuids
            .any((g) => g == Guid(serviceUuid));
        if (!hasService) continue;

        // Parse severity from manufacturer data
        final mfData = r.advertisementData.manufacturerData;
        String severity = 'Unknown';
        if (mfData.containsKey(manufacturerId)) {
          final bytes = mfData[manufacturerId]!;
          if (bytes.isNotEmpty) severity = byteToSeverity(bytes[0]);
        }

        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName.isNotEmpty
                ? r.device.platformName
                : r.device.remoteId.str;

        _beacons[r.device.remoteId.str] = BeaconInfo(
          device:     r.device,
          deviceName: name,
          severity:   severity,
          rssi:       r.rssi,
        );
      }
      _beaconsController.add(List.of(_beacons.values));
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(serviceUuid)],
      timeout: const Duration(seconds: 30),
    );
  }

  static Future<void> stopScan() async {
    await _sub?.cancel();
    _sub = null;
    await FlutterBluePlus.stopScan();
  }

  /// Restarts a fresh 30-second scan window.
  static Future<void> restartScan() async {
    await stopScan();
    await startScan();
  }
}
