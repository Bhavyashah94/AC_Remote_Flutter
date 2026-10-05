import 'package:flutter/material.dart';
import 'dart:math' as math;

class AnimatedLouver extends StatefulWidget {
  final int swingVMode;
  final Color accentColor;
  final String protocol;

  const AnimatedLouver({
    super.key,
    required this.swingVMode,
    required this.accentColor,
    this.protocol = 'Panasonic',
  });

  @override
  State<AnimatedLouver> createState() => _AnimatedLouverState();
}

class _AnimatedLouverState extends State<AnimatedLouver> with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _angleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    _angleAnimation = Tween<double>(begin: 36.0, end: 36.0).animate(_animController);
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant AnimatedLouver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.swingVMode != widget.swingVMode || oldWidget.protocol != widget.protocol) {
      _updateAnimation();
    }
  }

  void _updateAnimation() {
    double tMin;
    double tMax;
    bool isAuto = false;

    if (widget.protocol.toLowerCase().contains('panasonic') || widget.swingVMode == 0xF) {
      switch (widget.swingVMode) {
        case 0xF: // Auto (oscillate)
          tMin = 5.0;
          tMax = 58.0;
          isAuto = true;
          break;
        case 1: // Highest (near horizontal)
          tMin = 5.0;
          tMax = 5.0;
          break;
        case 2: // High
          tMin = 18.0;
          tMax = 18.0;
          break;
        case 3: // Mid
          tMin = 32.0;
          tMax = 32.0;
          break;
        case 4: // Low
          tMin = 45.0;
          tMax = 45.0;
          break;
        case 5: // Lowest (steep downward)
          tMin = 58.0;
          tMax = 58.0;
          break;
        default:
          tMin = 32.0;
          tMax = 32.0;
          break;
      }
    } else {
      // Gree Protocol mapping
      switch (widget.swingVMode) {
        case 1:
          tMin = 5.0;
          tMax = 58.0;
          isAuto = true;
          break;
        case 2:
          tMin = 5.0;
          tMax = 5.0;
          break;
        case 3:
          tMin = 18.0;
          tMax = 18.0;
          break;
        case 4:
          tMin = 32.0;
          tMax = 32.0;
          break;
        case 5:
          tMin = 45.0;
          tMax = 45.0;
          break;
        case 6:
          tMin = 58.0;
          tMax = 58.0;
          break;
        case 7:
          tMin = 35.0;
          tMax = 58.0;
          isAuto = true;
          break;
        case 9:
          tMin = 18.0;
          tMax = 45.0;
          isAuto = true;
          break;
        case 11:
          tMin = 5.0;
          tMax = 32.0;
          isAuto = true;
          break;
        default:
          tMin = 18.0;
          tMax = 18.0;
          break;
      }
    }

    _animController.stop();

    if (!isAuto && tMin == tMax) {
      _animController.duration = const Duration(milliseconds: 350);
      _angleAnimation = Tween<double>(
        begin: _angleAnimation.value,
        end: tMin,
      ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
      _animController.forward(from: 0.0);
    } else {
      _animController.duration = const Duration(milliseconds: 1400);
      _angleAnimation = Tween<double>(
        begin: tMin,
        end: tMax,
      ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOutSine));
      _animController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _angleAnimation,
      builder: (context, child) => Container(
        width: 64,
        height: 42,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF14161F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.accentColor.withValues(alpha: 0.25),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: widget.accentColor.withValues(alpha: 0.08),
              blurRadius: 8,
              spreadRadius: 0,
            ),
          ],
        ),
        child: CustomPaint(
          painter: SideProfileLouverPainter(
            angleInDegrees: _angleAnimation.value,
            color: widget.accentColor,
            isAuto: widget.swingVMode == 0xF || (widget.protocol == 'Gree' && widget.swingVMode == 1),
          ),
        ),
      ),
    );
  }
}

class SideProfileLouverPainter extends CustomPainter {
  final double angleInDegrees;
  final Color color;
  final bool isAuto;

