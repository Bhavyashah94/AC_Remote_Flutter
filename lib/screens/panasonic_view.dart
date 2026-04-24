import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/temperature_dial.dart';
import '../widgets/animated_louver.dart';

class PanasonicView extends StatefulWidget {
  final Map<String, dynamic> stateData;
  final Function(Map<String, dynamic>) onCommand;

  const PanasonicView({super.key, required this.stateData, required this.onCommand});

  @override
  State<PanasonicView> createState() => _PanasonicViewState();
}

class _PanasonicViewState extends State<PanasonicView> {
  DateTime _lastInteraction = DateTime.now();

  late int _temperature;
  late String _mode;
  late String _fanSpeed;
  late int _swingVMode;
  late int _swingHMode;
  late bool _isPowerfulOn;
  late bool _isQuietOn;
  late bool _isSmartAutoOn;

  final Map<String, Map<String, dynamic>> _modes = {
    'Cool': {'icon': Icons.ac_unit_rounded, 'color': const Color(0xFF00E5FF)},
    'Heat': {'icon': Icons.wb_sunny_rounded, 'color': const Color(0xFFFF3D00)},
    'Dry': {'icon': Icons.water_drop_rounded, 'color': const Color(0xFFD500F9)},
    'Fan': {'icon': Icons.air_rounded, 'color': const Color(0xFF00E676)},
    'Auto': {'icon': Icons.hdr_auto_rounded, 'color': const Color(0xFFFFFFFF)},
  };

  final List<String> _fanSpeeds = ['Auto', 'Min', 'Low', 'Med', 'High', 'Max'];

  final List<Map<String, dynamic>> _swingVOptions = [
    {'val': 0xF, 'label': 'Auto'}, {'val': 1, 'label': 'Highest'},
    {'val': 2, 'label': 'High'}, {'val': 3, 'label': 'Mid'},
    {'val': 4, 'label': 'Low'}, {'val': 5, 'label': 'Lowest'}
  ];
  final List<Map<String, dynamic>> _swingHOptions = [
    {'val': 0xD, 'label': 'Auto'}, {'val': 9, 'label': 'Max L'},
    {'val': 0xA, 'label': 'Left'}, {'val': 6, 'label': 'Center'},
    {'val': 0xB, 'label': 'Right'}, {'val': 0xC, 'label': 'Max R'}
  ];

  Color get _accentColor => _modes[_mode]?['color'] ?? Colors.white;

  @override
  void initState() {
    super.initState();
    _syncState();
  }

  @override
  void didUpdateWidget(PanasonicView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (DateTime.now().difference(_lastInteraction).inSeconds > 4) {
      _syncState();
    }
  }

  void _syncState() {
    _temperature = (widget.stateData['temp'] ?? 24).toInt();
    _mode = widget.stateData['mode'] ?? 'Cool';
    _fanSpeed = widget.stateData['fan'] ?? 'Auto';
    _swingVMode = widget.stateData['swing_v'] ?? 0xF;
    _swingHMode = widget.stateData['swing_h'] ?? 0xD;
    _isPowerfulOn = widget.stateData['powerful'] ?? false;
    _isQuietOn = widget.stateData['quiet'] ?? false;
    _isSmartAutoOn = widget.stateData['smart_auto'] ?? false;
  }

  void _pushCommand() {
    _lastInteraction = DateTime.now();
    widget.onCommand({
      "protocol": "Panasonic",
      "smart_auto": _isSmartAutoOn,
      "temp": _temperature, "mode": _mode, "fan": _fanSpeed,
      "swing_v": _swingVMode, "swing_h": _swingHMode,
      "powerful": _isPowerfulOn, "quiet": _isQuietOn,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TemperatureDial(
          value: _temperature, minTemp: 16, maxTemp: 30, accentColor: _accentColor,
          onChanged: (val) {
            _lastInteraction = DateTime.now();
            setState(() => _temperature = val);
          },
          onInteractionEnd: _pushCommand,
        ),
        const SizedBox(height: 56),
        _buildSectionTitle('Mode'), _buildModeSelector(),
        const SizedBox(height: 32),
        _buildSectionTitle('Fan Speed'), _buildFanSpeedSelector(),
        const SizedBox(height: 32),
        _buildSwingControls(),
        const SizedBox(height: 32),
        _buildSectionTitle('Panasonic Features'), _buildQuickTogglesGrid(),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(padding: const EdgeInsets.only(bottom: 16.0), child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white54, letterSpacing: 1.5)));
  }

