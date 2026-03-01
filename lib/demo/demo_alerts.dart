import '../data/alert_packet.dart';

/// Hardcoded fallback alerts used when no network is available.
/// verified = false because these are not from NWS.
final List<AlertPacket> demoAlerts = [
  AlertPacket(
    alertId:      'demo0001',
    severity:     'Extreme',
    headline:     'Tornado Warning issued for Demo County',
    expires:      DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
    instructions: 'Take shelter immediately in an interior room on the lowest floor of a sturdy building. '
        'Avoid windows. Do not attempt to outrun a tornado in a vehicle.',
    sourceUrl:    'https://www.weather.gov/demo',
    verified:     false,
    fetchedAt:    DateTime.now().millisecondsSinceEpoch ~/ 1000,
  ),
  AlertPacket(
    alertId:      'demo0002',
    severity:     'Severe',
    headline:     'Flash Flood Warning in effect until 8 PM',
    expires:      DateTime.now().add(const Duration(hours: 4)).millisecondsSinceEpoch ~/ 1000,
    instructions: 'Turn around, don\'t drown. Never walk, swim, or drive through flood waters. '
        'Stay off bridges over fast-moving water.',
    sourceUrl:    'https://www.weather.gov/demo',
    verified:     false,
    fetchedAt:    DateTime.now().millisecondsSinceEpoch ~/ 1000,
  ),
];
