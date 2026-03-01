import 'package:flutter/material.dart';

class SeverityColors {
  static const extreme  = Color(0xFFB71C1C); // deep crimson
  static const severe   = Color(0xFFE64A19); // deep orange-red
  static const moderate = Color(0xFFFF8F00); // amber
  static const _muted   = Color(0xFF546E7A); // slate (minor/unknown)

  static Color main(String severity) {
    switch (severity) {
      case 'Extreme':  return extreme;
      case 'Severe':   return severe;
      case 'Moderate': return moderate;
      default:         return _muted;
    }
  }

  static Color tint(String severity)   => main(severity).withAlpha(31);  // ~12%
  static Color border(String severity) => main(severity).withAlpha(102); // ~40%
  static bool  hasGlow(String severity) =>
      severity == 'Extreme' || severity == 'Severe';
}
