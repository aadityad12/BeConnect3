import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Dark-navy base layer with two warm gradient blobs.
///
/// Wrap every screen's Scaffold body in this widget so BackdropFilter
/// panels have real colour to blur against.
class GlassScaffold extends StatelessWidget {
  final Widget child;

  const GlassScaffold({super.key, required this.child});

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
          // Top-left warm blob
          const Positioned(
            top: -80,
            left: -60,
            child: _Blob(color: Color(0x33E64A19), size: 280),
          ),
          // Bottom-right crimson blob
          const Positioned(
            bottom: -60,
            right: -40,
            child: _Blob(color: Color(0x22B71C1C), size: 240),
          ),
          // Screen content
          child,
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
