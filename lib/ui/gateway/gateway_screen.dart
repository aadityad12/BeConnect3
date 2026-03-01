import 'package:flutter/material.dart';
import '../../data/alert_packet.dart';
import '../../demo/demo_alerts.dart';
import '../../network/alert_fetcher.dart';
import '../../service/gateway_background_service.dart';

class GatewayScreen extends StatefulWidget {
  const GatewayScreen({super.key});

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  List<AlertPacket> _alerts = [];
  AlertPacket? _broadcasting;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    // Stop broadcasting when leaving the screen
    if (_broadcasting != null) {
      GatewayBackgroundService.stop();
    }
    super.dispose();
  }

  Future<void> _fetchAlerts() async {
    setState(() { _loading = true; _error = null; });
    try {
      final alerts = await AlertFetcher().fetchAlerts();
      setState(() => _alerts = alerts);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  void _loadDemo() {
    setState(() { _alerts = demoAlerts; _error = null; });
  }

  Future<void> _startBroadcast(AlertPacket alert) async {
    if (_broadcasting != null) await _stopBroadcast();
    try {
      await GatewayBackgroundService.start(alert);
      setState(() => _broadcasting = alert);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Broadcast failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _stopBroadcast() async {
    await GatewayBackgroundService.stop();
    setState(() => _broadcasting = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gateway Mode'),
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
        actions: [
          if (_broadcasting != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: const Text('LIVE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                backgroundColor: Colors.red,
                avatar: const Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
              ),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Action buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _fetchAlerts,
                    icon: _loading
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.cloud_download),
                    label: const Text('Fetch NWS Alerts'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loadDemo,
                  icon: const Icon(Icons.science),
                  label: const Text('Demo'),
                ),
              ],
            ),

            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            ],

            if (_broadcasting != null) ...[
              const SizedBox(height: 12),
              _BroadcastBanner(
                alert: _broadcasting!,
                onStop: _stopBroadcast,
              ),
            ],

            const SizedBox(height: 16),
            Text('${_alerts.length} alert(s)',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),

            Expanded(
              child: _alerts.isEmpty
                  ? const Center(
                      child: Text(
                        'No alerts loaded.\nTap "Fetch NWS Alerts" or "Demo".',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _alerts.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final a = _alerts[i];
                        final isBroadcasting = _broadcasting?.alertId == a.alertId;
                        return _AlertTile(
                          alert: a,
                          isBroadcasting: isBroadcasting,
                          onBroadcast: isBroadcasting
                              ? _stopBroadcast
                              : () => _startBroadcast(a),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BroadcastBanner extends StatelessWidget {
  final AlertPacket alert;
  final VoidCallback onStop;

  const _BroadcastBanner({required this.alert, required this.onStop});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.shade700,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.cell_tower, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Broadcasting: ${alert.headline}',
              style: const TextStyle(color: Colors.white),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onStop,
            child: const Text('STOP', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  final AlertPacket alert;
  final bool isBroadcasting;
  final VoidCallback onBroadcast;

  const _AlertTile({
    required this.alert,
    required this.isBroadcasting,
    required this.onBroadcast,
  });

  Color get _severityColor {
    switch (alert.severity) {
      case 'Extreme':  return Colors.red.shade700;
      case 'Severe':   return Colors.orange.shade700;
      case 'Moderate': return Colors.yellow.shade700;
      default:         return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: isBroadcasting ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isBroadcasting
            ? const BorderSide(color: Colors.green, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _severityColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    alert.severity.toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                if (!alert.verified)
                  const Text('DEMO', style: TextStyle(color: Colors.grey, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 6),
            Text(alert.headline,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onBroadcast,
                icon: Icon(isBroadcasting ? Icons.stop : Icons.broadcast_on_personal),
                label: Text(isBroadcasting ? 'Stop Broadcasting' : 'Broadcast This Alert'),
                style: FilledButton.styleFrom(
                  backgroundColor: isBroadcasting ? Colors.red : Colors.green.shade700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
