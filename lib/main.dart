import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFE64A19),
          surface: const Color(0xFF0D0F1A),
          onSurface: Colors.white,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
          systemOverlayStyle: SystemUiOverlayStyle.light,
        ),
        dividerColor: Colors.white12,
      ),
      home: const HomeScreen(),
    );
  }
}
