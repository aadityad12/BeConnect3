import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/permissions.dart';
import 'gateway/gateway_screen.dart';
import 'receiver/receiver_screen.dart';

class ModeSelectScreen extends StatefulWidget {
  const ModeSelectScreen({super.key});

  @override
  State<ModeSelectScreen> createState() => _ModeSelectScreenState();
}

class _ModeSelectScreenState extends State<ModeSelectScreen> {
  bool _permissionsGranted = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    setState(() => _checking = true);
    final granted = await hasBlePermissions();
    if (mounted) {
      setState(() {
        _permissionsGranted = granted;
        _checking = false;
      });
    }
  }

  void _initPermissions() async {
    setState(() => _checking = true);
    await requestBlePermissions();
    final granted = await hasBlePermissions();
    final permanentlyDenied = await hasPermanentlyDeniedBlePermission();
    if (mounted) {
      setState(() {
        _permissionsGranted = granted;
        _checking = false;
      });
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              permanentlyDenied
                  ? 'Bluetooth permission is blocked. Enable it in iOS Settings.'
                  : 'Bluetooth permission is still not granted.',
            ),
            action: permanentlyDenied
                ? SnackBarAction(
                    label: 'Open Settings',
                    onPressed: openAppSettings,
                  )
                : null,
          ),
        );
      }
    }
  }

  void _goGateway() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const GatewayScreen()),
      );

  void _goReceiver() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ReceiverScreen()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(Icons.broadcast_on_personal, size: 80, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('BeConnect', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_checking)
                const Center(child: CircularProgressIndicator())
              else if (!_permissionsGranted) ...[
                const Text('Permissions required for BLE features.', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _initPermissions, child: const Text('Check Permissions')),
              ],
              const SizedBox(height: 16),
              _ModeButton(icon: Icons.cell_tower, label: 'Gateway Mode', subtitle: 'Fetch alerts & broadcast', color: Colors.deepOrange, onTap: _goGateway),
              const SizedBox(height: 16),
              _ModeButton(icon: Icons.bluetooth_searching, label: 'Receiver Mode', subtitle: 'Scan for gateways', color: Colors.indigo, onTap: _goReceiver),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon; final String label; final String subtitle; final Color color; final VoidCallback onTap;
  const _ModeButton({required this.icon, required this.label, required this.subtitle, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(color: color, borderRadius: BorderRadius.circular(16), child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24), child: Row(children: [Icon(icon, color: Colors.white, size: 36), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)), Text(subtitle, style: TextStyle(color: Colors.white.withAlpha(200)))]))],))));
  }
}
