import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Dark-navy base layer with two warm gradient blobs.
///
/// Wrap every screen's Scaffold body in this widget so BackdropFilter
/// panels have real colour to blur against.
class GlassScaffold extends StatefulWidget {
  final Widget child;

  const GlassScaffold({super.key, required this.child});

  @override
  State<GlassScaffold> createState() => _GlassScaffoldState();
}

class _GlassScaffoldState extends State<GlassScaffold>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl1;
  late final AnimationController _ctrl2;

  @override
  void initState() {
    super.initState();
    _ctrl1 = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 17),
    )..repeat(reverse: true);
    _ctrl2 = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 19),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl1.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Stack(
        children: [
          // Dark navy base
          Container(color: const Color(0xFF0D0F1A)),
          // Top-left warm blob (drifts gently)
          AnimatedBuilder(
            animation: _ctrl1,
            builder: (_, child) => Positioned(
              top: -80 + _ctrl1.value * 20,
              left: -60 + _ctrl1.value * 20,
              child: child!,
            ),
            child: const _Blob(color: Color(0x33E64A19), size: 280),
          ),
          // Bottom-right crimson blob (drifts gently)
          AnimatedBuilder(
            animation: _ctrl2,
            builder: (_, child) => Positioned(
              bottom: -60 + _ctrl2.value * 20,
              right: -40 + _ctrl2.value * 20,
              child: child!,
            ),
            child: const _Blob(color: Color(0x22B71C1C), size: 240),
          ),
          // Screen content
          widget.child,
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;

  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }
}
