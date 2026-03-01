import 'package:json_annotation/json_annotation.dart';

part 'alert_packet.g.dart';

@JsonSerializable()
class AlertPacket {
  final String alertId;     // first 8 chars of SHA-1(headline+expires)
  final String severity;    // "Extreme"|"Severe"|"Moderate"|"Minor"|"Unknown"
  final String headline;
  final int expires;         // Unix epoch seconds
  final String instructions;
  final String sourceUrl;
  final bool verified;       // true only if fetched from NWS
  final int fetchedAt;       // Unix epoch seconds

  const AlertPacket({
    required this.alertId,
    required this.severity,
    required this.headline,
    required this.expires,
    required this.instructions,
    required this.sourceUrl,
    required this.verified,
    required this.fetchedAt,
  });

  factory AlertPacket.fromJson(Map<String, dynamic> json) =>
      _$AlertPacketFromJson(json);

  Map<String, dynamic> toJson() => _$AlertPacketToJson(this);
}
