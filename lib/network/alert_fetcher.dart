import 'package:http/http.dart' as http;
import 'alert_parser.dart';
import '../data/alert_packet.dart';

class AlertFetcher {
  static const _url =
      'https://api.weather.gov/alerts/active'
      '?status=actual&message_type=alert';

  /// Fetches active NWS alerts and returns parsed AlertPackets.
  /// Throws on network error or non-200 status.
  Future<List<AlertPacket>> fetchAlerts() async {
    final response = await http
        .get(
          Uri.parse(_url),
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
