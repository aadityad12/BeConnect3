import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

List<Permission> _requiredBlePermissions() {
  if (Platform.isIOS) {
    return <Permission>[
      Permission.bluetooth,
    ];
  }

  return <Permission>[
    if (Platform.isAndroid) ...[
      Permission.location,
      // Note: Permission.bluetooth corresponds to the legacy BLUETOOTH and BLUETOOTH_ADMIN
      // permissions. These are "normal" permissions (granted at install time) and
      // should not be requested at runtime. Including them here causes "missing in manifest"
      // errors on Android 12+ when maxSdkVersion="30" is used in the manifest.
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.notification,
    ],
  ];
}

/// Checks if all runtime permissions required for BLE operation are already granted.
Future<bool> hasBlePermissions() async {
  final statuses = await Future.wait(
    _requiredBlePermissions().map((permission) => permission.status),
  );
  debugPrint('BLE permission statuses: ${statuses.join(', ')}');
  return statuses.every(
    (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
  );
}

/// Requests all runtime permissions required for BLE operation.
/// Returns true if every required permission was granted.
Future<bool> requestBlePermissions() async {
  final statuses = await _requiredBlePermissions().request();
  debugPrint('BLE permission request results: ${statuses.values.join(', ')}');

  final allGranted = statuses.values.every(
    (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
  );
  return allGranted;
}

Future<bool> hasPermanentlyDeniedBlePermission() async {
  final statuses = await Future.wait(
    _requiredBlePermissions().map((permission) => permission.status),
  );
  return statuses.any((s) => s == PermissionStatus.permanentlyDenied);
}
