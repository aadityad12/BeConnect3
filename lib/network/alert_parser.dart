import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../data/alert_packet.dart';

class AlertParser {
  static const _severities = {'Extreme', 'Severe', 'Moderate', 'Minor'};

  /// Parses a NWS GeoJSON response body into a list of AlertPackets.
  /// Filters to Extreme/Severe/Moderate/Minor severity only.
  static List<AlertPacket> parseGeoJson(String jsonStr) {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final features = data['features'] as List<dynamic>;

    return features
        .where((f) {
          final props = f['properties'] as Map<String, dynamic>;
          final severity = props['severity'] as String? ?? '';
          return _severities.contains(severity);
        })
        .map((f) => _fromProperties(f['properties'] as Map<String, dynamic>))
        .toList();
  }

  static AlertPacket _fromProperties(Map<String, dynamic> props) {
    final headline = props['headline'] as String? ?? '';
    final expiresStr = props['expires'] as String? ?? '';
    final expires = expiresStr.isNotEmpty
        ? DateTime.parse(expiresStr).millisecondsSinceEpoch ~/ 1000
        : 0;
    final sentStr = props['sent'] as String?;
    final sentAt = sentStr != null && sentStr.isNotEmpty
        ? DateTime.parse(sentStr).toUtc().millisecondsSinceEpoch ~/ 1000
        : null;
    final sourceUrl = props['@id'] as String? ?? '';
    final instructions =
        props['instruction'] as String? ?? 'No specific instructions.';
    final severity = props['severity'] as String? ?? 'Unknown';

    // alertId = first 8 hex chars of SHA-1(headline + expires)
    final digest = sha1.convert(utf8.encode('$headline$expires'));
    final alertId = digest.toString().substring(0, 8);

    return AlertPacket(
      alertId:      alertId,
      severity:     severity,
      headline:     headline,
      expires:      expires,
      instructions: instructions,
      sourceUrl:    sourceUrl,
      verified:     true,
      fetchedAt:    DateTime.now().millisecondsSinceEpoch ~/ 1000,
      sentAt:       sentAt,
    );
  }
}
