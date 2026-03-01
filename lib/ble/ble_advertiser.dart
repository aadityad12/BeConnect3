import '../data/alert_packet.dart';
import 'gatt_server.dart';

/// Thin delegate — advertising is started alongside the GATT server on the
/// native side, so this class simply forwards to GattServer.
class BleAdvertiser {
  static Future<void> start(AlertPacket alert) => GattServer.start(alert);
  static Future<void> stop() => GattServer.stop();
  static bool get isRunning => GattServer.isRunning;
}
