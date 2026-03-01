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

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _dao = AlertDao();
  List<AlertPacket> _alerts = [];
  bool _loading = false;   // NWS fetch in progress
  bool _scanning = false;  // foreground BLE scan in progress
  bool _meshActive = false;
  bool _fabReady = false;
  String _scanStatus = '';
  String? _fetchError;

  late final AnimationController _meshPulseCtrl;

  /// Cancelled in dispose() to prevent leaks.
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _meshPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _fabReady = true);
    });
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
    if (alreadyRunning && mounted) {
      setState(() => _meshActive = true);
      if (!_meshPulseCtrl.isAnimating) _meshPulseCtrl.repeat(reverse: true);
    }

    // 5. Load whatever alerts are already in the local DB.
    await _loadAlerts();

    // 6. Kick off an immediate foreground scan so the user doesn't have to
    //    wait up to 5 minutes for the background service to discover the Pi.
    if (granted && mounted) _runForegroundScan();
  }

  void _subscribeToServiceEvents() {
    final svc = GatewayBackgroundService.service;

    _subs.add(svc.on('serviceStarted').listen((_) {
      if (mounted) {
        setState(() => _meshActive = true);
        if (!_meshPulseCtrl.isAnimating) _meshPulseCtrl.repeat(reverse: true);
      }
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
    _meshPulseCtrl.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    BleScanner.stopScan();
    super.dispose();
  }

  // ── Alert actions ────────────────────────────────────────────────────────────

  Future<void> _deleteAlert(AlertPacket alert) async {
    setState(() => _alerts.removeWhere((a) => a.alertId == alert.alertId));
    await _dao.deleteAlert(alert.alertId);
  }

  Future<void> _togglePin(AlertPacket alert) async {
    final newPinned = !alert.pinned;
    await _dao.setPinned(alert.alertId, pinned: newPinned);
    await _loadAlerts();
  }

  void _showAlertContextMenu(AlertPacket alert, bool isNewest) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AlertContextMenu(
        alert: alert,
        isNewest: isNewest,
        onPin: () {
          Navigator.pop(context);
          _togglePin(alert);
        },
        onDelete: isNewest
            ? null
            : () {
                Navigator.pop(context);
                _showDeleteConfirmation(alert);
              },
      ),
    );
  }

  void _showDeleteConfirmation(AlertPacket alert) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _DeleteConfirmDialog(
        alert: alert,
        onConfirm: () {
          Navigator.pop(context);
          _deleteAlert(alert);
        },
        onCancel: () => Navigator.pop(context),
      ),
    );
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
                  AnimatedBuilder(
                    animation: _meshPulseCtrl,
                    builder: (_, child) => Container(
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF4CAF50).withAlpha(
                              (30 + 25 * _meshPulseCtrl.value).round(),
                            ),
                            blurRadius: 14,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: child,
                    ),
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
              else ...[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final alert = _alerts[i];
                        // The newest non-pinned alert (index 0 after sort) is
                        // the one that cannot be deleted.
                        final isNewest = i == 0;
                        return _AlertCard(
                          key: ValueKey(alert.alertId),
                          alert: alert,
                          isNewest: isNewest,
                          index: i,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AlertDetailScreen(alert: alert),
                            ),
                          ),
                          onLongPress: () =>
                              _showAlertContextMenu(alert, isNewest),
                        );
                      },
                      childCount: _alerts.length,
                    ),
                  ),
                ),
                // "You're all caught up" footer
                const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        "You're all caught up",
                        style: TextStyle(color: Colors.white24, fontSize: 13),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      // FAB for manual re-scan — scales in with elastic bounce.
      floatingActionButton: AnimatedScale(
        scale: _fabReady ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.elasticOut,
        child: FloatingActionButton(
          onPressed: _scanning ? null : _runForegroundScan,
          tooltip: 'Scan for beacons',
          backgroundColor: _scanning
              ? Colors.white.withAlpha(30)
              : const Color(0xFFE64A19).withAlpha(217),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withAlpha(40), width: 1),
          ),
          child: _scanning
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5),
                )
              : const Icon(Icons.bluetooth_searching, color: Colors.white),
        ),
      ),
    );
  }
}

// ─── Scan status banner ───────────────────────────────────────────────────────

class _ScanBanner extends StatefulWidget {
  final String status;
  final bool scanning;

  const _ScanBanner({required this.status, required this.scanning});

  @override
  State<_ScanBanner> createState() => _ScanBannerState();
}