  SideProfileLouverPainter({
    required this.angleInDegrees,
    required this.color,
    this.isAuto = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Wall behind the AC unit (subtle guideline)
    final wallPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(6, 6), Offset(6, size.height - 6), wallPaint);

    // 2. Indoor AC Unit Casing (Wall-mounted split cross-section)
    final casingPaint = Paint()
      ..color = color.withValues(alpha: 0.32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final casingPath = Path()
      // Top mount on wall
      ..moveTo(9, 9)
      ..lineTo(21, 9)
      // Top-front curve
      ..arcToPoint(const Offset(24, 13), radius: const Radius.circular(4))
      // Front face
      ..lineTo(22, 17)
      // Vent inlet recess
      ..arcToPoint(const Offset(18, 17), radius: const Radius.circular(3))
      // Bottom of unit back to wall
      ..moveTo(16, 23)
      ..lineTo(11, 28)
      ..lineTo(9, 28);

    canvas.drawPath(casingPath, casingPaint);

    // 3. Louver Pivot & Blade
    final pivot = const Offset(18, 18);
    final flapLength = 15.0;
    final radians = angleInDegrees * (math.pi / 180.0);

    final flapEnd = Offset(
      pivot.dx + math.cos(radians) * flapLength,
      pivot.dy + math.sin(radians) * flapLength,
    );

    // Blade glow
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    canvas.drawLine(pivot, flapEnd, glowPaint);

    // Sharp blade
    final bladePaint = Paint()
      ..color = color
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pivot, flapEnd, bladePaint);

    // Pivot pin dot
    canvas.drawCircle(pivot, 2.0, Paint()..color = color);

    // 4. Airflow Streamlines (Emanating gently from behind the vane into the room)
    final streamPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5;

    // Stream 1 (Upper stream)
    final s1Alpha = isAuto ? 0.5 : 0.4;
    streamPaint.color = color.withValues(alpha: s1Alpha);
    final s1Start = Offset(
      pivot.dx + math.cos(radians) * 7.0,
      pivot.dy + math.sin(radians) * 7.0 + 2.5,
    );
    final s1Ctrl = Offset(
      s1Start.dx + math.cos(radians) * 8.0,
      s1Start.dy + math.sin(radians) * 8.0,
    );
    final s1End = Offset(
      (s1Ctrl.dx + 12.0).clamp(0.0, size.width - 8.0),
      (s1Ctrl.dy + math.sin(radians) * 3.0).clamp(0.0, size.height - 6.0),
    );
    final s1Path = Path()
      ..moveTo(s1Start.dx, s1Start.dy)
      ..quadraticBezierTo(s1Ctrl.dx, s1Ctrl.dy, s1End.dx, s1End.dy);
    canvas.drawPath(s1Path, streamPaint);

    // Stream 2 (Lower stream)
    final s2Alpha = isAuto ? 0.35 : 0.25;
    streamPaint.color = color.withValues(alpha: s2Alpha);
    final s2Start = Offset(
      pivot.dx + math.cos(radians) * 11.0,
      pivot.dy + math.sin(radians) * 11.0 + 3.0,
    );
    final s2Ctrl = Offset(
      s2Start.dx + math.cos(radians) * 7.0,
      s2Start.dy + math.sin(radians) * 7.0,
    );
    final s2End = Offset(
      (s2Ctrl.dx + 10.0).clamp(0.0, size.width - 7.0),
      (s2Ctrl.dy + math.sin(radians) * 3.0).clamp(0.0, size.height - 5.0),
    );
    final s2Path = Path()
      ..moveTo(s2Start.dx, s2Start.dy)
      ..quadraticBezierTo(s2Ctrl.dx, s2Ctrl.dy, s2End.dx, s2End.dy);
    canvas.drawPath(s2Path, streamPaint);
  }

  @override
  bool shouldRepaint(covariant SideProfileLouverPainter oldDelegate) =>
      oldDelegate.angleInDegrees != angleInDegrees ||
      oldDelegate.color != color ||
      oldDelegate.isAuto != isAuto;
}
