import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widgets/glass_container.dart';

class SettingsScreen extends StatefulWidget {
  /// Called when the user taps "Download NWS Alerts" — runs in HomeScreen context.
  final VoidCallback? onFetchNws;

  /// Called when the user taps "Load Demo Alerts" — runs in HomeScreen context.
  final VoidCallback? onLoadDemo;

  const SettingsScreen({
    super.key,
    this.onFetchNws,
    this.onLoadDemo,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _prefKey = 'selected_states';

  // All 50 US states: code → name
  static const _states = {
    'AL': 'Alabama', 'AK': 'Alaska', 'AZ': 'Arizona', 'AR': 'Arkansas',
    'CA': 'California', 'CO': 'Colorado', 'CT': 'Connecticut', 'DE': 'Delaware',
    'FL': 'Florida', 'GA': 'Georgia', 'HI': 'Hawaii', 'ID': 'Idaho',
    'IL': 'Illinois', 'IN': 'Indiana', 'IA': 'Iowa', 'KS': 'Kansas',
    'KY': 'Kentucky', 'LA': 'Louisiana', 'ME': 'Maine', 'MD': 'Maryland',
    'MA': 'Massachusetts', 'MI': 'Michigan', 'MN': 'Minnesota', 'MS': 'Mississippi',
    'MO': 'Missouri', 'MT': 'Montana', 'NE': 'Nebraska', 'NV': 'Nevada',
    'NH': 'New Hampshire', 'NJ': 'New Jersey', 'NM': 'New Mexico', 'NY': 'New York',
    'NC': 'North Carolina', 'ND': 'North Dakota', 'OH': 'Ohio', 'OK': 'Oklahoma',
    'OR': 'Oregon', 'PA': 'Pennsylvania', 'RI': 'Rhode Island', 'SC': 'South Carolina',
    'SD': 'South Dakota', 'TN': 'Tennessee', 'TX': 'Texas', 'UT': 'Utah',
    'VT': 'Vermont', 'VA': 'Virginia', 'WA': 'Washington', 'WV': 'West Virginia',
    'WI': 'Wisconsin', 'WY': 'Wyoming',
  };

  Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<String>();
      if (mounted) setState(() => _selected = list.toSet());
    }
  }

  Future<void> _toggle(String code) async {
    setState(() {
      if (_selected.contains(code)) {
        _selected.remove(code);
      } else {
        _selected.add(code);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_selected.toList()));
  }

  Future<void> _clearAll() async {
    setState(() => _selected.clear());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode([]));
  }

  @override
  Widget build(BuildContext context) {
    final sortedCodes = _states.keys.toList()..sort();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: AppBar(
              title: const Text(
                'Settings',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              backgroundColor: Colors.white.withAlpha(20),
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D0F1A), Color(0xFF1A1040), Color(0xFF0D0F1A)],
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              // ── Data section ──────────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: _SectionHeader(
                    icon: Icons.cloud_outlined,
                    label: 'Data Sources',
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GlassContainer(
                    blur: true,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // NWS button
                        _DataButton(
                          icon: Icons.cloud_download_outlined,
                          label: 'Download NWS Alerts',
                          subtitle: 'Fetch live alerts from the National Weather Service',
                          color: const Color(0xFF1565C0),
                          onTap: widget.onFetchNws == null
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  widget.onFetchNws!();
                                },
                        ),
                        const SizedBox(height: 10),
                        // Demo button
                        _DataButton(
                          icon: Icons.science_outlined,
                          label: 'Load Demo Alerts',
                          subtitle: 'Inject sample alerts for testing without a Relay',
                          color: const Color(0xFF4A148C),
                          onTap: widget.onLoadDemo == null
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  widget.onLoadDemo!();
                                },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // ── State filter section ──────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: _SectionHeader(
                    icon: Icons.location_on_outlined,
                    label: 'NWS State Filter',
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GlassContainer(
                    blur: true,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            color: Colors.white38, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _selected.isEmpty
                                ? 'No states selected — fetching alerts for all states.'
                                : '${_selected.length} state${_selected.length == 1 ? '' : 's'} selected for NWS filtering.',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 13),
                          ),
                        ),
                        if (_selected.isNotEmpty)
                          GestureDetector(
                            onTap: _clearAll,
                            child: const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Text('Clear',
                                  style: TextStyle(
                                      color: Color(0xFFE64A19),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // State list
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final code = sortedCodes[i];
                      final name = _states[code]!;
                      final checked = _selected.contains(code);
                      final isFirst = i == 0;
                      final isLast = i == sortedCodes.length - 1;

                      return _StateTile(
                        code: code,
                        name: name,
                        checked: checked,
                        isFirst: isFirst,
                        isLast: isLast,
                        onTap: () => _toggle(code),
                      );
                    },
                    childCount: sortedCodes.length,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 15),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

// ─── Data source button ───────────────────────────────────────────────────────

class _DataButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _DataButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withAlpha(40),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(100)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withAlpha(60),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white70, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: color.withAlpha(180), size: 18),
          ],
        ),
      ),
    );
  }
}

// ─── State tile ───────────────────────────────────────────────────────────────

class _StateTile extends StatelessWidget {
  final String code;
  final String name;
  final bool checked;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  const _StateTile({
    required this.code,
    required this.name,
    required this.checked,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(
          bottom: isLast ? 0 : 1,
        ),
        decoration: BoxDecoration(
          color: checked
              ? const Color(0xFFE64A19).withAlpha(25)
              : Colors.white.withAlpha(8),
          borderRadius: BorderRadius.only(
            topLeft: isFirst ? const Radius.circular(12) : Radius.zero,
            topRight: isFirst ? const Radius.circular(12) : Radius.zero,
            bottomLeft: isLast ? const Radius.circular(12) : Radius.zero,
            bottomRight: isLast ? const Radius.circular(12) : Radius.zero,
          ),
          border: Border.all(
            color: checked
                ? const Color(0xFFE64A19).withAlpha(80)
                : Colors.white.withAlpha(15),
            width: 0.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // Custom checkbox
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: checked
                      ? const Color(0xFFE64A19)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: checked
                        ? const Color(0xFFE64A19)
                        : Colors.white24,
                    width: 1.5,
                  ),
                ),
                child: checked
                    ? const Icon(Icons.check, size: 13, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: checked ? Colors.white : Colors.white70,
                    fontSize: 14,
                    fontWeight:
                        checked ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
              Text(
                code,
                style: TextStyle(
                  color: checked
                      ? const Color(0xFFE64A19).withAlpha(200)
                      : Colors.white24,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loads the saved state codes from SharedPreferences.
/// Returns empty list if none saved (= fetch all states).
Future<List<String>> loadSelectedStates() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('selected_states');
  if (raw == null) return [];
  return (jsonDecode(raw) as List).cast<String>();
}
