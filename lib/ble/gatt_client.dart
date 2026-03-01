import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../ble_constants.dart';
import '../data/alert_packet.dart';
import 'chunk_utils.dart';

/// Downloads and reassembles an AlertPacket from a BeConnect GATT server.
class GattClient {
  /// Connects to [device], downloads all chunks, and returns the AlertPacket.
  ///
  /// Retries once on GATT error 133 (common on Android on first connect).
  static Future<AlertPacket> downloadAlert(BluetoothDevice device) async {
    await _connectWithRetry(device);
    try {
      return await _readAlert(device);
    } finally {
      await device.disconnect();
    }
  }

  static Future<void> _connectWithRetry(BluetoothDevice device) async {
    try {
      // mtu:512 automatically calls requestMtu on Android after connect
      await device.connect(mtu: 512, timeout: const Duration(seconds: 15));
    } catch (_) {
      // GATT 133 workaround: wait 600 ms and retry once
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await device.connect(mtu: 512, timeout: const Duration(seconds: 15));
    }
  }

  static Future<AlertPacket> _readAlert(BluetoothDevice device) async {
    final services = await device.discoverServices();

    final service = services.firstWhere(
      (s) => s.serviceUuid == Guid(serviceUuid),
      orElse: () => throw Exception('BeConnect service not found'),
    );

    final alertChar = service.characteristics.firstWhere(
      (c) => c.characteristicUuid == Guid(alertCharUuid),
      orElse: () => throw Exception('Alert characteristic not found'),
    );

    final controlChar = service.characteristics.firstWhere(
      (c) => c.characteristicUuid == Guid(controlCharUuid),
      orElse: () => throw Exception('Control characteristic not found'),
    );

    final chunks = <int, Uint8List>{};
    int totalChunks = -1;
    int idx = 0;

    do {
      // Tell the server which chunk we want
      await controlChar.write(
        [(idx >> 8) & 0xFF, idx & 0xFF],
        withoutResponse: false,
      );
      // Read the framed chunk
      final raw = await alertChar.read();
      final frame = ChunkUtils.decodeFrame(Uint8List.fromList(raw));
      totalChunks = frame.total;
      chunks[frame.index] = frame.payload;
      idx++;
    } while (idx < totalChunks);

    final data = ChunkUtils.reassemble(chunks, totalChunks);
    if (data == null) throw Exception('Chunk reassembly failed');

    // Auto-detect gzip (magic bytes 0x1f 0x8b = Flutter-sent compressed alert).
    // Pi sender transmits raw UTF-8 JSON which never starts with these bytes,
    // so this check gives full backward compatibility with no Pi changes.
    final Uint8List decoded;
    if (data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
      decoded = Uint8List.fromList(gzip.decode(data));
    } else {
      decoded = data;
    }

    final parsed = AlertPacket.fromJson(
      jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>,
    );

    // Each BLE relay hop adds 1. The originating device (Pi or NWS fetch)
    // starts at 0, so a direct Pi→phone receive lands at 1.
    return AlertPacket(
      alertId:      parsed.alertId,
      severity:     parsed.severity,
      headline:     parsed.headline,
      expires:      parsed.expires,
      instructions: parsed.instructions,
      sourceUrl:    parsed.sourceUrl,
      verified:     parsed.verified,
      fetchedAt:    parsed.fetchedAt,
      pinned:       parsed.pinned,
      hopCount:     parsed.hopCount + 1,
    );
  }
}
