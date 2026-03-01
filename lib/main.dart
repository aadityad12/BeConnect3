import 'package:flutter/material.dart';
import 'ui/mode_select_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
      home: const ModeSelectScreen(),
    );
  }
}
