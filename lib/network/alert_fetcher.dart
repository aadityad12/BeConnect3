import 'package:http/http.dart' as http;
import 'alert_parser.dart';
import '../data/alert_packet.dart';

class AlertFetcher {
  static const _baseUrl =
      'https://api.weather.gov/alerts/active'
      '?status=actual&message_type=alert';

  /// Fetches active NWS alerts and returns parsed AlertPackets.
  /// Pass [states] (e.g. ['CA', 'TX']) to filter by area; empty = all states.
  /// Throws on network error or non-200 status.
  Future<List<AlertPacket>> fetchAlerts({List<String> states = const []}) async {
    final url = states.isEmpty
        ? _baseUrl
        : '$_baseUrl&area=${states.join(',')}';
    final response = await http
        .get(
          Uri.parse(url),
          headers: {
            'Accept': 'application/geo+json',
            'User-Agent': 'BeConnect/1.0 (hackathon@beconnect.app)',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('NWS API returned ${response.statusCode}');
    }

    return AlertParser.parseGeoJson(response.body);
  }
}
