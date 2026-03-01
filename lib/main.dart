import 'package:flutter/material.dart';
import 'service/gateway_background_service.dart';
import 'ui/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Configure (but do not start) the background mesh service before runApp.
  // The service is started by HomeScreen after permissions are granted.
  await GatewayBackgroundService.init();
  runApp(const BeConnectApp());
}

class BeConnectApp extends StatelessWidget {
  const BeConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BeConnect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
