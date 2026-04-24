import 'package:flutter/material.dart';
import 'dart:math' as math;

class EndlessWheelPainter extends CustomPainter {
  final double rotation;
  final Color accentColor;
  final bool isOverscrolling;

  EndlessWheelPainter({
    required this.rotation,
    required this.accentColor,
    required this.isOverscrolling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    canvas.drawCircle(
        center,
        radius - 24,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.02)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 24);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.translate(-center.dx, -center.dy);
    final tickPaint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 30; i++) {
      final tickAngle = (i / 30) * 2 * math.pi;
      final isMajor = i % 5 == 0;
      tickPaint.color = Colors.white.withValues(alpha: isMajor ? 0.3 : 0.1);
      canvas.drawLine(
          Offset(center.dx + (radius - 50) * math.cos(tickAngle), center.dy + (radius - 50) * math.sin(tickAngle)),
          Offset(center.dx + (radius - 50 - (isMajor ? 16.0 : 8.0)) * math.cos(tickAngle),
              center.dy + (radius - 50 - (isMajor ? 16.0 : 8.0)) * math.sin(tickAngle)),
          tickPaint);
    }
    canvas.restore();

    final indicatorColor = isOverscrolling ? accentColor : Colors.white;
    final topOuter = Offset(center.dx, center.dy - radius + 46);
    canvas.drawLine(
        Offset(center.dx, center.dy - radius + 14),
        topOuter,
        Paint()
          ..color = indicatorColor
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 4);
    if (isOverscrolling) {
      canvas.drawCircle(
          topOuter,
          10,
          Paint()
            ..color = accentColor.withValues(alpha: 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    }
    canvas.drawCircle(topOuter, 5, Paint()..color = indicatorColor);
  }

  @override
  bool shouldRepaint(covariant EndlessWheelPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.isOverscrolling != isOverscrolling;
}
