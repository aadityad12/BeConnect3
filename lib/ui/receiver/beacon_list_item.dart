import 'package:flutter/material.dart';
import '../../ble/ble_scanner.dart';

class BeaconListItem extends StatelessWidget {
  final BeaconInfo beacon;
  final VoidCallback onTap;

  const BeaconListItem({super.key, required this.beacon, required this.onTap});

  Color get _severityColor {
    switch (beacon.severity) {
      case 'Extreme':  return Colors.red.shade700;
      case 'Severe':   return Colors.orange.shade700;
      case 'Moderate': return Colors.yellow.shade700;
      default:         return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: _severityColor,
          child: const Icon(Icons.cell_tower, color: Colors.white, size: 20),
        ),
        title: Text(
          beacon.deviceName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _severityColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                beacon.severity.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.signal_cellular_alt,
                size: 14, color: Colors.grey.shade600),
            Text(' ${beacon.rssi} dBm',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ],
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 14),
      ),
    );
  }
}
