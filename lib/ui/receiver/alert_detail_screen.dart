import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../data/alert_packet.dart';
import '../theme/severity_colors.dart';
import '../widgets/glass_container.dart';
import '../widgets/glass_scaffold.dart';

class AlertDetailScreen extends StatefulWidget {
  final AlertPacket alert;

  const AlertDetailScreen({super.key, required this.alert});

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  late final FlutterTts _tts;
  bool _isSpeaking = false;

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    _tts = FlutterTts();
    await _tts.setLanguage('en-US');
    // Slightly slower than default for clarity during emergencies.
    await _tts.setSpeechRate(Platform.isIOS ? 0.45 : 0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  /// Builds the spoken string: severity + headline + instructions.
  String get _speechText =>
      '${widget.alert.severity} alert. ${widget.alert.headline}. '
      'Instructions: ${widget.alert.instructions}';

  Future<void> _toggleSpeech() async {
    if (_isSpeaking) {
      await _tts.stop();
    } else {
      await _tts.speak(_speechText);
    }
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  String _formatExpiry() {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(widget.alert.expires * 1000);
    return '${dt.month}/${dt.day} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')} local';
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
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
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              backgroundColor: Colors.white.withAlpha(20),
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                // Quick TTS toggle in the AppBar for one-tap access.
                IconButton(
                  icon: Icon(
                    _isSpeaking ? Icons.stop_circle_outlined : Icons.volume_up,
                    color: _isSpeaking ? color : Colors.white70,
                  ),
                  tooltip: _isSpeaking ? 'Stop reading' : 'Read aloud',
                  onPressed: _toggleSpeech,
                ),
              ],
            ),
          ),
        ),
      ),
      body: GlassScaffold(
        child: SingleChildScrollView(
          padding:
              const EdgeInsets.fromLTRB(16, kToolbarHeight + 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Severity banner
              GlassContainer(
                blur: true,
                padding: const EdgeInsets.symmetric(
                    vertical: 12, horizontal: 16),
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
                  const Icon(Icons.schedule,
                      size: 16, color: Colors.white60),
                  const SizedBox(width: 4),
                  Text(
                    'Expires: ${_formatExpiry()}',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Read Aloud button ──────────────────────────────────────
              _ReadAloudButton(
                isSpeaking: _isSpeaking,
                color: color,
                onTap: _toggleSpeech,
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

              // Hop count visualiser
              _HopCountRow(hopCount: alert.hopCount),
              const Divider(height: 32),

              // Metadata
              _MetaRow(
                label: 'Source',
                value: alert.verified
                    ? 'National Weather Service'
                    : 'Demo Data',
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

// ─── Read Aloud button ────────────────────────────────────────────────────────

class _ReadAloudButton extends StatelessWidget {
  final bool isSpeaking;
  final Color color;
  final VoidCallback onTap;

  const _ReadAloudButton({
    required this.isSpeaking,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: isSpeaking
              ? color.withAlpha(40)
              : Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSpeaking ? color.withAlpha(180) : Colors.white24,
            width: isSpeaking ? 1.5 : 1,
          ),
          boxShadow: isSpeaking
              ? [
                  BoxShadow(
                    color: color.withAlpha(40),
                    blurRadius: 12,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSpeaking ? Icons.stop_circle_outlined : Icons.volume_up,
              color: isSpeaking ? color : Colors.white70,
              size: 20,
            ),
            const SizedBox(width: 10),
            Text(
              isSpeaking ? 'Stop Reading' : 'Read Aloud',
              style: TextStyle(
                color: isSpeaking ? color : Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            if (isSpeaking) ...[
              const SizedBox(width: 12),
              _PulseDot(color: color),
            ],
          ],
        ),
      ),
    );
  }
}

/// Animated pulsing dot shown while TTS is active.
class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withAlpha((100 + 155 * _ctrl.value).round()),
        ),
      ),
    );
  }
}

// ─── Hop count visualiser ─────────────────────────────────────────────────────

class _HopCountRow extends StatelessWidget {
  final int hopCount;

  const _HopCountRow({required this.hopCount});

  @override
  Widget build(BuildContext context) {
    // Build a chain of nodes: origin → hop 1 → hop 2 → … → this device.
    // Cap the visual chain at 7 nodes so it always fits on screen.
    final totalNodes = hopCount + 1;
    final displayNodes = totalNodes.clamp(1, 7);
    final truncated = totalNodes > 7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Relay Path',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (int i = 0; i < displayNodes; i++) ...[
              _HopNode(
                isOrigin: i == 0,
                isCurrent: i == displayNodes - 1 && !truncated,
                isOverflow: truncated && i == displayNodes - 1,
                overflowCount: truncated ? totalNodes - 6 : 0,
              ),
              if (i < displayNodes - 1)
                Expanded(
                  child: Container(
                    height: 1.5,
                    color: Colors.white24,
                  ),
                ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          hopCount == 0
              ? 'Fetched directly — not relayed.'
              : hopCount == 1
                  ? 'Received directly from the source beacon (1 hop).'
                  : 'Relayed through $hopCount devices before reaching you.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

class _HopNode extends StatelessWidget {
  final bool isOrigin;
  final bool isCurrent;
  final bool isOverflow;
  final int overflowCount;

  const _HopNode({
    required this.isOrigin,
    required this.isCurrent,
    required this.isOverflow,
    required this.overflowCount,
  });

  @override
  Widget build(BuildContext context) {
    if (isOverflow) {
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withAlpha(20),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: Text(
            '+$overflowCount',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    final Color nodeColor;
    final IconData icon;
    if (isOrigin) {
      nodeColor = const Color(0xFF4CAF50);
      icon = Icons.cell_tower;
    } else if (isCurrent) {
      nodeColor = const Color(0xFF42A5F5);
      icon = Icons.smartphone;
    } else {
      nodeColor = Colors.white38;
      icon = Icons.bluetooth;
    }

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: nodeColor.withAlpha(30),
        border: Border.all(color: nodeColor, width: 1.5),
      ),
      child: Icon(icon, size: 14, color: nodeColor),
    );
  }
}

// ─── Metadata row ─────────────────────────────────────────────────────────────

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
                    fontWeight: FontWeight.w500,
                    color: Colors.white54)),
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
