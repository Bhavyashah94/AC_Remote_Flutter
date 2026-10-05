import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/temperature_dial.dart';
import '../widgets/animated_louver.dart';

class GreeView extends StatefulWidget {
  final Map<String, dynamic> stateData;
  final Function(Map<String, dynamic>) onCommand;

  const GreeView({super.key, required this.stateData, required this.onCommand});

  @override
  State<GreeView> createState() => _GreeViewState();
}

class _GreeViewState extends State<GreeView> {
  late int _temperature;
  late String _mode;
  late String _fanSpeed;
  late int _swingVMode;
  late int _swingHMode;
  late bool _isTurboOn;
  late bool _isSleepOn;
  late bool _isIFeelOn;
  late bool _isXFanOn;
  late bool _isLightOn;
  late int _displayMode;
  late bool _isSmartAutoOn;

  final Map<String, Map<String, dynamic>> _modes = {
    'Cool': {'icon': Icons.ac_unit_rounded, 'color': const Color(0xFF00E5FF)},
    'Heat': {'icon': Icons.wb_sunny_rounded, 'color': const Color(0xFFFF3D00)},
    'Dry': {'icon': Icons.water_drop_rounded, 'color': const Color(0xFFD500F9)},
    'Fan': {'icon': Icons.air_rounded, 'color': const Color(0xFF00E676)},
    'Auto': {'icon': Icons.hdr_auto_rounded, 'color': const Color(0xFFFFFFFF)},
  };

  final List<String> _fanSpeeds = ['Auto', 'Low', 'Med', 'High'];
  final List<String> _displayLabels = ['Off', 'Set Temp', 'Inside Temp', 'Outside Temp'];

  final List<Map<String, dynamic>> _swingVOptions = [
    {'val': 0, 'label': 'Off'},
    {'val': 1, 'label': 'Full Auto'},
    {'val': 2, 'label': 'Up'},
    {'val': 3, 'label': 'Mid-Up'},
    {'val': 4, 'label': 'Mid'},
    {'val': 5, 'label': 'Mid-Down'},
    {'val': 6, 'label': 'Down'},
    {'val': 7, 'label': 'Sweep Down'},
    {'val': 9, 'label': 'Sweep Mid'},
    {'val': 11, 'label': 'Sweep Up'},
  ];

  final List<Map<String, dynamic>> _swingHOptions = [
    {'val': 0, 'label': 'Off'},
    {'val': 1, 'label': 'Full Auto'},
    {'val': 2, 'label': 'Max Left'},
    {'val': 3, 'label': 'Left'},
    {'val': 4, 'label': 'Center'},
    {'val': 5, 'label': 'Right'},
    {'val': 6, 'label': 'Max Right'},
  ];

  Color get _accentColor => _modes[_mode]?['color'] ?? Colors.white;

  @override
  void initState() {
    super.initState();
    _syncState();
  }

