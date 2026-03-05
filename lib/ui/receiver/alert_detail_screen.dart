import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../data/alert_packet.dart';
import '../../services/translation_service.dart';
import '../theme/severity_colors.dart';
import '../widgets/glass_container.dart';
import '../widgets/glass_scaffold.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

bool _isDemo(AlertPacket a) =>
    a.alertId.startsWith('demo') || a.sourceUrl.contains('weather.gov/demo');

// ─── Language choice ──────────────────────────────────────────────────────────

class _LangChoice {
  final String label;
  final String? langCode;   // null = original (no translation)
  final String ttsBcp47;    // BCP-47 locale for flutter_tts

  const _LangChoice(this.label, this.langCode, this.ttsBcp47);
}

const _languages = [
  _LangChoice('Original (English)', null, 'en-US'),
  _LangChoice('Arabic', 'ar', 'ar-SA'),
  _LangChoice('Chinese (Simplified)', 'zh', 'zh-CN'),
  _LangChoice('Dutch', 'nl', 'nl-NL'),
  _LangChoice('French', 'fr', 'fr-FR'),
  _LangChoice('German', 'de', 'de-DE'),
  _LangChoice('Greek', 'el', 'el-GR'),
  _LangChoice('Hebrew', 'he', 'he-IL'),
  _LangChoice('Hindi', 'hi', 'hi-IN'),
  _LangChoice('Indonesian', 'id', 'id-ID'),
  _LangChoice('Italian', 'it', 'it-IT'),
  _LangChoice('Japanese', 'ja', 'ja-JP'),
  _LangChoice('Korean', 'ko', 'ko-KR'),
  _LangChoice('Norwegian', 'nb', 'nb-NO'),
  _LangChoice('Polish', 'pl', 'pl-PL'),
  _LangChoice('Portuguese', 'pt', 'pt-BR'),
  _LangChoice('Russian', 'ru', 'ru-RU'),
  _LangChoice('Spanish', 'es', 'es-ES'),
  _LangChoice('Swedish', 'sv', 'sv-SE'),
  _LangChoice('Thai', 'th', 'th-TH'),
  _LangChoice('Turkish', 'tr', 'tr-TR'),
  _LangChoice('Ukrainian', 'uk', 'uk-UA'),
  _LangChoice('Vietnamese', 'vi', 'vi-VN'),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class AlertDetailScreen extends StatefulWidget {
  final AlertPacket alert;

  const AlertDetailScreen({super.key, required this.alert});

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  late final FlutterTts _tts;
  bool _isSpeaking = false;

  _LangChoice _selectedLang = _languages.first;
  bool _translating = false;
  String? _translatedText;
  // null = still loading, empty = none downloaded
  List<_LangChoice>? _availableLanguages;

  @override
  void initState() {
    super.initState();
    _initTts();
    _loadAvailableLanguages();
  }

  Future<void> _loadAvailableLanguages() async {
    final downloaded = await TranslationService.getDownloadedLanguages();
    final filtered = [
      _languages.first, // always include "Original"
      ..._languages.where((l) => l.langCode != null && downloaded.contains(l.langCode)),
    ];
    if (mounted) {
      setState(() {
        _availableLanguages = filtered;
        // Reset to "Original" if current selection is no longer available
        if (!filtered.contains(_selectedLang)) {
          _selectedLang = filtered.first;
          _translatedText = null;
        }
      });
    }
  }

  Future<void> _initTts() async {
    _tts = FlutterTts();
    await _tts.setLanguage('en-US');
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

  String get _displayText => _translatedText ?? widget.alert.instructions;

  String get _speechText =>
      '${widget.alert.severity} alert. ${widget.alert.headline}. '
      'Instructions: $_displayText';

  Future<void> _onLanguageChanged(_LangChoice choice) async {
    if (_isSpeaking) await _tts.stop();
    setState(() {
      _selectedLang = choice;
      _translatedText = null;
    });

    if (choice.langCode == null) return;

    setState(() => _translating = true);
    try {
      final translated = await TranslationService.translate(
        widget.alert.instructions,
        choice.langCode!,
      );
      if (mounted) setState(() => _translatedText = translated);
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message ?? 'Translation failed'),
            backgroundColor: Colors.red.shade800,
          ),
        );
        setState(() => _selectedLang = _languages.first);
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  Future<void> _toggleSpeech() async {
    if (_isSpeaking) {
      await _tts.stop();
    } else {
      await _tts.setLanguage(_selectedLang.ttsBcp47);
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

  String? _formatSentAt() {
    final sentAt = widget.alert.sentAt;
    if (sentAt == null) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(sentAt * 1000);
    return '${dt.month}/${dt.day} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')} local';
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final color = SeverityColors.main(alert.severity);
    final issuedStr = _formatSentAt();

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
                    if (alert.verified)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1B5E20).withAlpha(180),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF4CAF50).withAlpha(150)),
                        ),
                        child: const Text('NWS',
                            style: TextStyle(
                                color: Color(0xFF81C784), fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      )
                    else if (_isDemo(alert))
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
              const SizedBox(height: 6),

              // Language dropdown
              _LanguageDropdown(
                selected: _selectedLang,
                languages: _availableLanguages,
                translating: _translating,
                onChanged: _onLanguageChanged,
              ),
              const SizedBox(height: 12),

              // Read Aloud button
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
              if (_translating)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: CircularProgressIndicator(
                        color: Colors.white54, strokeWidth: 2),
                  ),
                )
              else
                Text(
                  _displayText,
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
                    : _isDemo(alert)
                        ? 'Demo Data'
                        : 'Echo Mesh (BLE Relay)',
              ),
              if (issuedStr != null)
                _MetaRow(label: 'Issued', value: issuedStr),
              _MetaRow(
                label: 'Alert ID',
                value: alert.alertId,
              ),
              _MetaRow(
                label: 'Delivered via',
                value: 'Echo Mesh (BLE)',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Language picker (glass bottom sheet) ────────────────────────────────────

class _LanguageDropdown extends StatelessWidget {
  final _LangChoice selected;
  /// null while loading; list of available (downloaded) choices once ready.
  final List<_LangChoice>? languages;
  final bool translating;
  final ValueChanged<_LangChoice> onChanged;

  const _LanguageDropdown({
    required this.selected,
    required this.languages,
    required this.translating,
    required this.onChanged,
  });

  void _openPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _LanguagePickerSheet(
        selected: selected,
        languages: languages!,
        onChanged: (l) {
          Navigator.pop(context);
          onChanged(l);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Still checking what's downloaded
    if (languages == null) {
      return _GlassRow(
        child: const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  color: Colors.white38, strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Loading languages…',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );
    }

    // Only "Original" available — no languages downloaded yet
    if (languages!.length <= 1) {
      return _GlassRow(
        child: const Row(
          children: [
            Icon(Icons.language, color: Colors.white24, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'No translation languages downloaded.\nAdd them in Settings → General → Language & Region → Translation Languages.',
                style: TextStyle(
                    color: Colors.white38, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    final isOriginal = selected.langCode == null;

    return GestureDetector(
      onTap: translating ? null : () => _openPicker(context),
      child: _GlassRow(
        child: Row(
          children: [
            translating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        color: Colors.white54, strokeWidth: 2),
                  )
                : Icon(
                    isOriginal
                        ? Icons.language_outlined
                        : Icons.translate,
                    color: isOriginal ? Colors.white38 : Colors.white70,
                    size: 18,
                  ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                translating ? 'Translating…' : selected.label,
                style: TextStyle(
                  color: translating
                      ? Colors.white38
                      : isOriginal
                          ? Colors.white54
                          : Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
            if (!translating)
              const Icon(Icons.expand_more,
                  color: Colors.white38, size: 18),
          ],
        ),
      ),
    );
  }
}

class _GlassRow extends StatelessWidget {
  final Widget child;
  const _GlassRow({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(38)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LanguagePickerSheet extends StatelessWidget {
  final _LangChoice selected;
  final List<_LangChoice> languages;
  final ValueChanged<_LangChoice> onChanged;

  const _LanguagePickerSheet({
    required this.selected,
    required this.languages,
    required this.onChanged,
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
                const SizedBox(height: 14),
                const Text(
                  'Translate To',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 10),
                const Divider(color: Colors.white12, height: 1),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.55,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: languages.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (_, i) {
                      final lang = languages[i];
                      final isSelected = lang.langCode == selected.langCode;
                      return InkWell(
                        onTap: () => onChanged(lang),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 14),
                          child: Row(
                            children: [
                              Icon(
                                lang.langCode == null
                                    ? Icons.language_outlined
                                    : Icons.translate,
                                size: 18,
                                color: isSelected
                                    ? const Color(0xFFE64A19)
                                    : Colors.white38,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  lang.label,
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white70,
                                    fontSize: 15,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check,
                                    color: Color(0xFFE64A19), size: 18),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
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
    final totalNodes = hopCount + 1;
    final displayNodes = totalNodes.clamp(1, 7);
    final truncated = totalNodes > 7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Echo Path',
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
              ? 'Received directly from a Relay node (0 echoes).'
              : hopCount == 1
                  ? 'Echoed once — 1 Echo device relayed this to you.'
                  : 'Echoed $hopCount times through nearby Echo devices.',
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
