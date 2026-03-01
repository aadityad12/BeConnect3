import 'package:flutter/material.dart';
import '../../data/alert_packet.dart';

class AlertDetailScreen extends StatelessWidget {
  final AlertPacket alert;

  const AlertDetailScreen({super.key, required this.alert});

  Color get _severityColor {
    switch (alert.severity) {
      case 'Extreme':  return Colors.red.shade700;
      case 'Severe':   return Colors.orange.shade700;
      case 'Moderate': return Colors.yellow.shade700;
      default:         return Colors.grey;
    }
  }

  String _formatExpiry() {
    final dt = DateTime.fromMillisecondsSinceEpoch(alert.expires * 1000);
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} local';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alert Details'),
        backgroundColor: _severityColor,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Severity banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: _severityColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        alert.severity.toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14),
                      ),
                      const Spacer(),
                      if (!alert.verified)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('DEMO',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 10)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Headline
            Text(
              alert.headline,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // Expires
            Row(
              children: [
                const Icon(Icons.schedule, size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  'Expires: ${_formatExpiry()}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
            const Divider(height: 32),

            // Instructions
            Text(
              'Instructions',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              alert.instructions,
              style: const TextStyle(fontSize: 15, height: 1.5),
            ),
            const Divider(height: 32),

            // Metadata
            _MetaRow(
              label: 'Source',
              value: alert.verified ? 'National Weather Service' : 'Demo Data',
            ),
            _MetaRow(
              label: 'Alert ID',
              value: alert.alertId,
            ),
            _MetaRow(
              label: 'Received via',
              value: 'Bluetooth LE',
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w500, color: Colors.grey)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
