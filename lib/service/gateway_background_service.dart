import 'dart:async';
import 'dart:convert';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../data/alert_dao.dart';
import '../data/alert_packet.dart';
import '../ble/ble_scanner.dart';
import '../ble/gatt_client.dart';
// NOTE: GattServer is intentionally NOT imported here.
// GattServer.start/stop use MethodChannel('com.beconnect.beconnect/ble'),
// which is registered only in the main Flutter engine (MainActivity /
// AppDelegate). The flutter_background_service background isolate runs in a
// separate Flutter engine where that channel is absent — calling it there
// throws MissingPluginException. All GattServer calls live in HomeScreen
// (main isolate) instead, triggered via the 'meshAlert' IPC event.

class GatewayBackgroundService {
  static final _service = FlutterBackgroundService();

  /// Call once in main() before runApp. Configures (but does not start) the
  /// background service. Safe to call on every launch — configure is idempotent.
  static Future<void> init() async {
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'beconnect_bg_channel',
        initialNotificationTitle: 'BeConnect',
        initialNotificationContent: 'Mesh node active…',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.connectedDevice],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  /// Starts the autonomous background mesh node.
  /// Parameterless — the background isolate loads the latest alert from the
  /// DB itself and emits 'meshAlert' so HomeScreen can start GattServer.
  static Future<void> start() async {
    if (await _service.isRunning()) return;
    await _service.startService();
  }

  /// Notifies the background isolate of a newly fetched alert (e.g. from NWS).
  /// The background isolate persists it in its own DB connection and emits
  /// 'meshAlert' back so HomeScreen can call GattServer.restart() immediately.
  static void notifyNewAlert(AlertPacket alert) {
    _service.invoke('notifyAlert', {'alertJson': jsonEncode(alert.toJson())});
  }

  /// Exposes the service instance so HomeScreen can subscribe to IPC events
  /// ('serviceStarted', 'meshAlert') via service.on(eventName).listen(...).
  static FlutterBackgroundService get service => _service;
}

// ─── Background isolate entry point ──────────────────────────────────────────

bool _meshRunning = false; // guards against overlapping mesh iterations

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  final dao = AlertDao(); // fresh instance in this isolate

  // ── A: Signal to the main isolate that the service is up ─────────────────
  service.invoke('serviceStarted', {});

  // ── B: Kick off advertising immediately using the most recent stored alert ─
  // We cannot call GattServer here (wrong Flutter engine). Instead we send
  // 'meshAlert' — HomeScreen receives it and calls GattServer.restart().
  final existing = await dao.fetchAll();
  if (existing.isNotEmpty) {
    service.invoke('meshAlert', {
      'alertJson': jsonEncode(existing.first.toJson()),
    });
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'BeConnect',
        content: 'Broadcasting: ${existing.first.headline}',
      );
    }
  }

  // ── C: React to alerts pushed from the main isolate (e.g. NWS fetch) ─────
  service.on('notifyAlert').listen((data) async {
    if (data == null) return;
    try {
      final alert = AlertPacket.fromJson(
        jsonDecode(data['alertJson'] as String) as Map<String, dynamic>,
      );
      await dao.insert(alert);
      // Echo back as 'meshAlert' so HomeScreen updates GattServer.
      service.invoke('meshAlert', {'alertJson': jsonEncode(alert.toJson())});
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'BeConnect',
          content: 'Broadcasting: ${alert.headline}',
        );
      }
    } catch (_) {}
  });

  // ── D: Gossip mesh loop — run once immediately, then every 5 minutes ──────
  await _meshRoutine(service, dao);
  Timer.periodic(const Duration(minutes: 5), (_) async {
    await _meshRoutine(service, dao);
  });
}

Future<void> _meshRoutine(ServiceInstance service, AlertDao dao) async {
  if (_meshRunning) return; // previous iteration still in flight
  _meshRunning = true;
  try {
    // 1. One-shot BLE scan (15 s). scanForMesh() is isolate-safe — no streams.
    final beacons = await BleScanner.scanForMesh();

    // 2. Check each beacon's alertIdHash against the local DB.
    for (final beacon in beacons) {
      final hash = beacon.alertIdHash;
      if (hash == null) continue; // no hash → cannot do loop-prevention check
      if (await dao.hasAlert(hash)) continue; // already stored → skip

      // 3. New alert found — download it via GATT (isolate-safe; no channel).
      try {
        final alert = await GattClient.downloadAlert(beacon.device);

        // 4. Persist in background isolate's DB connection.
        await dao.insert(alert);

        // 5. Emit 'meshAlert' — HomeScreen calls GattServer.restart() in the
        //    main isolate where the MethodChannel is properly registered.
        service.invoke('meshAlert', {
          'alertJson': jsonEncode(alert.toJson()),
        });

        // 6. Update foreground notification.
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: 'BeConnect',
            content: 'Relaying: ${alert.headline}',
          );
        }

        break; // one new alert per cycle to avoid flooding
      } catch (_) {
        continue; // GATT/connection error — try next beacon
      }
    }
  } catch (_) {
    // Swallow all errors so the Timer keeps firing.
  } finally {
    _meshRunning = false;
  }
}

@pragma('vm:entry-point')
bool _onIosBackground(ServiceInstance service) => true;
