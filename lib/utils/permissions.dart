import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// Requests all runtime permissions required for BLE operation.
/// Returns true if every required permission was granted.
Future<bool> requestBlePermissions() async {
  final permissions = <Permission>[
    Permission.location,
    if (Platform.isAndroid) ...[
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

  final statuses = await permissions.request();

  final allGranted = statuses.values.every(
    (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
  );
  return allGranted;
}
