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

/// Fade + 4% slide-up page transition applied to both Android and iOS.
class _FadeSlideTransitionBuilder extends PageTransitionsBuilder {
  const _FadeSlideTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOut)).animate(animation),
        child: child,
      ),
    );
  }
}

class BeConnectApp extends StatelessWidget {
  const BeConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RE3',
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
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _FadeSlideTransitionBuilder(),
            TargetPlatform.iOS: _FadeSlideTransitionBuilder(),
          },
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
