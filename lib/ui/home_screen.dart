import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../ble/ble_scanner.dart';
import '../ble/gatt_client.dart';
import '../ble/gatt_server.dart';
import '../data/alert_dao.dart';
import '../data/alert_packet.dart';
import '../demo/demo_alerts.dart';
import '../network/alert_fetcher.dart';
import '../service/gateway_background_service.dart';
import '../utils/permissions.dart';
import 'receiver/alert_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _dao = AlertDao();
  List<AlertPacket> _alerts = [];
  bool _loading = false;   // NWS fetch in progress
  bool _scanning = false;  // foreground BLE scan in progress
  bool _meshActive = false;
  String _scanStatus = '';
  String? _fetchError;

  /// Cancelled in dispose() to prevent leaks.
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Full startup sequence: permissions → service → events → load DB → scan.
  Future<void> _bootstrap() async {
    // 1. Aggressively prompt for all BLE + location + notification permissions.
    final granted = await requestBlePermissions();
    if (!mounted) return;

    if (granted) {
      // 2. Start the autonomous background mesh service (idempotent).
      await GatewayBackgroundService.start();
    }

    // 3. Wire up IPC event listeners from the background isolate.
    _subscribeToServiceEvents();

    // 4. Handle hot-restart case: service was already running, won't re-emit
    //    'serviceStarted', so check isRunning() directly.
    final alreadyRunning = await GatewayBackgroundService.service.isRunning();
    if (alreadyRunning && mounted) setState(() => _meshActive = true);

    // 5. Load whatever alerts are already in the local DB.
    await _loadAlerts();

    // 6. Kick off an immediate foreground scan so the user doesn't have to
    //    wait up to 5 minutes for the background service to discover the Pi.
    if (granted && mounted) _runForegroundScan();
  }

  void _subscribeToServiceEvents() {
    final svc = GatewayBackgroundService.service;

    _subs.add(svc.on('serviceStarted').listen((_) {
      if (mounted) setState(() => _meshActive = true);
    }));

    // Background isolate found/relayed a new alert → update GattServer in
    // the main isolate (only place the MethodChannel is registered).
    _subs.add(svc.on('meshAlert').listen((data) async {
      if (data == null) return;
      try {
        final alert = AlertPacket.fromJson(
          jsonDecode(data['alertJson'] as String) as Map<String, dynamic>,
        );
        await GattServer.restart(alert);
        if (mounted) await _loadAlerts();
      } catch (_) {}
    }));
  }

  /// Reads all alerts from SQLite ordered by most-recently-fetched first.
  Future<void> _loadAlerts() async {
    final alerts = await _dao.fetchAll();
    if (mounted) setState(() => _alerts = alerts);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    BleScanner.stopScan();
    super.dispose();
  }

  // ── Foreground BLE scan ─────────────────────────────────────────────────────

  /// Runs a 15-second foreground scan in the main isolate.
  /// Same logic as the background mesh routine, but with live UI feedback and
  /// reliable iOS/Android BLE access (no background isolate limitations).
  Future<void> _runForegroundScan() async {
    if (_scanning) return;
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _scanStatus = 'Scanning for beacons…';
    });

    try {
      final beacons = await BleScanner.scanForMesh(
        timeout: const Duration(seconds: 15),
      );

      if (!mounted) return;

      if (beacons.isEmpty) {
        setState(() => _scanStatus = 'No beacons found nearby.');
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => _scanStatus = '');
        return;
      }

      setState(() => _scanStatus = 'Found ${beacons.length} beacon(s). Connecting…');

      // Process beacons — skip any whose alert is already stored (loop prevention).
      for (final beacon in beacons) {
        if (!mounted) break;
        final hash = beacon.alertIdHash;
        if (hash != null && await _dao.hasAlert(hash)) continue;

        setState(() => _scanStatus = 'Downloading from ${beacon.deviceName}…');
        try {
          final alert = await GattClient.downloadAlert(beacon.device);
          await _dao.insert(alert);
          // Keep background isolate's DB in sync and update GattServer.
          GatewayBackgroundService.notifyNewAlert(alert);
          await GattServer.restart(alert);
          await _loadAlerts();
          break; // one new alert per scan cycle (same as mesh routine)
        } catch (_) {
          continue; // GATT error — try next beacon
        }
      }

      if (mounted) setState(() => _scanStatus = '');
    } catch (e) {
      if (mounted) setState(() => _scanStatus = 'Scan error: $e');
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) setState(() => _scanStatus = '');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  // ── NWS / Demo actions ──────────────────────────────────────────────────────

  Future<void> _fetchNws() async {
    setState(() {
      _loading = true;
      _fetchError = null;
    });
    try {
      final fetched = await AlertFetcher().fetchAlerts();
      if (fetched.isEmpty) {
        if (mounted) setState(() => _fetchError = 'No active NWS alerts right now.');
        return;
      }
      for (final a in fetched) {
        await _dao.insert(a);
      }
      GatewayBackgroundService.notifyNewAlert(fetched.first);
      await GattServer.restart(fetched.first);
      await _loadAlerts();
    } catch (e) {
      if (mounted) setState(() => _fetchError = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDemo() async {
    setState(() => _fetchError = null);
    for (final a in demoAlerts) {
      await _dao.insert(a);
    }
    GatewayBackgroundService.notifyNewAlert(demoAlerts.first);
    await GattServer.restart(demoAlerts.first);
    await _loadAlerts();
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BeConnect'),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
        actions: [
          if (_meshActive)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                label: const Text(
                  'MESH ACTIVE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
                backgroundColor: Colors.green.shade700,
                avatar: const Icon(Icons.cell_tower, color: Colors.white, size: 14),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download),
            tooltip: 'Fetch NWS Alerts',
            onPressed: _loading ? null : _fetchNws,
          ),
          IconButton(
            icon: const Icon(Icons.science),
            tooltip: 'Load Demo Alerts',
            onPressed: _loadDemo,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadAlerts,
        child: CustomScrollView(
          slivers: [
            // Scan status banner — shown while a foreground scan is in progress.
            if (_scanning || _scanStatus.isNotEmpty)
              SliverToBoxAdapter(
                child: _ScanBanner(
                  status: _scanStatus,
                  scanning: _scanning,
                ),
              ),

            if (_fetchError != null)
              SliverToBoxAdapter(
                child: _ErrorBanner(
                  message: _fetchError!,
                  onDismiss: () => setState(() => _fetchError = null),
                ),
              ),

            if (_alerts.isEmpty)
              SliverFillRemaining(
                child: _EmptyState(scanning: _scanning),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => _AlertCard(
                      alert: _alerts[i],
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AlertDetailScreen(alert: _alerts[i]),
                        ),
                      ),
                    ),
                    childCount: _alerts.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      // FAB for manual re-scan.
      floatingActionButton: FloatingActionButton(
        onPressed: _scanning ? null : _runForegroundScan,
        tooltip: 'Scan for beacons',
        backgroundColor: _scanning ? Colors.grey : Colors.deepOrange,
        child: _scanning
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5),
              )
            : const Icon(Icons.bluetooth_searching, color: Colors.white),
      ),
    );
  }
}

// ─── Scan status banner ───────────────────────────────────────────────────────

class _ScanBanner extends StatelessWidget {
  final String status;
  final bool scanning;

  const _ScanBanner({required this.status, required this.scanning});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (scanning) const LinearProgressIndicator(color: Colors.deepOrange),
        Container(
          width: double.infinity,
          color: Colors.deepOrange.withAlpha(20),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.bluetooth_searching,
                  size: 16, color: Colors.deepOrange.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.isNotEmpty ? status : 'Scanning…',
                  style: TextStyle(
                      color: Colors.deepOrange.shade900, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Error banner ─────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: Colors.red,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool scanning;

  const _EmptyState({required this.scanning});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            scanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
            size: 72,
            color: Colors.grey.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            scanning
                ? 'Scanning for nearby beacons…'
                : 'No alerts saved yet.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            scanning
                ? 'This takes about 15 seconds.'
                : 'Tap \u25ba to scan for nearby Pi beacons,\nor \u2193 to fetch from NWS.',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─── Alert card ───────────────────────────────────────────────────────────────

class _AlertCard extends StatelessWidget {
  final AlertPacket alert;
  final VoidCallback onTap;

  const _AlertCard({required this.alert, required this.onTap});

  Color get _severityColor {
    switch (alert.severity) {
      case 'Extreme':  return Colors.red.shade700;
      case 'Severe':   return Colors.orange.shade700;
      case 'Moderate': return Colors.yellow.shade800;
      default:         return Colors.grey.shade600;
    }
  }

  String _formatAge() {
    final age =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - alert.fetchedAt;
    if (age < 60) return '${age}s ago';
    if (age < 3600) return '${age ~/ 60}m ago';
    return '${age ~/ 3600}h ago';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _severityColor.withAlpha(100), width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 56,
                decoration: BoxDecoration(
                  color: _severityColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _severityColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            alert.severity.toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (!alert.verified) ...[
                          const SizedBox(width: 6),
                          Text('DEMO',
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 10)),
                        ],
                        const Spacer(),
                        Text(
                          _formatAge(),
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      alert.headline,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_forward_ios,
                  size: 14, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
