import 'dart:ui';
import 'package:flutter/material.dart';
import '../../data/alert_packet.dart';
import '../theme/severity_colors.dart';
import '../widgets/glass_container.dart';
import '../widgets/glass_scaffold.dart';

class AlertDetailScreen extends StatelessWidget {
  final AlertPacket alert;

  const AlertDetailScreen({super.key, required this.alert});

  String _formatExpiry() {
    final dt = DateTime.fromMillisecondsSinceEpoch(alert.expires * 1000);
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} local';
  }

  @override
  Widget build(BuildContext context) {
    final color = SeverityColors.main(alert.severity);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: AppBar(
              title: const Text(
                'Alert Details',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              backgroundColor: Colors.white.withAlpha(20),
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
            ),
          ),
        ),
      ),
      body: GlassScaffold(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, kToolbarHeight + 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Severity banner
              GlassContainer(
                blur: true,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                tint: SeverityColors.tint(alert.severity),
                borderColor: SeverityColors.border(alert.severity),
                shadows: SeverityColors.hasGlow(alert.severity)
                    ? [
                        BoxShadow(
                          color: color.withAlpha(77),
                          blurRadius: 20,
                          spreadRadius: 2,
                        )
                      ]
                    : null,
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: color, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      alert.severity.toUpperCase(),
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 14),
                    ),
                    const Spacer(),
                    if (!alert.verified)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(20),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Text('DEMO',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 10)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Headline
              Text(
                alert.headline,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 10),

              // Expires
              Row(
                children: [
                  const Icon(Icons.schedule, size: 16, color: Colors.white60),
                  const SizedBox(width: 4),
                  Text(
                    'Expires: ${_formatExpiry()}',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ],
              ),
              const Divider(height: 32),

              // Instructions
              const Text(
                'Instructions',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
              const SizedBox(height: 10),
              Text(
                alert.instructions,
                style: const TextStyle(
                    color: Color(0xDEFFFFFF), fontSize: 15, height: 1.5),
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
                    fontWeight: FontWeight.w500, color: Colors.white54)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
