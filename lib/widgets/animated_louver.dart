import 'package:flutter/material.dart';
import 'dart:math' as math;

class AnimatedLouver extends StatefulWidget {
  final int swingVMode;
  final Color accentColor;

  const AnimatedLouver({
    super.key,
    required this.swingVMode,
    required this.accentColor,
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
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _angleAnimation = Tween<double>(begin: 20.0, end: 20.0).animate(_animController);
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant AnimatedLouver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.swingVMode != widget.swingVMode) _updateAnimation();
  }

  void _updateAnimation() {
    double tMin;
    double tMax;
    switch (widget.swingVMode) {
      case 2: tMin = -10; tMax = -10; break;
      case 3: tMin = 5; tMax = 5; break;
      case 4: tMin = 20; tMax = 20; break;
      case 5: tMin = 35; tMax = 35; break;
      case 6: tMin = 50; tMax = 50; break;
      case 1: tMin = -10; tMax = 50; break;
      case 11: tMin = -10; tMax = 20; break;
      case 9: tMin = 5; tMax = 35; break;
      case 7: tMin = 20; tMax = 50; break;
      default: tMin = 20; tMax = 20; break;
    }
    _animController.stop();
    if (tMin == tMax) {
      _animController.duration = const Duration(milliseconds: 600);
      _angleAnimation = Tween<double>(begin: _angleAnimation.value, end: tMin).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
      _animController.forward(from: 0.0);
    } else {
      _animController.duration = const Duration(milliseconds: 1500);
      _angleAnimation = Tween<double>(begin: tMin, end: tMax).animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOutSine));
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
        width: 50,
        height: 38,
        decoration: BoxDecoration(
          color: widget.swingVMode != 0 ? widget.accentColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: widget.swingVMode != 0 ? widget.accentColor.withValues(alpha: 0.5) : Colors.white12),
        ),
        child: CustomPaint(
          painter: SideProfileLouverPainter(
            angleInDegrees: _angleAnimation.value,
            color: widget.swingVMode != 0 ? widget.accentColor : Colors.white38,
          ),
        ),
      ),
    );
  }
}

class SideProfileLouverPainter extends CustomPainter {
  final double angleInDegrees;
  final Color color;

  SideProfileLouverPainter({required this.angleInDegrees, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        Offset(size.width * 0.15, 6),
        Offset(size.width * 0.15, size.height - 6),
        Paint()
          ..color = color.withValues(alpha: 0.3)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    final pivot = Offset(size.width * 0.15, size.height * 0.25);
    final flapLength = size.width * 0.65;
    double radians = angleInDegrees * (math.pi / 180);
    canvas.drawLine(pivot, Offset(pivot.dx + math.cos(radians) * flapLength, pivot.dy + math.sin(radians) * flapLength), paint);
    canvas.drawCircle(pivot, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant SideProfileLouverPainter oldDelegate) => oldDelegate.angleInDegrees != angleInDegrees;
}
