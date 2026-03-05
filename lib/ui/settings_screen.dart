import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

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
      setState(() => _selected = list.toSet());
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
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              backgroundColor: Colors.white.withAlpha(20),
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                if (_selected.isNotEmpty)
                  TextButton(
                    onPressed: _clearAll,
                    child: const Text('Clear all',
                        style: TextStyle(color: Colors.white70)),
                  ),
              ],
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
          child: Column(
            children: [
              // Header hint
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: Colors.white38, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _selected.isEmpty
                              ? 'No states selected — fetching alerts for all states.'
                              : '${_selected.length} state${_selected.length == 1 ? '' : 's'} selected.',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // State list
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: sortedCodes.length,
                  itemBuilder: (_, i) {
                    final code = sortedCodes[i];
                    final name = _states[code]!;
                    final checked = _selected.contains(code);
                    return CheckboxListTile(
                      value: checked,
                      onChanged: (_) => _toggle(code),
                      title: Text(
                        name,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        code,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                      checkColor: Colors.white,
                      activeColor: const Color(0xFFE64A19),
                      side: const BorderSide(color: Colors.white24),
                    );
                  },
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