  @override
  void didUpdateWidget(GreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(oldWidget.stateData, widget.stateData)) {
      _syncState();
    }
  }

  void _syncState() {
    _temperature = (widget.stateData['temp'] ?? 24).toInt();
    _mode = widget.stateData['mode'] ?? 'Cool';
    _fanSpeed = widget.stateData['fan'] ?? 'Auto';
    _swingVMode = widget.stateData['swing_v'] ?? 0;
    _swingHMode = widget.stateData['swing_h'] ?? 0;
    _isTurboOn = widget.stateData['turbo'] ?? false;
    _isSleepOn = widget.stateData['sleep'] ?? false;
    _isIFeelOn = widget.stateData['ifeel'] ?? false;
    _isXFanOn = widget.stateData['x_fan'] ?? false;
    _isLightOn = widget.stateData['light'] ?? (widget.stateData['display'] != 0);
    _displayMode = widget.stateData['display_temp'] ?? widget.stateData['display'] ?? 1;
    _isSmartAutoOn = widget.stateData['smart_auto'] ?? false;
  }

  void _pushCommand() {
    widget.onCommand({
      "protocol": "Gree",
      "smart_auto": _isSmartAutoOn,
      "temp": _temperature,
      "mode": _mode,
      "fan": _fanSpeed,
      "swing_v": _swingVMode,
      "swing_h": _swingHMode,
      "turbo": _isTurboOn,
      "sleep": _isSleepOn,
      "ifeel": _isIFeelOn,
      "x_fan": _isXFanOn,
      "light": _isLightOn,
      "display": _isLightOn ? 1 : 0,
      "display_temp": _displayMode,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TemperatureDial(
          value: _temperature,
          minTemp: 16,
          maxTemp: 30,
          accentColor: _accentColor,
          onChanged: (val) {
            setState(() => _temperature = val);
          },
          onInteractionEnd: _pushCommand,
        ),
        const SizedBox(height: 56),
        _buildSectionTitle('Mode'),
        _buildModeSelector(),
        const SizedBox(height: 32),
        _buildSectionTitle('Fan Speed'),
        _buildFanSpeedSelector(),
        const SizedBox(height: 32),
        _buildSwingControls(),
        const SizedBox(height: 32),
        _buildFeatureDecks(),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.white54,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return SizedBox(
      height: 90,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        clipBehavior: Clip.none,
        children: _modes.keys.map((mode) {
          bool isActive = _mode == mode;
          Color modeColor = _modes[mode]!['color'] as Color;
          return Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _mode = mode);
                _pushCommand();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 85,
                decoration: BoxDecoration(
                  color: isActive ? modeColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isActive ? modeColor.withValues(alpha: 0.5) : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _modes[mode]!['icon'] as IconData,
                      color: isActive ? modeColor : Colors.white54,
                      size: 28,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      mode,
                      style: TextStyle(
                        color: isActive ? modeColor : Colors.white54,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFanSpeedSelector() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: _fanSpeeds.map((speed) {
          bool isActive = _fanSpeed == speed;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _fanSpeed = speed);
                _pushCommand();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: isActive ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    if (isActive)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                  ],
                ),
                child: Center(
                  child: Text(
                    speed,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white54,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSwingControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _buildSectionTitle('Airflow Direction'),
            AnimatedLouver(
              swingVMode: _swingVMode,
              protocol: 'Gree',
              accentColor: _accentColor,
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Vertical Louver',
          style: TextStyle(
            fontSize: 11,
            color: Colors.white38,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: _swingVOptions.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final opt = _swingVOptions[index];
              return _buildSwingChip(
                label: opt['label'],
                isSelected: _swingVMode == opt['val'],
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _swingVMode = opt['val']);
                  _pushCommand();
                },
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Horizontal Sweeper',
          style: TextStyle(
            fontSize: 11,
            color: Colors.white38,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: _swingHOptions.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final opt = _swingHOptions[index];
              return _buildSwingChip(
                label: opt['label'],
                isSelected: _swingHMode == opt['val'],
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _swingHMode = opt['val']);
                  _pushCommand();
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSwingChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? _accentColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? _accentColor : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? _accentColor : Colors.white70,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureDecks() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle('Remote Controls'),
        Row(
          children: [
            Expanded(
              child: _buildActionTile(
                title: 'Turbo',
                subtitle: _isTurboOn ? 'Max Cool' : 'Off',
                isActive: _isTurboOn,
                icon: Icons.bolt_rounded,
                onTap: () {
                  setState(() => _isTurboOn = !_isTurboOn);
                  _pushCommand();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildActionTile(
                title: 'Display LED',
                subtitle: _isLightOn ? 'LED On' : 'LED Off',
                isActive: _isLightOn,
                icon: Icons.lightbulb_rounded,
                onTap: () {
                  setState(() => _isLightOn = !_isLightOn);
                  _pushCommand();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildActionTile(
                title: 'X-Fan Clean',
                subtitle: _isXFanOn ? 'Blowing' : 'Off',
                isActive: _isXFanOn,
                icon: Icons.cleaning_services_rounded,
                onTap: () {
                  setState(() => _isXFanOn = !_isXFanOn);
                  _pushCommand();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildActionTile(
                title: 'I-Feel',
                subtitle: _isIFeelOn ? 'Follow-Me' : 'Off',
                isActive: _isIFeelOn,
                icon: Icons.sensors_rounded,
                onTap: () {
                  setState(() => _isIFeelOn = !_isIFeelOn);
                  _pushCommand();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildActionTile(
                title: 'Sleep Mode',
                subtitle: _isSleepOn ? 'Night Curve' : 'Off',
                isActive: _isSleepOn,
                icon: Icons.nights_stay_rounded,
                onTap: () {
                  setState(() => _isSleepOn = !_isSleepOn);
                  _pushCommand();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildActionTile(
                title: 'Temp Display',
                subtitle: _displayLabels[_displayMode],
                isActive: _displayMode != 0,
                icon: _displayMode == 0 ? Icons.visibility_off_rounded : Icons.thermostat_rounded,
                onTap: () {
                  setState(() => _displayMode = (_displayMode + 1) % 4);
                  _pushCommand();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionTile({
    required String title,
    required String subtitle,
    required bool isActive,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: isActive ? _accentColor.withValues(alpha: 0.14) : const Color(0xFF14161F),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? _accentColor.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.06),
            width: 1.5,
          ),
          boxShadow: [
            if (isActive)
              BoxShadow(
                color: _accentColor.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? _accentColor.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.05),
              ),
              child: Icon(
                icon,
                color: isActive ? _accentColor : Colors.white60,
                size: 22,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white70,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                color: isActive ? _accentColor : Colors.white38,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                fontSize: 10,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}