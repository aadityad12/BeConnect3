import 'dart:convert';
import 'package:flutter/services.dart';
import '../data/alert_packet.dart';
import '../ble_constants.dart';

/// Bridges to platform-native BLE advertising + GATT server.
///
/// Android: BluetoothLeAdvertiser + BluetoothGattServer  (MainActivity.kt)
/// iOS:     CBPeripheralManager                          (AppDelegate.swift)
///
/// Channel method "startAdvertising" args:
///   { "alertJson": String, "severityByte": int }
/// Channel method "stopAdvertising": no args
class GattServer {
  static const _channel = MethodChannel('com.beconnect.beconnect/ble');

  static bool _running = false;
  static bool get isRunning => _running;

  static Future<void> start(AlertPacket alert) async {
    if (_running) return;
    await _channel.invokeMethod<void>('startAdvertising', {
      'alertJson':    jsonEncode(alert.toJson()),
      'severityByte': severityToByte(alert.severity),
    });
    _running = true;
  }

  static Future<void> stop() async {
    if (!_running) return;
    await _channel.invokeMethod<void>('stopAdvertising');
    _running = false;
  }

  /// Stops any current broadcast and starts a fresh one for [alert].
  /// Use this when the mesh relays a newer alert that should replace
  /// the currently advertised one.
  static Future<void> restart(AlertPacket alert) async {
    if (_running) await stop();
    await start(alert);
  }
}
