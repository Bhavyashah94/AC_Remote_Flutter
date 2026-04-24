import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'gree_view.dart';
import 'panasonic_view.dart';
import '../widgets/analytics_sheet.dart';

class ACRemoteDashboard extends StatefulWidget {
  const ACRemoteDashboard({super.key});

  @override
  State<ACRemoteDashboard> createState() => _ACRemoteDashboardState();
}

class _ACRemoteDashboardState extends State<ACRemoteDashboard> {
  String _wifiEndpoint = "http://10.99.213.95";
  final TextEditingController _ipController = TextEditingController();

  Timer? _debounceTimer;
  Timer? _sensorPollingTimer;
  bool _isNetworkActive = false;

  DateTime _lastInteraction = DateTime.now();

  String _activeProtocol = "Gree";
  Map<String, dynamic> _acStateData = {};

  double _roomTemp = 0.0;
  double _roomHum = 0.0;
  bool _motionDetected = false;
  bool _isPowerOn = true;

  int _timerHours = 0;
  int _timerMinutes = 0;
  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;

  bool _isSyncingTimer = false;

  @override
  void initState() {
    super.initState();
    _hourController = FixedExtentScrollController(initialItem: _timerHours);
    _minuteController = FixedExtentScrollController(initialItem: _timerMinutes);

    _loadSettings().then((_) {
      _pollSensorsAndState();
      _sensorPollingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollSensorsAndState());
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _wifiEndpoint = prefs.getString('wifi_endpoint') ?? "http://10.99.213.95";
      _activeProtocol = prefs.getString('active_protocol') ?? "Gree";
      _ipController.text = _wifiEndpoint;
    });
  }

  Future<void> _saveSettings({String? newIp, String? newProtocol}) async {
    final prefs = await SharedPreferences.getInstance();
    if (newIp != null && newIp.isNotEmpty) {
      if (!newIp.startsWith("http")) {
        newIp = "http://$newIp";
      }
      await prefs.setString('wifi_endpoint', newIp);
      setState(() {
        _wifiEndpoint = newIp!;
        _isNetworkActive = false;
      });
    }
    if (newProtocol != null) {
      await prefs.setString('active_protocol', newProtocol);
      setState(() {
        _activeProtocol = newProtocol;
        _acStateData.clear();
      });
    }
    _pollSensorsAndState();
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _ipController.dispose();
    _debounceTimer?.cancel();
    _sensorPollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollSensorsAndState() async {
    if (_wifiEndpoint.isEmpty) return;
    try {
      final response = await http.get(Uri.parse('$_wifiEndpoint/api/state')).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _roomTemp = data['room_temp'].toDouble();
          _roomHum = data['room_hum'].toDouble();
          _motionDetected = data['motion'];
          _isNetworkActive = true;

          if (DateTime.now().difference(_lastInteraction).inSeconds > 4) {
            _acStateData = data;
            _isPowerOn = data['power'] ?? true;

            int totalMins = data['timer_mins'] ?? 0;
            if (_timerHours != totalMins ~/ 60 || _timerMinutes != totalMins % 60) {
              _isSyncingTimer = true;
              _timerHours = totalMins ~/ 60;
              _timerMinutes = totalMins % 60;

              if (_hourController.hasClients) _hourController.jumpToItem(_timerHours);
              if (_minuteController.hasClients) _minuteController.jumpToItem(_timerMinutes);

              Future.delayed(const Duration(milliseconds: 100), () {
                if (mounted) _isSyncingTimer = false;
              });
            }
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isNetworkActive = false);
    }
  }

  void _sendNetworkCommand(Map<String, dynamic> payload) {
    _lastInteraction = DateTime.now();
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    void executeCall() async {
      payload["power"] = _isPowerOn;
      payload["timer_mins"] = (_timerHours * 60) + _timerMinutes;

      try {
        await http.post(Uri.parse('$_wifiEndpoint/api/ac'), headers: {"Content-Type": "application/json"}, body: jsonEncode(payload)).timeout(const Duration(seconds: 3));
        if (mounted) setState(() => _isNetworkActive = true);
      } catch (e) {
        if (mounted) setState(() => _isNetworkActive = false);
      }
    }

    _debounceTimer = Timer(const Duration(milliseconds: 400), executeCall);
  }

  void _showSecretProtocolMenu() {
    HapticFeedback.vibrate();
    _ipController.text = _wifiEndpoint;
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF161618),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
        builder: (context) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 48,
              left: 24, right: 24, top: 16
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 32),
                const Text('Ventra Configuration', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 24),
                const Align(alignment: Alignment.centerLeft, child: Text('HUB IP ADDRESS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5))),
                const SizedBox(height: 12),
                TextField(
                  controller: _ipController,
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (val) {
                    _saveSettings(newIp: val);
                    Navigator.pop(context);
                  },
                  decoration: InputDecoration(
                    hintText: 'http://192.168.1.XX',
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.check_circle, color: Color(0xFF00E5FF)),
                      onPressed: () {
                        _saveSettings(newIp: _ipController.text);
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                const Align(alignment: Alignment.centerLeft, child: Text('AC PROTOCOL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5))),
                const SizedBox(height: 12),
                _buildProtocolOption('Gree', 'Legacy Chinese AC Protocol', const Color(0xFF00E5FF)),
                const SizedBox(height: 12),
                _buildProtocolOption('Panasonic', 'Modern Japanese AC Protocol', const Color(0xFF00E5FF)),
              ],
            ),
          );
        }
    );
  }

  Widget _buildProtocolOption(String title, String subtitle, Color accentColor) {
    bool isSelected = _activeProtocol == title;
    return ListTile(
      onTap: () {
        _saveSettings(newProtocol: title);
        Navigator.pop(context);
      },
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      tileColor: isSelected ? accentColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54)),
      trailing: isSelected ? Icon(Icons.check_circle_rounded, color: accentColor) : null,
    );
  }

  void _openAnalytics() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AnalyticsSheet(endpoint: _wifiEndpoint, accentColor: const Color(0xFF00E5FF)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: const Color(0xFF00E5FF),
          backgroundColor: const Color(0xFF161618),
          onRefresh: () {
            _lastInteraction = DateTime.now().subtract(const Duration(seconds: 5));
            return _pollSensorsAndState();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 10.0),
            children: [
              _buildHeader(),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 400),
                opacity: _isPowerOn ? 1.0 : 0.3,
                child: IgnorePointer(
                  ignoring: !_isPowerOn,
                  child: Column(
                    children: [
                      if (_activeProtocol == 'Gree')
                        GreeView(stateData: _acStateData, onCommand: _sendNetworkCommand)
                      else
                        PanasonicView(stateData: _acStateData, onCommand: _sendNetworkCommand),

                      const SizedBox(height: 40),
                      _buildTimerScrollPicker(),
                      const SizedBox(height: 60),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isNetworkActive)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off_rounded, size: 14, color: Colors.red),
                    const SizedBox(width: 8),
                    Text('Offline. Reconnecting...', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onLongPress: _showSecretProtocolMenu,
                    child: Container(color: Colors.transparent, child: const Text('VENTRA', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -0.5))),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(_isNetworkActive ? '${_roomTemp.toStringAsFixed(1)}°C • ${_roomHum.toInt()}% Hum' : 'Sensors Offline', style: const TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w600)),
                      if (_motionDetected && _isNetworkActive) ...[const SizedBox(width: 8), Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)), child: const Text('Motion', style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.bold)))]
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  GestureDetector(
                    onTap: _openAnalytics,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300), padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), shape: BoxShape.circle, border: Border.all(color: Colors.white12, width: 1.5)),
                      child: const Icon(Icons.bar_chart_rounded, color: Colors.white54, size: 22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () {
                      _lastInteraction = DateTime.now();
                      HapticFeedback.heavyImpact();
                      setState(() => _isPowerOn = !_isPowerOn);
                      _sendNetworkCommand({});
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300), padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: _isPowerOn ? Colors.white.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05), shape: BoxShape.circle, border: Border.all(color: _isPowerOn ? Colors.white.withValues(alpha: 0.5) : Colors.white12, width: 1.5), boxShadow: [if (_isPowerOn) BoxShadow(color: Colors.white.withValues(alpha: 0.2), blurRadius: 20, spreadRadius: 2)]),
                      child: Icon(Icons.power_settings_new_rounded, color: _isPowerOn ? Colors.white : Colors.white54, size: 28),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimerScrollPicker() {
    final bool isTimerActive = _timerHours > 0 || _timerMinutes > 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(color: isTimerActive ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.02), borderRadius: BorderRadius.circular(24), border: Border.all(color: isTimerActive ? Colors.white.withValues(alpha: 0.3) : Colors.transparent, width: 1)),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.timer_rounded, color: isTimerActive ? Colors.white : Colors.white38, size: 20), const SizedBox(width: 8),
              Text(isTimerActive ? 'AC WILL TURN OFF IN' : 'SET AUTO-OFF TIMER', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isTimerActive ? Colors.white : Colors.white38, letterSpacing: 1.0)),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 120,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                    width: 80,
                    child: ListWheelScrollView.useDelegate(
                        controller: _hourController, itemExtent: 40, perspective: 0.005, diameterRatio: 1.2, physics: const FixedExtentScrollPhysics(),
                        onSelectedItemChanged: (index) {
                          if (!_isSyncingTimer) {
                            _lastInteraction = DateTime.now();
                            HapticFeedback.selectionClick();
                            setState(() => _timerHours = index);
                            _sendNetworkCommand({});
                          }
                        },
                        childDelegate: ListWheelChildBuilderDelegate(childCount: 25, builder: (context, index) => Center(child: AnimatedDefaultTextStyle(duration: const Duration(milliseconds: 200), style: TextStyle(fontSize: _timerHours == index ? 32 : 20, fontWeight: _timerHours == index ? FontWeight.bold : FontWeight.w400, color: _timerHours == index ? Colors.white : Colors.white38), child: Text(index.toString().padLeft(2, '0')))))
                    )
                ),
                const Text('hrs', style: TextStyle(fontSize: 16, color: Colors.white54, fontWeight: FontWeight.bold)),
                const SizedBox(width: 24),
                SizedBox(
                    width: 80,
                    child: ListWheelScrollView.useDelegate(
                        controller: _minuteController, itemExtent: 40, perspective: 0.005, diameterRatio: 1.2, physics: const FixedExtentScrollPhysics(),
                        onSelectedItemChanged: (index) {
                          if (!_isSyncingTimer) {
                            _lastInteraction = DateTime.now();
                            HapticFeedback.selectionClick();
                            setState(() => _timerMinutes = index);
                            _sendNetworkCommand({});
                          }
                        },
                        childDelegate: ListWheelChildBuilderDelegate(childCount: 60, builder: (context, index) => Center(child: AnimatedDefaultTextStyle(duration: const Duration(milliseconds: 200), style: TextStyle(fontSize: _timerMinutes == index ? 32 : 20, fontWeight: _timerMinutes == index ? FontWeight.bold : FontWeight.w400, color: _timerMinutes == index ? Colors.white : Colors.white38), child: Text(index.toString().padLeft(2, '0')))))
                    )
                ),
                const Text('min', style: TextStyle(fontSize: 16, color: Colors.white54, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}