class _ScanBannerState extends State<_ScanBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerCtrl;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

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
            if (widget.scanning) ...[
              // Track
              Container(
                height: 3,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: Colors.white.withAlpha(20),
                ),
              ),
              const SizedBox(height: 2),
              // Shimmer sweep
              AnimatedBuilder(
                animation: _shimmerCtrl,
                builder: (_, __) => ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(_shimmerCtrl.value * 4 - 2, 0),
                        end: Alignment(_shimmerCtrl.value * 4 - 1, 0),
                        colors: const [
                          Colors.transparent,
                          Color(0xFFE64A19),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                const Icon(Icons.bluetooth_searching,
                    size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.status.isNotEmpty ? widget.status : 'Scanning…',
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

class _AlertCard extends StatefulWidget {
  final AlertPacket alert;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool isNewest;
  final int index;

  const _AlertCard({
    super.key,
    required this.alert,
    required this.onTap,
    required this.onLongPress,
    this.isNewest = false,
    this.index = 0,
  });

  @override
  State<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends State<_AlertCard> with TickerProviderStateMixin {
  late final AnimationController _entranceCtrl;
  late final AnimationController _glowCtrl;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    // Stagger entrance: each card delays by 50ms × its index (capped at 6).
    final delay = Duration(milliseconds: 50 * widget.index.clamp(0, 6));
    Future.delayed(delay, () {
      if (mounted) _entranceCtrl.forward();
    });

    if (SeverityColors.hasGlow(widget.alert.severity)) {
      _glowCtrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  String _formatAge() {
    final age =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - widget.alert.fetchedAt;
    if (age < 60) return '${age}s ago';
    if (age < 3600) return '${age ~/ 60}m ago';
    return '${age ~/ 3600}h ago';
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final color = SeverityColors.main(alert.severity);
    final hasGlow = SeverityColors.hasGlow(alert.severity);

    return FadeTransition(
      opacity: _entranceCtrl,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut)),
        child: AnimatedScale(
          scale: _isPressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _isPressed = true),
            onTapUp: (_) => setState(() => _isPressed = false),
            onTapCancel: () => setState(() => _isPressed = false),
            child: AnimatedBuilder(
              animation: _glowCtrl,
              builder: (_, child) {
                final glowAlpha = (20 + 31 * _glowCtrl.value).round();
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: SeverityColors.tint(alert.severity),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: SeverityColors.border(alert.severity)),
                    boxShadow: hasGlow
                        ? [
                            BoxShadow(
                              color: color.withAlpha(glowAlpha),
                              blurRadius: 20,
                              spreadRadius: 2,
                            )
                          ]
                        : null,
                  ),
                  child: child,
                );
              },
              // child is cached — only the Container decoration rebuilds each frame.
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Accent bar
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
                                  // Severity pill badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: color.withAlpha(40),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                          color: color.withAlpha(150),
                                          width: 0.8),
                                    ),
                                    child: Text(
                                      alert.severity.toUpperCase(),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                  if (!alert.verified) ...[
                                    const SizedBox(width: 6),
                                    // DEMO tag — pill style, clearly secondary
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withAlpha(12),
                                        borderRadius:
                                            BorderRadius.circular(20),
                                        border: Border.all(
                                            color: Colors.white24,
                                            width: 0.5),
                                      ),
                                      child: const Text(
                                        'DEMO',
                                        style: TextStyle(
                                          color: Colors.white38,
                                          fontSize: 10,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (alert.pinned) ...[
                                    const SizedBox(width: 6),
                                    const Icon(Icons.push_pin,
                                        size: 11, color: Colors.white54),
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
                                  fontSize: 14,
                                ),
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
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Alert context menu (long-press bottom sheet) ─────────────────────────────

class _AlertContextMenu extends StatelessWidget {
  final AlertPacket alert;
  final bool isNewest;
  final VoidCallback onPin;
  final VoidCallback? onDelete;

  const _AlertContextMenu({
    required this.alert,
    required this.isNewest,
    required this.onPin,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0D0F1A).withAlpha(230),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: const Border(
              top: BorderSide(color: Colors.white12),
              left: BorderSide(color: Colors.white12),
              right: BorderSide(color: Colors.white12),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),

                // Alert headline preview
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 36,
                        decoration: BoxDecoration(
                          color: SeverityColors.main(alert.severity),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          alert.headline,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(color: Colors.white12, height: 1),
                const SizedBox(height: 8),

                // Pin / Unpin option
                _ContextMenuItem(
                  icon: alert.pinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin,
                  label: alert.pinned ? 'Unpin alert' : 'Pin alert',
                  onTap: onPin,
                ),

                // Delete option — only for non-newest alerts
                if (onDelete != null) ...[
                  const Divider(
                      color: Colors.white12,
                      height: 1,
                      indent: 20,
                      endIndent: 20),
                  _ContextMenuItem(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete alert',
                    color: Colors.redAccent,
                    onTap: onDelete!,
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ContextMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Delete confirmation dialog ───────────────────────────────────────────────

class _DeleteConfirmDialog extends StatelessWidget {
  final AlertPacket alert;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _DeleteConfirmDialog({
    required this.alert,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0D0F1A).withAlpha(230),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white12),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.delete_outline_rounded,
                        color: Colors.redAccent, size: 22),
                    SizedBox(width: 10),
                    Text(
                      'Delete Alert',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Are you sure you want to delete\n"${alert.headline}"?',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This action cannot be undone.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onCancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: onConfirm,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade800,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Delete'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
