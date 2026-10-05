import 'package:flutter/material.dart';

class VentraColors {
  // Monolithic Remote Chassis Colors
  static const Color background = Color(0xFF0D0E12);
  static const Color surface = Color(0xFF14161E);
  static const Color surfaceElevated = Color(0xFF1A1D27);
  static const Color debossed = Color(0xFF090A0D);

  // Borders
  static const Color borderSubtle = Color(0x1AFFFFFF);
  static const Color borderHighlight = Color(0x3300E5FF);

  // Backlight & Mode Colors
  static const Color cool = Color(0xFF00E5FF);
  static const Color heat = Color(0xFFFF5722);
  static const Color dry = Color(0xFFD500F9);
  static const Color fan = Color(0xFF00E676);
  static const Color auto = Color(0xFFFFFFFF);

  // Status & Brand Accent
  static const Color accent = Color(0xFF00E5FF);
  static const Color online = Color(0xFF00E676);
  static const Color offline = Color(0xFFFF5252);
  static const Color warning = Color(0xFFFFB300);

  // Typography
  static const Color textPrimary = Color(0xFFF0F2F8);
  static const Color textSecondary = Color(0xFF9E9EB2);
  static const Color textMuted = Color(0xFF5A6075);

  static Color forMode(String mode) {
    switch (mode.toLowerCase()) {
      case 'cool': return cool;
      case 'heat': return heat;
      case 'dry':  return dry;
      case 'fan':  return fan;
      case 'auto': return auto;
      default:     return cool;
    }
  }

  static IconData iconForMode(String mode) {
    switch (mode.toLowerCase()) {
      case 'cool': return Icons.ac_unit_rounded;
      case 'heat': return Icons.wb_sunny_rounded;
      case 'dry':  return Icons.water_drop_rounded;
      case 'fan':  return Icons.air_rounded;
      case 'auto': return Icons.hdr_auto_rounded;
      default:     return Icons.ac_unit_rounded;
    }
  }
}

class VentraTheme {
  static BoxDecoration remoteCard({Color? activeColor, bool isPressed = false}) {
    return BoxDecoration(
      color: activeColor != null
          ? activeColor.withValues(alpha: 0.12)
          : VentraColors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: activeColor != null
            ? activeColor.withValues(alpha: 0.45)
            : Colors.white.withValues(alpha: 0.07),
        width: 1.2,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          offset: const Offset(0, 4),
          blurRadius: 10,
        ),
        if (activeColor != null)
          BoxShadow(
            color: activeColor.withValues(alpha: 0.15),
            blurRadius: 16,
            spreadRadius: 1,
          ),
      ],
    );
  }
}
