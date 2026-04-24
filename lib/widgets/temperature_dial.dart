import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'endless_wheel_painter.dart';

class TemperatureDial extends StatefulWidget {
  final int value;
  final int minTemp;
  final int maxTemp;
  final Color accentColor;
  final ValueChanged<int> onChanged;
  final VoidCallback onInteractionEnd;

  const TemperatureDial({
    super.key,
    required this.value,
    required this.minTemp,
    required this.maxTemp,
    required this.accentColor,
    required this.onChanged,
    required this.onInteractionEnd,
  });

  @override
  State<TemperatureDial> createState() => _TemperatureDialState();
}

class _TemperatureDialState extends State<TemperatureDial> with TickerProviderStateMixin {
  late AnimationController _snapController;
  Animation<double>? _snapAnimation;
  late AnimationController _inertiaController;
  Animation<double>? _inertiaAnimation;

  final double _radsPerTick = 12.0 * math.pi / 180.0;

  double _wheelRotation = 0.0;
  double _overscroll = 0.0;
  double _lastAngle = 0.0;
  double _dragStartRotation = 0.0;
  double _dragStartTemp = 24.0;

  Offset _lastTouchPosition = Offset.zero;
  bool _isDragging = false;
  late double _currentTemp;

  @override
  void initState() {
    super.initState();
    _currentTemp = widget.value.toDouble();
    _snapController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _inertiaController = AnimationController(vsync: this);

    _inertiaController.addListener(() {
      if (_inertiaAnimation == null) return;
      setState(() {
        _wheelRotation = _inertiaAnimation!.value;
        double exactTemp = _dragStartTemp + ((_wheelRotation - _dragStartRotation) / _radsPerTick);
        int newTempInt = exactTemp.round().clamp(widget.minTemp, widget.maxTemp);

        if (newTempInt != _currentTemp.toInt()) {
          HapticFeedback.lightImpact();
          _currentTemp = newTempInt.toDouble();
          widget.onChanged(newTempInt);
        }
      });
    });

    _inertiaController.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onInteractionEnd();
    });
  }

  @override
  void didUpdateWidget(TemperatureDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_isDragging && !_inertiaController.isAnimating) {
      setState(() => _currentTemp = widget.value.toDouble());
    }
  }

  @override
  void dispose() {
    _snapController.dispose();
    _inertiaController.dispose();
    super.dispose();
  }

  void _updateOverscroll() {
    if (_snapAnimation != null && mounted) setState(() => _wheelRotation = _snapAnimation!.value);
  }

  void _onPanStart(DragStartDetails details) {
    _isDragging = true;
    _snapController.stop();
    _inertiaController.stop();
    _snapAnimation?.removeListener(_updateOverscroll);

    const center = Offset(180, 180);
    _lastTouchPosition = details.localPosition;
    _lastAngle = math.atan2(_lastTouchPosition.dy - center.dy, _lastTouchPosition.dx - center.dx);
    _dragStartRotation = _wheelRotation;
    _dragStartTemp = _currentTemp;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    const center = Offset(180, 180);
    _lastTouchPosition = details.localPosition;
    final currentAngle = math.atan2(_lastTouchPosition.dy - center.dy, _lastTouchPosition.dx - center.dx);

    double deltaAngle = currentAngle - _lastAngle;
    while (deltaAngle > math.pi) deltaAngle -= 2 * math.pi;
    while (deltaAngle < -math.pi) deltaAngle += 2 * math.pi;
    _lastAngle = currentAngle;

    setState(() {
      _wheelRotation += deltaAngle;
      double exactTemp = _dragStartTemp + ((_wheelRotation - _dragStartRotation) / _radsPerTick);

      if (exactTemp > widget.maxTemp) {
        _overscroll = (exactTemp - widget.maxTemp) * _radsPerTick;
        _currentTemp = widget.maxTemp.toDouble();
      } else if (exactTemp < widget.minTemp) {
        _overscroll = (exactTemp - widget.minTemp) * _radsPerTick;
        _currentTemp = widget.minTemp.toDouble();
      } else {
        _overscroll = 0;
        int newTempInt = exactTemp.round();
        if (newTempInt != _currentTemp.toInt()) {
          HapticFeedback.lightImpact();
          _currentTemp = newTempInt.toDouble();
          widget.onChanged(newTempInt);
        }
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _isDragging = false;
    if (_overscroll != 0) {
      double targetRotation = _dragStartRotation + ((_currentTemp - _dragStartTemp) * _radsPerTick);
      _snapAnimation = Tween<double>(begin: _wheelRotation, end: targetRotation).animate(CurvedAnimation(parent: _snapController, curve: Curves.elasticOut));
      _snapAnimation!.addListener(_updateOverscroll);
      _snapController.forward(from: 0.0);
      widget.onInteractionEnd();
    } else {
      double rx = _lastTouchPosition.dx - 180; double ry = _lastTouchPosition.dy - 180;
      double vx = details.velocity.pixelsPerSecond.dx; double vy = details.velocity.pixelsPerSecond.dy;
      double r2 = rx * rx + ry * ry;

      if (r2 > 0) {
        double angularVelocity = (rx * vy - ry * vx) / r2;
        if (angularVelocity.abs() > 1.5) {
          int ticksToSpin = (angularVelocity * 1.5).round();
          double targetTemp = (_currentTemp + ticksToSpin).clamp(widget.minTemp.toDouble(), widget.maxTemp.toDouble());
          double targetRotation = _dragStartRotation + ((targetTemp - _dragStartTemp) * _radsPerTick);

          _inertiaAnimation = Tween<double>(begin: _wheelRotation, end: targetRotation).animate(CurvedAnimation(parent: _inertiaController, curve: Curves.easeOutCubic));
          _inertiaController.duration = Duration(milliseconds: 600 + (ticksToSpin.abs() * 50));
          _inertiaController.forward(from: 0.0);
        } else {
          double targetRotation = _dragStartRotation + ((_currentTemp - _dragStartTemp) * _radsPerTick);
          _snapAnimation = Tween<double>(begin: _wheelRotation, end: targetRotation).animate(CurvedAnimation(parent: _snapController, curve: Curves.easeOutBack));
          _snapAnimation!.addListener(_updateOverscroll);
          _snapController.forward(from: 0.0);
          widget.onInteractionEnd();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(duration: const Duration(milliseconds: 500), width: 300, height: 300, decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: widget.accentColor.withValues(alpha: 0.12), blurRadius: 80, spreadRadius: 15)])),
          Text('${_currentTemp.toInt()}', style: TextStyle(fontSize: 110, fontWeight: FontWeight.w200, color: _overscroll != 0 ? widget.accentColor : Colors.white, height: 1.0)),
          GestureDetector(
            behavior: HitTestBehavior.opaque, onPanStart: _onPanStart, onPanUpdate: _onPanUpdate, onPanEnd: _onPanEnd,
            child: SizedBox(
              width: 360, height: 360,
              child: CustomPaint(painter: EndlessWheelPainter(rotation: _wheelRotation, accentColor: widget.accentColor, isOverscrolling: _overscroll != 0)),
            ),
          ),
        ],
      ),
    );
  }
}