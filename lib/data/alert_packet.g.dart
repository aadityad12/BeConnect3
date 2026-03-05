// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'alert_packet.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AlertPacket _$AlertPacketFromJson(Map<String, dynamic> json) => AlertPacket(
      alertId: json['alertId'] as String,
      severity: json['severity'] as String,
      headline: json['headline'] as String,
      expires: (json['expires'] as num).toInt(),
      instructions: json['instructions'] as String,
      sourceUrl: json['sourceUrl'] as String,
      verified: json['verified'] as bool,
      fetchedAt: (json['fetchedAt'] as num).toInt(),
      pinned: json['pinned'] as bool? ?? false,
      hopCount: (json['hopCount'] as num?)?.toInt() ?? 0,
      sentAt: (json['sentAt'] as num?)?.toInt(),
    );

Map<String, dynamic> _$AlertPacketToJson(AlertPacket instance) =>
    <String, dynamic>{
      'alertId': instance.alertId,
      'severity': instance.severity,
      'headline': instance.headline,
      'expires': instance.expires,
      'instructions': instance.instructions,
      'sourceUrl': instance.sourceUrl,
      'verified': instance.verified,
      'fetchedAt': instance.fetchedAt,
      'pinned': instance.pinned,
      'hopCount': instance.hopCount,
      'sentAt': instance.sentAt,
    };
