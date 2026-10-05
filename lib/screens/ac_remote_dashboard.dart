import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'gree_view.dart';
import 'panasonic_view.dart';
import '../widgets/analytics_sheet.dart';
import '../widgets/ble_provisioning_sheet.dart';

class ACRemoteDashboard extends StatefulWidget {
  const ACRemoteDashboard({super.key});

  @override
  State<ACRemoteDashboard> createState() => _ACRemoteDashboardState();
}

class _ACRemoteDashboardState extends State<ACRemoteDashboard> {
  String _serverEndpoint = "https://ventra.bhavyashah.me";
  final TextEditingController _endpointController = TextEditingController();

  WebSocketChannel? _wsChannel;
  Timer? _wsReconnectTimer;
  Timer? _pollingTimer;
  Timer? _debounceTimer;

  bool _isWsConnected = false;
  bool _isHubOnline = false;
  bool _isUserInteracting = false;

  String _activeProtocol = "Panasonic";
  Map<String, dynamic> _acStateData = {};

  double? _roomTemp;
  double? _roomHum;
  bool _motionDetected = false;
  bool _isPowerOn = true;

  int _timerMins = 0;

  final List<int> _timerPresets = [0, 30, 60, 120, 180, 240];

  @override
  void initState() {
    super.initState();
    _loadSettings().then((_) {
      _connectWebSocket();
      _pollSensorsAndState();
      _pollingTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollSensorsAndState());
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverEndpoint = prefs.getString('server_endpoint') ?? "https://ventra.bhavyashah.me";
      _activeProtocol = prefs.getString('active_protocol') ?? "Panasonic";
      _endpointController.text = _serverEndpoint;
    });
  }

  Future<void> _saveSettings({String? newEndpoint, String? newProtocol}) async {
    final prefs = await SharedPreferences.getInstance();
    if (newEndpoint != null && newEndpoint.isNotEmpty) {
      if (!newEndpoint.startsWith("http")) {
        newEndpoint = "https://$newEndpoint";
      }
      await prefs.setString('server_endpoint', newEndpoint);
      setState(() {
        _serverEndpoint = newEndpoint!;
        _isWsConnected = false;
        _isHubOnline = false;
      });
      _connectWebSocket();
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
    _endpointController.dispose();
    _debounceTimer?.cancel();
    _pollingTimer?.cancel();
    _wsReconnectTimer?.cancel();
    _wsChannel?.sink.close();
    super.dispose();
  }

  void _connectWebSocket() {
    _wsChannel?.sink.close();
    _wsReconnectTimer?.cancel();

    try {
      final wsUrl = _serverEndpoint.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://");
      final channel = WebSocketChannel.connect(Uri.parse('$wsUrl/ws'));
      _wsChannel = channel;

      channel.stream.listen(
        (message) {
          if (!mounted) return;
          if (!_isWsConnected) {
            setState(() => _isWsConnected = true);
          }
          try {
            final data = jsonDecode(message);
            if (data is Map<String, dynamic>) {
              _handleIncomingEvent(data);
            }
          } catch (_) {}
        },
        onError: (_) {
          if (mounted) setState(() => _isWsConnected = false);
          _scheduleWsReconnect();
        },
        onDone: () {
          if (mounted) setState(() => _isWsConnected = false);
          _scheduleWsReconnect();
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (mounted) setState(() => _isWsConnected = false);
      _scheduleWsReconnect();
    }
  }

  void _scheduleWsReconnect() {
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _connectWebSocket();
    });
  }

  void _handleIncomingEvent(Map<String, dynamic> packet) {
    if (!mounted) return;
    final type = packet['type'];
    final data = packet['data'];

    if (type == 'hub_status' && data is Map) {
      setState(() {
        _isHubOnline = data['online'] == true;
      });
    } else if (type == 'telemetry' && data is Map) {
      setState(() {
        if (data['room_temp'] != null) {
          _roomTemp = (data['room_temp'] as num).toDouble();
        }
        if (data['room_hum'] != null) {
          _roomHum = (data['room_hum'] as num).toDouble();
        }
        _motionDetected = data['motion'] ?? false;
        _isHubOnline = true;
      });
    } else if (type == 'ac_state' && data is Map) {
      if (!_isUserInteracting) {
        setState(() {
          _acStateData = Map<String, dynamic>.from(data);
          if (data.containsKey('power')) {
            _isPowerOn = data['power'] ?? _isPowerOn;
          }
          if (data.containsKey('timer_mins')) {
            _timerMins = data['timer_mins'] ?? _timerMins;
          }
        });
      }
    } else if (type == 'state' && data is Map) {
      _updateStateFromData(Map<String, dynamic>.from(data));
    } else if (type == 'brand_detected') {
      final brand = packet['brand'];
      if (brand != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Physical Remote Detected: $brand'),
            backgroundColor: const Color(0xFF00E5FF),
          ),
        );
      }
    }
  }

  Future<void> _pollSensorsAndState() async {
    if (_serverEndpoint.isEmpty || _isWsConnected) return;
    try {
      final response = await http.get(Uri.parse('$_serverEndpoint/api/state')).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) _updateStateFromData(data);
      }
    } catch (_) {
      if (mounted && !_isWsConnected) {
        setState(() => _isHubOnline = false);
      }
    }
  }

  void _updateStateFromData(Map<String, dynamic> raw) {
    if (!mounted) return;
    final Map<String, dynamic> data = (raw.containsKey('data') && raw['data'] is Map)
        ? Map<String, dynamic>.from(raw['data'] as Map)
        : raw;

    setState(() {
      if (data.containsKey('online')) {
        _isHubOnline = data['online'] == true;
      }
      if (data['room_temp'] != null) {
        _roomTemp = (data['room_temp'] as num).toDouble();
      }
      if (data['room_hum'] != null) {
        _roomHum = (data['room_hum'] as num).toDouble();
      }
      _motionDetected = data['motion'] ?? false;

      // Only update AC state if user is not actively interacting
      if (!_isUserInteracting) {
        _acStateData = data;
        if (data.containsKey('power')) {
          _isPowerOn = data['power'] ?? true;
        }
        if (data.containsKey('timer_mins')) {
          _timerMins = data['timer_mins'] ?? 0;
        }
      }
    });
  }

  void _sendNetworkCommand(Map<String, dynamic> rawPayload) {
    _isUserInteracting = true;
    _debounceTimer?.cancel();

    final bool isOneShot = rawPayload.containsKey('capacity') ||
        rawPayload.containsKey('display_toggle') ||
        rawPayload.containsKey('clean') ||
        rawPayload.containsKey('powerful_toggle');

    final Map<String, dynamic> payload = Map<String, dynamic>.from(rawPayload);

    // Optimistically update _acStateData immediately
    setState(() {
      if (isOneShot) {
        if (payload.containsKey('capacity')) {
          _acStateData['capacity'] = payload['capacity'];
        }
        if (payload.containsKey('display_toggle')) {
          _acStateData['display_state'] = !(_acStateData['display_state'] ?? true);
        }
        if (payload.containsKey('clean')) {
          _acStateData['clean_active'] = payload['clean'];
        }
        if (payload.containsKey('powerful_toggle')) {
          _acStateData['powerful'] = !(_acStateData['powerful'] ?? false);
        }
      } else {
        if (payload.containsKey('power')) {
          _isPowerOn = payload['power'] ?? _isPowerOn;
        } else if (!_isPowerOn) {
          _isPowerOn = true;
        }
        if (payload.containsKey('timer_mins')) {
          _timerMins = payload['timer_mins'] ?? _timerMins;
        }
        payload["power"] = _isPowerOn;
        payload["protocol"] = _activeProtocol;
        payload["timer_mins"] = _timerMins;
        _acStateData = Map<String, dynamic>.from(_acStateData)..addAll(payload);
      }
    });

    void executeCall() async {
      bool sentOverWs = false;
      if (_isWsConnected && _wsChannel != null) {
        try {
          final wsMsg = jsonEncode({
            "action": "command",
            "data": payload
          });
          _wsChannel!.sink.add(wsMsg);
          sentOverWs = true;
        } catch (_) {
          sentOverWs = false;
        }
      }

      if (!sentOverWs) {
        try {
          await http.post(
            Uri.parse('$_serverEndpoint/api/ac'),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(payload),
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }

      // Clear interaction lock after cooldown
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _isUserInteracting = false);
      });
    }

    _debounceTimer = Timer(const Duration(milliseconds: 300), executeCall);
  }

  void _setTimer(int mins) {
    HapticFeedback.selectionClick();
    _sendNetworkCommand({"timer_mins": mins});
  }

  void _showCustomTimerDialog() {
    int selectedMins = _timerMins > 0 ? _timerMins : 60;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1B1D26),
              title: const Text('Set Auto-Off Timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${selectedMins ~/ 60}h ${selectedMins % 60}m ($selectedMins mins)',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFF00E5FF)),
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: selectedMins.toDouble(),
                    min: 15,
                    max: 480,
                    divisions: 31,
                    activeColor: const Color(0xFF00E5FF),
                    onChanged: (val) {
                      setDialogState(() => selectedMins = val.round());
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _setTimer(selectedMins);
                  },
                  child: const Text('Set Timer'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showConfigurationSheet() {
    HapticFeedback.vibrate();
    _endpointController.text = _serverEndpoint;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161822),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 32,
            left: 20,
            right: 20,
            top: 14,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Configuration',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 20),

              // Server Endpoint Field
              const Text(
                'HUB ENDPOINT',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _endpointController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'https://ventra.bhavyashah.me',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.check_circle_rounded, color: Color(0xFF00E5FF)),
                    onPressed: () {
                      _saveSettings(newEndpoint: _endpointController.text.trim());
                      Navigator.pop(context);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Wi-Fi Setup via Bluetooth (Provisioning)
              const Text(
                'HARDWARE SETUP',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5),
              ),
              const SizedBox(height: 8),
              Card.filled(
                color: Colors.white.withValues(alpha: 0.04),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  onTap: () {
                    Navigator.pop(context);
                    HapticFeedback.lightImpact();
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (context) => const BleProvisioningSheet(accentColor: Color(0xFF00E5FF)),
                    );
                  },
                  leading: const Icon(Icons.bluetooth_searching_rounded, color: Color(0xFF00E5FF)),
                  title: const Text('Set Up Hub Wi-Fi (Bluetooth)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
                  subtitle: const Text('Scan & connect ESP32 to Wi-Fi or hotspot', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                ),
              ),
              const SizedBox(height: 24),

              // AC Protocol Selection (Strictly Panasonic & Gree - no home/lab labels)
              const Text(
                'AC PROTOCOL',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5),
              ),
              const SizedBox(height: 8),
              _buildProtocolTile('Panasonic', 'Modern Japanese Inverter AC Protocol'),
              const SizedBox(height: 8),
              _buildProtocolTile('Gree', 'Legacy Chinese AC Protocol'),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProtocolTile(String title, String subtitle) {
    bool isSelected = _activeProtocol == title;
    return Card.filled(
      color: isSelected ? const Color(0xFF00E5FF).withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isSelected ? const Color(0xFF00E5FF) : Colors.transparent),
      ),
      child: ListTile(
        onTap: () {
          HapticFeedback.selectionClick();
          _saveSettings(newProtocol: title);
          Navigator.pop(context);
        },
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Color(0xFF00E5FF)) : null,
      ),
    );
  }

  void _openAnalytics() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AnalyticsSheet(endpoint: _serverEndpoint, accentColor: const Color(0xFF00E5FF)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0E13),
      body: SafeArea(
        child: RefreshIndicator(
          color: const Color(0xFF00E5FF),
          backgroundColor: const Color(0xFF1B1D26),
          onRefresh: () async {
            _isUserInteracting = false;
            await _pollSensorsAndState();
          },
          child: ListView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
            children: [
              _buildTopBar(),
              const SizedBox(height: 12),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: _isPowerOn ? 1.0 : 0.25,
                child: IgnorePointer(
                  ignoring: !_isPowerOn,
                  child: Column(
                    children: [
                      if (_activeProtocol == 'Gree')
                        GreeView(stateData: _acStateData, onCommand: _sendNetworkCommand)
                      else
                        PanasonicView(stateData: _acStateData, onCommand: _sendNetworkCommand),
                      const SizedBox(height: 24),
                      _buildMaterialTimerDeck(),
                      const SizedBox(height: 48),
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

  // ---------------------------------------------------------------------------
  // Clean Material 3 Top Bar (No Logo, Pure Telemetry & Action Buttons)
  // ---------------------------------------------------------------------------
  Widget _buildTopBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Left: Ambient Sensor Readout (Material Pill)
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1D26),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isHubOnline
                        ? const Color(0xFF00E676)
                        : (_isWsConnected ? Colors.amberAccent : Colors.redAccent),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _isHubOnline
                      ? (_roomTemp != null
                          ? '${_roomTemp!.toStringAsFixed(1)}°C · ${_roomHum?.toInt() ?? 0}%'
                          : 'Reading...')
                      : (_isWsConnected ? 'Hub Offline' : 'Connecting...'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                if (_motionDetected && _isHubOnline) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.directions_walk_rounded, size: 11, color: Colors.orange),
                        SizedBox(width: 2),
                        Text(
                          'Motion',
                          style: TextStyle(fontSize: 9.5, color: Colors.orange, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Right: Config + Analytics + Material Circular Power Button
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              onPressed: _showConfigurationSheet,
              icon: const Icon(Icons.tune_rounded, size: 17),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF1B1D26),
                foregroundColor: Colors.white70,
                minimumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
              ),
              tooltip: 'Settings',
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(
              onPressed: _openAnalytics,
              icon: const Icon(Icons.insights_rounded, size: 17),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF1B1D26),
                foregroundColor: Colors.white70,
                minimumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
              ),
              tooltip: 'Analytics',
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                HapticFeedback.heavyImpact();
                _sendNetworkCommand({"power": !_isPowerOn});
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isPowerOn ? const Color(0xFF00E5FF) : const Color(0xFF1B1D26),
                  boxShadow: [
                    if (_isPowerOn)
                      BoxShadow(
                        color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                  ],
                ),
                child: Icon(
                  Icons.power_settings_new_rounded,
                  color: _isPowerOn ? Colors.black : Colors.white54,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Material 3 Timer Deck (Harmonized Dark Glass Container & Custom Pills)
  // ---------------------------------------------------------------------------
  Widget _buildMaterialTimerDeck() {
    final bool isTimerActive = _timerMins > 0;
    const accentColor = Color(0xFF00E5FF);

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF14161F),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isTimerActive ? accentColor.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.06),
          width: 1.5,
        ),
        boxShadow: [
          if (isTimerActive)
            BoxShadow(
              color: accentColor.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isTimerActive ? accentColor.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
                    ),
                    child: Icon(
                      Icons.timer_outlined,
                      size: 16,
                      color: isTimerActive ? accentColor : Colors.white54,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isTimerActive
                        ? 'AUTO-OFF IN ${_timerMins ~/ 60}H ${_timerMins % 60}M'
                        : 'AUTO-OFF TIMER',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                      color: isTimerActive ? accentColor : Colors.white70,
                    ),
                  ),
                ],
              ),
              if (isTimerActive)
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _setTimer(0);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Row(
              children: [
                ..._timerPresets.map((mins) {
                  final bool isSelected = _timerMins == mins;
                  final String label = mins == 0 ? 'Off' : (mins < 60 ? '${mins}m' : '${mins ~/ 60}h');
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _setTimer(mins);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected ? accentColor.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected ? accentColor : Colors.transparent,
                            width: 1.2,
                          ),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? accentColor : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    _showCustomTimerDialog();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_calendar_rounded, size: 14, color: Colors.white54),
                        SizedBox(width: 6),
                        Text(
                          'Custom...',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}