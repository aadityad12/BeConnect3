import 'dart:ui';
import 'package:flutter/material.dart';

/// A frosted-glass container widget.
///
/// Set [blur] to false for items inside list builders to avoid jank —
/// glass colour + border still gives the glass aesthetic without
/// the BackdropFilter performance cost.
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final BorderRadius borderRadius;
  final Color? tint;        // background fill — default: white 8%
  final Color? borderColor; // border colour  — default: white 15%
  final List<BoxShadow>? shadows;
  final bool blur;          // false disables BackdropFilter

  const GlassContainer({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.tint,
    this.borderColor,
    this.shadows,
    this.blur = true,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: tint ?? Colors.white.withAlpha(20),          // ~8%
        borderRadius: borderRadius,
        border: Border.all(
          color: borderColor ?? Colors.white.withAlpha(38), // ~15%
        ),
        boxShadow: shadows,
      ),
      child: child,
    );

    if (!blur) return box;

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: box,
      ),
    );
  }
}
