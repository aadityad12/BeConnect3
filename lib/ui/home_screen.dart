import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
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
import 'settings_screen.dart';
import 'theme/severity_colors.dart';
import 'widgets/glass_container.dart';
import 'widgets/glass_scaffold.dart';

// ─── Tag helper (shared with detail screen) ────────────────────────────────

bool _isDemo(AlertPacket a) =>
    a.alertId.startsWith('demo') || a.sourceUrl.contains('weather.gov/demo');

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _dao = AlertDao();
  List<AlertPacket> _alerts = [];
  List<String> _selectedStates = [];
  bool _loading = false;
  bool _scanning = false;
  bool _meshActive = false;
  /// Tracks which card (by alertId) is currently swiped open.
  /// When a card opens, others listen and close themselves.
  final _openSwipeId = ValueNotifier<String?>(null);
  bool _fabReady = false;
  bool _btOn = true;
  String _scanStatus = '';
  String? _fetchError;

  late final AnimationController _meshPulseCtrl;

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

  Future<void> _bootstrap() async {
    // Subscribe to Bluetooth adapter state (for red/green chip)
    _subs.add(FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _btOn = state == BluetoothAdapterState.on);
    }));

    final granted = await requestBlePermissions();
    if (!mounted) return;

    if (granted) {
      await GatewayBackgroundService.start();
    }

    _subscribeToServiceEvents();

    final alreadyRunning = await GatewayBackgroundService.service.isRunning();
    if (alreadyRunning && mounted) {
      setState(() => _meshActive = true);
      if (!_meshPulseCtrl.isAnimating) _meshPulseCtrl.repeat(reverse: true);
    }

    _selectedStates = await loadSelectedStates();
    await _loadAlerts();

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

  Future<void> _loadAlerts() async {
    final alerts = await _dao.fetchAll();
    if (mounted) setState(() => _alerts = alerts);
  }

  @override
  void dispose() {
    _meshPulseCtrl.dispose();
    _openSwipeId.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    BleScanner.stopScan();
    super.dispose();
  }

  // ── Alert actions ──────────────────────────────────────────────────────────

  Future<void> _deleteAlert(AlertPacket alert) async {
    setState(() => _alerts.removeWhere((a) => a.alertId == alert.alertId));
    await _dao.deleteAlert(alert.alertId);
  }

  Future<void> _togglePin(AlertPacket alert) async {
    await _dao.setPinned(alert.alertId, pinned: !alert.pinned);
    await _loadAlerts();
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

  // ── Foreground BLE scan ────────────────────────────────────────────────────

  Future<void> _runForegroundScan() async {
    if (_scanning) return;
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _scanStatus = 'Scanning for Relay nodes…';
    });

    try {
      final beacons = await BleScanner.scanForMesh(
        timeout: const Duration(seconds: 15),
      );

      if (!mounted) return;

      if (beacons.isEmpty) {
        setState(() => _scanStatus = 'No Relay nodes found nearby.');
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => _scanStatus = '');
        return;
      }

      setState(() =>
          _scanStatus = 'Found ${beacons.length} Relay node(s). Connecting…');

      for (final beacon in beacons) {
        if (!mounted) break;
        final hash = beacon.alertIdHash;
        if (hash != null && await _dao.hasAlert(hash)) continue;

        setState(
            () => _scanStatus = 'Downloading from ${beacon.deviceName}…');
        try {
          final alert = await GattClient.downloadAlert(beacon.device);
          await _dao.insert(alert);
          GatewayBackgroundService.notifyNewAlert(alert);
          await GattServer.restart(alert);
          await _loadAlerts();
          break;
        } catch (_) {
          continue;
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

  // ── NWS / Demo ────────────────────────────────────────────────────────────

  Future<void> _reloadStates() async {
    _selectedStates = await loadSelectedStates();
  }

  Future<void> _fetchNws() async {
    setState(() {
      _loading = true;
      _fetchError = null;
    });
    try {
      final fetched =
          await AlertFetcher().fetchAlerts(states: _selectedStates);
      if (fetched.isEmpty) {
        if (mounted)
          setState(() => _fetchError = 'No active NWS alerts right now.');
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

  // ── Build ──────────────────────────────────────────────────────────────────

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
                'Echo',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: Colors.white.withAlpha(20),
              elevation: 0,
              actions: [
                // Mesh / BT status chip — always visible
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _MeshChip(
                    btOn: _btOn,
                    meshActive: _meshActive,
                    pulseCtrl: _meshPulseCtrl,
                  ),
                ),
                // Settings gear
                IconButton(
                  icon: const Icon(Icons.settings_outlined, color: Colors.white),
                  tooltip: 'Settings',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SettingsScreen(
                          onFetchNws: _loading ? null : _fetchNws,
                          onLoadDemo: _loadDemo,
                        ),
                      ),
                    ).then((_) => _reloadStates());
                  },
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
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).padding.top +
                      kToolbarHeight +
                      8,
                ),
              ),

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
                        final isNewest = i == 0;
                        return _AlertCard(
                          key: ValueKey(alert.alertId),
                          alert: alert,
                          isNewest: isNewest,
                          index: i,
                          openSwipeId: _openSwipeId,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AlertDetailScreen(alert: alert),
                            ),
                          ),
                          onPin: () => _togglePin(alert),
                          onDelete: () => _showDeleteConfirmation(alert),
                        );
                      },
                      childCount: _alerts.length,
                    ),
                  ),
                ),
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
      floatingActionButton: AnimatedScale(
        scale: _fabReady ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.elasticOut,
        child: FloatingActionButton(
          onPressed: _scanning ? null : _runForegroundScan,
          tooltip: 'Scan for Relay nodes',
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

// ─── Mesh status chip ─────────────────────────────────────────────────────────

class _MeshChip extends StatelessWidget {
  final bool btOn;
  final bool meshActive;
  final AnimationController pulseCtrl;

  const _MeshChip({
    required this.btOn,
    required this.meshActive,
    required this.pulseCtrl,
  });

  @override
  Widget build(BuildContext context) {
    if (!btOn) {
      return Chip(
        label: const Text(
          'BT OFF',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
        ),
        backgroundColor: Colors.red.shade800.withAlpha(217),
        avatar:
            const Icon(Icons.bluetooth_disabled, color: Colors.white, size: 14),
        side: const BorderSide(color: Colors.white24),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );
    }

    if (!meshActive) {
      return Chip(
        label: const Text(
          'STARTING…',
          style: TextStyle(
              color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 11),
        ),
        backgroundColor: Colors.white.withAlpha(20),
        avatar: const Icon(Icons.cell_tower, color: Colors.white38, size: 14),
        side: const BorderSide(color: Colors.white12),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );
    }

    return AnimatedBuilder(
      animation: pulseCtrl,
      builder: (_, child) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4CAF50).withAlpha(
                (30 + 25 * pulseCtrl.value).round(),
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
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
        ),
        backgroundColor: const Color(0xFF2E7D32).withAlpha(217),
        avatar:
            const Icon(Icons.cell_tower, color: Colors.white, size: 14),
        side: const BorderSide(color: Colors.white24),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
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
              Container(
                height: 3,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: Colors.white.withAlpha(20),
                ),
              ),
              const SizedBox(height: 2),
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
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13),
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
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13)),
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
                ? 'Scanning for nearby Relay nodes…'
                : 'No alerts saved yet.',
            style: const TextStyle(color: Colors.white54, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            scanning
                ? 'This takes about 15 seconds.'
                : 'Tap \u25ba to scan for nearby Relay nodes,\nor open Settings to fetch from NWS.',
            style: const TextStyle(color: Colors.white30, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─── Alert card (swipe-to-reveal pin / delete) ────────────────────────────────

class _AlertCard extends StatefulWidget {
  final AlertPacket alert;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback onDelete;
  final bool isNewest;
  final int index;
  final ValueNotifier<String?> openSwipeId;

  const _AlertCard({
    super.key,
    required this.alert,
    required this.onTap,
    required this.onPin,
    required this.onDelete,
    required this.openSwipeId,
    this.isNewest = false,
    this.index = 0,
  });

  @override
  State<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends State<_AlertCard> with TickerProviderStateMixin {
  late final AnimationController _entranceCtrl;
  late final AnimationController _glowCtrl;
  late final AnimationController _swipeCtrl;
  bool _isPressed = false;

  // Swipe reveals 65px per action button.
  double get _revealWidth => widget.isNewest ? 65.0 : 130.0;

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
    _swipeCtrl = AnimationController(
      vsync: this,
      lowerBound: 0.0,
      upperBound: 1.0,
    );

    widget.openSwipeId.addListener(_onGlobalSwipeChange);

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
    widget.openSwipeId.removeListener(_onGlobalSwipeChange);
    _entranceCtrl.dispose();
    _glowCtrl.dispose();
    _swipeCtrl.dispose();
    super.dispose();
  }

  /// Called when any card changes swipe state — close this card if it's not the open one.
  void _onGlobalSwipeChange() {
    if (widget.openSwipeId.value != widget.alert.alertId &&
        _swipeCtrl.value > 0) {
      _swipeCtrl.animateTo(0.0,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _handleDragUpdate(DragUpdateDetails d) {
    if (d.primaryDelta == null) return;
    final delta = d.primaryDelta!;
    // Opening (swiping left): notify so other cards close
    if (delta < 0 && _swipeCtrl.value == 0) {
      widget.openSwipeId.value = widget.alert.alertId;
    }
    final newVal = (_swipeCtrl.value - delta / _revealWidth).clamp(0.0, 1.0);
    _swipeCtrl.value = newVal;
  }

  void _handleDragEnd(DragEndDetails d) {
    final velocity = d.velocity.pixelsPerSecond.dx;
    if (_swipeCtrl.value > 0.45 || velocity < -400) {
      _swipeCtrl.animateTo(1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut);
    } else {
      _closeSwipe();
    }
  }

  void _closeSwipe() {
    if (widget.openSwipeId.value == widget.alert.alertId) {
      widget.openSwipeId.value = null;
    }
    _swipeCtrl.animateTo(0.0,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void _handleTap() {
    if (_swipeCtrl.value > 0.05) {
      _closeSwipe();
    } else {
      widget.onTap();
    }
  }

  String _formatAge() {
    final sentAt = widget.alert.sentAt;
    if (sentAt != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(sentAt * 1000);
      return '${dt.month}/${dt.day} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    }
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
    final isVerified = alert.verified;
    final isDemo = _isDemo(alert);

    return FadeTransition(
      opacity: _entranceCtrl,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut)),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
            clipBehavior: Clip.none,
            children: [
              // ── Action buttons (revealed on swipe-left) ──────────────────
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      width: _revealWidth,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(18),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withAlpha(40)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _CircleActionButton(
                            icon: alert.pinned
                                ? Icons.push_pin_outlined
                                : Icons.push_pin,
                            color: Colors.white.withAlpha(40),
                            borderColor: Colors.white.withAlpha(80),
                            onTap: () {
                              _closeSwipe();
                              widget.onPin();
                            },
                          ),
                          if (!widget.isNewest)
                            _CircleActionButton(
                              icon: Icons.delete_outline_rounded,
                              color: Colors.red.shade800.withAlpha(200),
                              borderColor: Colors.red.shade300.withAlpha(100),
                              onTap: () {
                                _closeSwipe();
                                widget.onDelete();
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Swipeable card ────────────────────────────────────────────
              AnimatedBuilder(
                animation: _swipeCtrl,
                builder: (_, child) => Transform.translate(
                  offset: Offset(-_revealWidth * _swipeCtrl.value, 0),
                  child: child,
                ),
                child: GestureDetector(
                  onTapDown: (_) => setState(() => _isPressed = true),
                  onTapUp: (_) {
                    setState(() => _isPressed = false);
                    _handleTap();
                  },
                  onTapCancel: () => setState(() => _isPressed = false),
                  onHorizontalDragUpdate: _handleDragUpdate,
                  onHorizontalDragEnd: _handleDragEnd,
                  child: AnimatedScale(
                    scale: _isPressed ? 0.97 : 1.0,
                    duration: const Duration(milliseconds: 150),
                    child: AnimatedBuilder(
                      animation: _glowCtrl,
                      builder: (_, child) {
                        final glowAlpha =
                            (20 + 31 * _glowCtrl.value).round();
                        // Blend the semi-transparent tint over the opaque
                        // app background so the card is fully opaque and the
                        // action buttons behind can't bleed through.
                        final cardBg = Color.alphaBlend(
                          SeverityColors.tint(alert.severity),
                          const Color(0xFF0D0F1A),
                        );
                        return Container(
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color:
                                    SeverityColors.border(alert.severity)),
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
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      // Severity pill
                                      Container(
                                        padding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: color.withAlpha(40),
                                          borderRadius:
                                              BorderRadius.circular(20),
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
                                      // NWS tag
                                      if (isVerified) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1B5E20)
                                                .withAlpha(160),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            border: Border.all(
                                                color: const Color(
                                                        0xFF4CAF50)
                                                    .withAlpha(130),
                                                width: 0.5),
                                          ),
                                          child: const Text(
                                            'NWS',
                                            style: TextStyle(
                                              color: Color(0xFF81C784),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ),
                                      ],
                                      // DEMO tag (only for actual demo alerts)
                                      if (!isVerified && isDemo) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.white.withAlpha(12),
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
                                            size: 11,
                                            color: Colors.white54),
                                      ],
                                      const Spacer(),
                                      Text(
                                        _formatAge(),
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11),
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
            ],
          ),
          ), // ClipRRect
        ),
      ),
    );
  }
}

// ─── Circle action button (swipe reveal) ─────────────────────────────────────

class _CircleActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color? borderColor;
  final VoidCallback onTap;

  const _CircleActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: borderColor != null
              ? Border.all(color: borderColor!, width: 1)
              : null,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
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
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
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
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This action cannot be undone.',
                  style:
                      TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onCancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side:
                              const BorderSide(color: Colors.white24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
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
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
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
