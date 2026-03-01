// BLE UUIDs — must match exactly on gateway and receiver
const String serviceUuid = '0000BCBC-0000-1000-8000-00805F9B34FB';
const String alertCharUuid = '0000BCB1-0000-1000-8000-00805F9B34FB';
const String controlCharUuid = '0000BCB2-0000-1000-8000-00805F9B34FB';

const int manufacturerId = 0x1234;

/// Conservative chunk size used before MTU negotiation (pre-MTU payload = 17 bytes).
const int defaultChunkSize = 17;

/// Converts a severity string to the 1-byte value embedded in manufacturer data.
int severityToByte(String severity) {
  switch (severity) {
    case 'Extreme':  return 0;
    case 'Severe':   return 1;
    case 'Moderate': return 2;
    case 'Minor':    return 3;
    default:         return 4;
  }
}

/// Converts the 1-byte manufacturer data value back to a severity string.
String byteToSeverity(int byte) {
  switch (byte) {
    case 0: return 'Extreme';
    case 1: return 'Severe';
    case 2: return 'Moderate';
    case 3: return 'Minor';
    default: return 'Unknown';
  }
}
