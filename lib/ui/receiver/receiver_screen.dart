import 'package:flutter/material.dart';
import '../../ble/ble_scanner.dart';
import '../../ble/gatt_client.dart';
import '../../data/alert_dao.dart';
import '../../data/alert_packet.dart';
import 'alert_detail_screen.dart';
import 'beacon_list_item.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  bool _scanning = false;
  String? _status;
  final _dao = AlertDao();

  @override
  void dispose() {
    BleScanner.stopScan();
    super.dispose();
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await BleScanner.stopScan();
      setState(() { _scanning = false; _status = 'Scan stopped.'; });
    } else {
      setState(() { _scanning = true; _status = 'Scanning for gateways…'; });
      try {
        await BleScanner.startScan();
        await Future<void>.delayed(const Duration(seconds: 30));
        if (mounted && _scanning) {
          setState(() { _scanning = false; _status = 'Scan complete.'; });
        }
      } catch (e) {
        if (mounted) {
          setState(() { _scanning = false; _status = 'Could not start scan: $e'; });
        }
      }
    }
  }

  Future<void> _connectAndDownload(BeaconInfo beacon) async {
    setState(() => _status = 'Connecting to ${beacon.deviceName}…');
    await BleScanner.stopScan();
    setState(() => _scanning = false);

    try {
      final alert = await GattClient.downloadAlert(beacon.device);
      await _dao.insert(alert);
      setState(() => _status = 'Alert received!');
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AlertDetailScreen(alert: alert),
          ),
        );
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _viewSavedAlerts() async {
    final alerts = await _dao.fetchAll();
    if (!mounted) return;
    if (alerts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No saved alerts yet.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SavedAlertsScreen(alerts: alerts),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receiver Mode'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Saved alerts',
            onPressed: _viewSavedAlerts,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _toggleScan,
              icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
              label: Text(_scanning ? 'Stop Scan' : 'Start Scan'),
              style: FilledButton.styleFrom(
                backgroundColor: _scanning ? Colors.red : Colors.indigo,
              ),
            ),

            if (_status != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_scanning) ...[
                    const SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(_status!, style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ],

            const SizedBox(height: 16),

            Expanded(
              child: StreamBuilder<List<BeaconInfo>>(
                stream: BleScanner.beaconsStream,
                builder: (context, snapshot) {
                  final beacons = snapshot.data ?? [];

                  if (beacons.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bluetooth_searching,
                              size: 64,
                              color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text(
                            _scanning
                                ? 'Looking for BeConnect gateways…'
                                : 'Tap "Start Scan" to find nearby gateways.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${beacons.length} gateway(s) found',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: beacons.length,
                          itemBuilder: (_, i) => BeaconListItem(
                            beacon: beacons[i],
                            onTap: () => _connectAndDownload(beacons[i]),
                          ),
                        ),
                      ),
                    ],
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

// ─── Saved alerts sub-screen ─────────────────────────────────────────────────

class _SavedAlertsScreen extends StatelessWidget {
  final List<AlertPacket> alerts;

  const _SavedAlertsScreen({required this.alerts});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Saved Alerts (${alerts.length})'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: alerts.length,
        itemBuilder: (_, i) {
          final a = alerts[i];
          return ListTile(
            leading: const Icon(Icons.warning_amber_rounded),
            title: Text(a.headline, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(a.severity),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AlertDetailScreen(alert: a),
              ),
            ),
          );
        },
      ),
    );
  }
}
