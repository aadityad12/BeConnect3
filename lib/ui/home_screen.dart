import 'dart:async';
import 'dart:convert';
import 'dart:ui';
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
import 'theme/severity_colors.dart';
import 'widgets/glass_container.dart';
import 'widgets/glass_scaffold.dart';

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
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: AppBar(
              title: const Text(
                'BeConnect',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: Colors.white.withAlpha(20),
              elevation: 0,
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
                      backgroundColor: const Color(0xFF2E7D32).withAlpha(217),
                      avatar: const Icon(
                          Icons.cell_tower, color: Colors.white, size: 14),
                      side: const BorderSide(color: Colors.white24),
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
          ),
        ),
      ),
      body: GlassScaffold(
        child: RefreshIndicator(
          onRefresh: _loadAlerts,
          color: const Color(0xFFE64A19),
          child: CustomScrollView(
            slivers: [
              // Space for the glass AppBar + status bar
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                ),
              ),

              // Scan status banner
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
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
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
      ),
      // FAB for manual re-scan.
      floatingActionButton: FloatingActionButton(
        onPressed: _scanning ? null : _runForegroundScan,
        tooltip: 'Scan for beacons',
        backgroundColor: _scanning
            ? Colors.white.withAlpha(30)
            : const Color(0xFFE64A19).withAlpha(217),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GlassContainer(
        blur: true,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (scanning)
              const LinearProgressIndicator(
                color: Color(0xFFE64A19),
                backgroundColor: Colors.white12,
              ),
            if (scanning) const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.bluetooth_searching,
                    size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.isNotEmpty ? status : 'Scanning…',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GlassContainer(
        blur: true,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        tint: Colors.red.withAlpha(38),
        borderColor: Colors.red.withAlpha(102),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: Colors.white54,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onDismiss,
            ),
          ],
        ),
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
            color: Colors.white24,
          ),
          const SizedBox(height: 16),
          Text(
            scanning
                ? 'Scanning for nearby beacons…'
                : 'No alerts saved yet.',
            style: const TextStyle(color: Colors.white54, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            scanning
                ? 'This takes about 15 seconds.'
                : 'Tap \u25ba to scan for nearby Pi beacons,\nor \u2193 to fetch from NWS.',
            style: const TextStyle(color: Colors.white30, fontSize: 13),
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

  String _formatAge() {
    final age =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - alert.fetchedAt;
    if (age < 60) return '${age}s ago';
    if (age < 3600) return '${age ~/ 60}m ago';
    return '${age ~/ 3600}h ago';
  }

  @override
  Widget build(BuildContext context) {
    final color = SeverityColors.main(alert.severity);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: SeverityColors.tint(alert.severity),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SeverityColors.border(alert.severity)),
        boxShadow: SeverityColors.hasGlow(alert.severity)
            ? [
                BoxShadow(
                  color: color.withAlpha(64),
                  blurRadius: 16,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
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
                    color: color,
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
                              color: color,
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
                            const Text('DEMO',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 10)),
                          ],
                          const Spacer(),
                          Text(
                            _formatAge(),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        alert.headline,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_ios,
                    size: 14, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
