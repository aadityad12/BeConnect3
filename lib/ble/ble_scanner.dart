import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../ble_constants.dart';

/// Represents a discovered BeConnect gateway beacon.
class BeaconInfo {
  final BluetoothDevice device;
  final String deviceName;
  final String severity;
  final int rssi;
  final String? alertIdHash; // 8-char hex from manufacturer bytes[1..4]; null if absent

  const BeaconInfo({
    required this.device,
    required this.deviceName,
    required this.severity,
    required this.rssi,
    this.alertIdHash,
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

  /// Parses a BeaconInfo from a ScanResult. Returns null if the result
  /// does not carry the BeConnect service UUID.
  static BeaconInfo? _parseResult(ScanResult r) {
    final hasService = r.advertisementData.serviceUuids
        .any((g) => g == Guid(serviceUuid));
    // Fallback: accept by device name when iOS doesn't report serviceUuids
    // (macOS CoreBluetooth peripherals sometimes advertise UUID in overflow area).
    final advName = r.advertisementData.advName;
    final platformName = r.device.platformName;
    final hasBeaconName = advName == 'BeConnect' || platformName == 'BeConnect';
    if (!hasService && !hasBeaconName) return null;

    final mfData = r.advertisementData.manufacturerData;
    String severity = 'Unknown';
    String? alertIdHash;

    if (mfData.containsKey(manufacturerId)) {
      final bytes = mfData[manufacturerId]!;
      if (bytes.isNotEmpty) severity = byteToSeverity(bytes[0]);
      // Pi protocol: [severity:1][alertIdHash:4][fetchedAt:4]
      if (bytes.length >= 5) {
        alertIdHash = bytes
            .sublist(1, 5)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
      }
    }

    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.device.remoteId.str;

    return BeaconInfo(
      device: r.device,
      deviceName: name,
      severity: severity,
      rssi: r.rssi,
      alertIdHash: alertIdHash,
    );
  }

  static Future<void> startScan() async {
    // On iOS, CBCentralManager briefly reports unknown before settling.
    // Skip transient states (unknown / turningOn) and wait for a definitive one.
    var adapterState = FlutterBluePlus.adapterStateNow;
    if (adapterState == BluetoothAdapterState.unknown ||
        adapterState == BluetoothAdapterState.turningOn) {
      adapterState = await FlutterBluePlus.adapterState
          .where((s) =>
              s != BluetoothAdapterState.unknown &&
              s != BluetoothAdapterState.turningOn)
          .first
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => FlutterBluePlus.adapterStateNow,
          );
    }
    if (adapterState != BluetoothAdapterState.on) {
      throw Exception('Bluetooth is not available (state: ${adapterState.name})');
    }

    _beacons.clear();
    _beaconsController.add([]);

    _sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final info = _parseResult(r);
        if (info != null) _beacons[r.device.remoteId.str] = info;
      }
      _beaconsController.add(List.of(_beacons.values));
    });

    // Do NOT pass withServices here: on iOS the hardware filter can strip
    // serviceUuids from the delivered advertisement data, causing the software
    // filter below to drop every result. Scan all devices and filter in code.
    await FlutterBluePlus.startScan(
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

  /// One-shot scan suitable for use in a background isolate.
  /// Scans for [timeout], collects results, and returns them without
  /// updating the UI stream.
  static Future<List<BeaconInfo>> scanForMesh({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // Wait for a definitive adapter state (same guard as startScan)
    var state = FlutterBluePlus.adapterStateNow;
    if (state == BluetoothAdapterState.unknown ||
        state == BluetoothAdapterState.turningOn) {
      state = await FlutterBluePlus.adapterState
          .where((s) =>
              s != BluetoothAdapterState.unknown &&
              s != BluetoothAdapterState.turningOn)
          .first
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => FlutterBluePlus.adapterStateNow,
          );
    }
    if (state != BluetoothAdapterState.on) return [];

    final found = <String, BeaconInfo>{};
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final info = _parseResult(r);
        if (info != null) found[r.device.remoteId.str] = info;
      }
    });

    await FlutterBluePlus.startScan(
      timeout: timeout,
    );
    await sub.cancel();
    return found.values.toList();
  }
}
