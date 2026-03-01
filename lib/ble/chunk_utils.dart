import 'dart:math';
import 'dart:typed_data';

/// Handles chunking and reassembly of large byte payloads for GATT transfer.
///
/// Frame format: [chunkIndex: 2 bytes BE][totalChunks: 2 bytes BE][payload: N bytes]
class ChunkUtils {
  /// Payload bytes per chunk after MTU negotiation (512 MTU − 4 header bytes).
  static const int postMtuPayloadSize = 508;

  /// Splits [data] into framed chunks of at most [payloadSize] payload bytes each.
  static List<Uint8List> encode(
    Uint8List data, {
    int payloadSize = postMtuPayloadSize,
  }) {
    final total = (data.length / payloadSize).ceil().clamp(1, 65535);
    return List.generate(total, (i) {
      final start = i * payloadSize;
      final end = min(start + payloadSize, data.length);
      final payload = data.sublist(start, end);
      final frame = BytesBuilder()
        ..addByte((i >> 8) & 0xFF)
        ..addByte(i & 0xFF)
        ..addByte((total >> 8) & 0xFF)
        ..addByte(total & 0xFF)
        ..add(payload);
      return frame.toBytes();
    });
  }

  /// Decodes a framed chunk into its index, total count, and raw payload.
  static ({int index, int total, Uint8List payload}) decodeFrame(
      Uint8List frame) {
    assert(frame.length >= 4, 'Frame must be at least 4 bytes');
    final index = (frame[0] << 8) | frame[1];
    final total = (frame[2] << 8) | frame[3];
    final payload = frame.sublist(4);
    return (index: index, total: total, payload: payload);
  }

  /// Reassembles ordered chunks into the original bytes.
  /// Returns null if any chunk in [0, totalChunks) is missing.
  static Uint8List? reassemble(Map<int, Uint8List> chunks, int totalChunks) {
    if (chunks.length < totalChunks) return null;
    final builder = BytesBuilder();
    for (int i = 0; i < totalChunks; i++) {
      final chunk = chunks[i];
      if (chunk == null) return null;
      builder.add(chunk);
    }
    return builder.toBytes();
  }
}
