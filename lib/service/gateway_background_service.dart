import 'package:flutter_background_service/flutter_background_service.dart';
import '../data/alert_packet.dart';
import '../ble/gatt_server.dart';

/// Keeps the BLE gateway alive in the background via a foreground service
/// on Android (persistent notification) and a background task on iOS.
class GatewayBackgroundService {
  static final _service = FlutterBackgroundService();

  /// Call once in main() before runApp.
  static Future<void> init() async {
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart:                       _onStart,
        autoStart:                     false,
        isForegroundMode:              true,
        notificationChannelId:         'beconnect_bg_channel',
        initialNotificationTitle:      'BeConnect',
        initialNotificationContent:    'Broadcasting alert...',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.connectedDevice],
      ),
      iosConfiguration: IosConfiguration(
        autoStart:    false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  /// Starts the foreground service and begins BLE advertising.
  static Future<void> start(AlertPacket alert) async {
    await _service.startService();
    _service.invoke('setNotification', {
      'title':   'BeConnect',
      'content': 'Broadcasting: ${alert.headline}',
    });
    await GattServer.start(alert);
  }

  /// Stops BLE advertising and the foreground service.
  static Future<void> stop() async {
    await GattServer.stop();
    _service.invoke('stop');
  }
}

// ─── Background isolate entry points ────────────────────────────────────────

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.on('setNotification').listen((data) {
      if (data != null) {
        service.setForegroundNotificationInfo(
          title:   data['title'] as String,
          content: data['content'] as String,
        );
      }
    });
    service.on('stop').listen((_) => service.stopSelf());
  }
}

@pragma('vm:entry-point')
bool _onIosBackground(ServiceInstance service) => true;
