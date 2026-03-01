import 'dart:convert';
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

    return AlertPacket.fromJson(
      jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
    );
  }
}