  Widget _buildModeSelector() {
    return SizedBox(
      height: 90,
      child: ListView(
        scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(), clipBehavior: Clip.none,
        children: _modes.keys.map((mode) {
          bool isActive = _mode == mode; Color modeColor = _modes[mode]!['color'] as Color;
          return Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: GestureDetector(
              onTap: () {
                _lastInteraction = DateTime.now();
                HapticFeedback.lightImpact(); setState(() => _mode = mode); _pushCommand();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300), width: 85,
                decoration: BoxDecoration(color: isActive ? modeColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03), borderRadius: BorderRadius.circular(24), border: Border.all(color: isActive ? modeColor.withValues(alpha: 0.5) : Colors.transparent, width: 1.5)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(_modes[mode]!['icon'] as IconData, color: isActive ? modeColor : Colors.white54, size: 28), const SizedBox(height: 12), Text(mode, style: TextStyle(color: isActive ? modeColor : Colors.white54, fontWeight: isActive ? FontWeight.bold : FontWeight.normal, fontSize: 13))]),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFanSpeedSelector() {
    return Container(
      padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.03), borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: _fanSpeeds.map((speed) {
          bool isActive = _fanSpeed == speed;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                _lastInteraction = DateTime.now();
                HapticFeedback.lightImpact(); setState(() => _fanSpeed = speed); _pushCommand();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250), padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(color: isActive ? Colors.white.withValues(alpha: 0.1) : Colors.transparent, borderRadius: BorderRadius.circular(16), boxShadow: [if (isActive) BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 2))]),
                child: Center(child: Text(speed, style: TextStyle(color: isActive ? Colors.white : Colors.white54, fontWeight: isActive ? FontWeight.bold : FontWeight.normal, fontSize: 13))),
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
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [_buildSectionTitle('Airflow Direction'), AnimatedLouver(swingVMode: _swingVMode, accentColor: _accentColor)]),
        const SizedBox(height: 8), const Text('Vertical Louver', style: TextStyle(fontSize: 11, color: Colors.white38, fontWeight: FontWeight.bold, letterSpacing: 1.0)), const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(), itemCount: _swingVOptions.length, separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final opt = _swingVOptions[index];
              return _buildSwingChip(label: opt['label'], isSelected: _swingVMode == opt['val'], onTap: () {
                _lastInteraction = DateTime.now();
                HapticFeedback.selectionClick(); setState(() => _swingVMode = opt['val']); _pushCommand();
              });
            },
          ),
        ),
        const SizedBox(height: 16), const Text('Horizontal Sweeper', style: TextStyle(fontSize: 11, color: Colors.white38, fontWeight: FontWeight.bold, letterSpacing: 1.0)), const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal, physics: const BouncingScrollPhysics(), itemCount: _swingHOptions.length, separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final opt = _swingHOptions[index];
              return _buildSwingChip(label: opt['label'], isSelected: _swingHMode == opt['val'], onTap: () {
                _lastInteraction = DateTime.now();
                HapticFeedback.selectionClick(); setState(() => _swingHMode = opt['val']); _pushCommand();
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSwingChip({required String label, required bool isSelected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(horizontal: 18), alignment: Alignment.center,
        decoration: BoxDecoration(color: isSelected ? _accentColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(20), border: Border.all(color: isSelected ? _accentColor : Colors.transparent, width: 1)),
        child: Text(label, style: TextStyle(color: isSelected ? _accentColor : Colors.white70, fontSize: 13, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500)),
      ),
    );
  }

  Widget _buildQuickTogglesGrid() {
    return GridView.count(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 2.5,
      children: [
        _buildSlimToggle('Powerful Mode', _isPowerfulOn, Icons.bolt_rounded, () { _lastInteraction = DateTime.now(); setState(() => _isPowerfulOn = !_isPowerfulOn); _pushCommand(); }),
        _buildSlimToggle('Quiet Mode', _isQuietOn, Icons.volume_mute_rounded, () { _lastInteraction = DateTime.now(); setState(() => _isQuietOn = !_isQuietOn); _pushCommand(); }),
        _buildSlimToggle('Smart Auto-Pilot', _isSmartAutoOn, Icons.auto_awesome_rounded, () { _lastInteraction = DateTime.now(); setState(() => _isSmartAutoOn = !_isSmartAutoOn); _pushCommand(); }),
      ],
    );
  }

  Widget _buildSlimToggle(String title, bool isActive, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); onTap(); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300), padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: isActive ? _accentColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.03), borderRadius: BorderRadius.circular(16), border: Border.all(color: isActive ? _accentColor.withValues(alpha: 0.5) : Colors.transparent, width: 1)),
        child: Row(children: [Icon(icon, color: isActive ? _accentColor : Colors.white54, size: 20), const SizedBox(width: 10), Expanded(child: Text(title, style: TextStyle(color: isActive ? Colors.white : Colors.white54, fontWeight: isActive ? FontWeight.bold : FontWeight.w500, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis))]),
      ),
    );
  }
}