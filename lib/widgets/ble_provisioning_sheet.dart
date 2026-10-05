import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class BleProvisioningSheet extends StatefulWidget {
  final Color accentColor;
  const BleProvisioningSheet({super.key, required this.accentColor});

  @override
  State<BleProvisioningSheet> createState() => _BleProvisioningSheetState();
}

enum ProvisioningStep { scanningBle, selectBle, connectingBle, scanningWifi, selectWifi, enteringPassword, provisioning, success, error }

class _BleProvisioningSheetState extends State<BleProvisioningSheet> {
  ProvisioningStep _step = ProvisioningStep.scanningBle;
  String _statusMessage = 'Searching for Ventra Hub...';
  String _errorMessage = '';

  List<ScanResult> _bleResults = [];
  BluetoothDevice? _targetDevice;
  BluetoothCharacteristic? _scanChar;
  BluetoothCharacteristic? _configChar;
  BluetoothCharacteristic? _statusChar;

  StreamSubscription? _scanSub;
  StreamSubscription? _statusSub;

  List<Map<String, dynamic>> _wifiNetworks = [];
  String _selectedSsid = '';
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _startBleScan();
  }

  Future<void> _disconnectBle() async {
    _scanSub?.cancel();
    _scanSub = null;
    _statusSub?.cancel();
    _statusSub = null;
    if (_targetDevice != null) {
      try {
        await _targetDevice!.disconnect();
      } catch (_) {}
      _targetDevice = null;
    }
    _scanChar = null;
    _configChar = null;
    _statusChar = null;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    FlutterBluePlus.stopScan();
    _disconnectBle();
    super.dispose();
  }

  void _onRetry() {
    if (_targetDevice != null && _configChar != null) {
      _scanWifiNetworks();
    } else {
      _startBleScan();
    }
  }

  Future<void> _startBleScan() async {
    await _disconnectBle();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    setState(() {
      _step = ProvisioningStep.scanningBle;
      _statusMessage = 'Checking permissions & Bluetooth...';
      _bleResults.clear();
      _errorMessage = '';
    });

    try {
      // 1. Android 12+ (API 31+) Runtime Permissions
      if (Platform.isAndroid) {
        final scanStatus = await Permission.bluetoothScan.request();
        final connectStatus = await Permission.bluetoothConnect.request();
        if (scanStatus.isPermanentlyDenied || connectStatus.isPermanentlyDenied) {
          setState(() {
            _step = ProvisioningStep.error;
            _errorMessage = 'Bluetooth permissions permanently denied. Please enable "Nearby Devices" in App Settings.';
          });
          return;
        }
        if (!scanStatus.isGranted || !connectStatus.isGranted) {
          setState(() {
            _step = ProvisioningStep.error;
            _errorMessage = 'Bluetooth permission is required to search for Ventra Hub.';
          });
          return;
        }
      }

      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        setState(() {
          _step = ProvisioningStep.error;
          _errorMessage = 'Please turn on Bluetooth on your device.';
        });
        return;
      }

      setState(() => _statusMessage = 'Scanning for Ventra Hub via Bluetooth...');

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );

      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        final ventraDevices = results.where((r) {
          final advName = r.advertisementData.advName.toLowerCase();
          final platName = r.device.platformName.toLowerCase();
          final hasVentra = advName.contains('ventra') || platName.contains('ventra');
          final hasUuid = r.advertisementData.serviceUuids.any(
              (u) => u.toString().toLowerCase().contains('19b10000'));
          return hasVentra || hasUuid;
        }).toList();

        if (mounted) {
          setState(() {
            _bleResults = ventraDevices;
          });

          // Auto-connect if Ventra hub found
          if (ventraDevices.isNotEmpty && _targetDevice == null) {
            _connectToBleDevice(ventraDevices.first.device);
          }
        }
      });

      await Future.delayed(const Duration(seconds: 10));
      if (_targetDevice == null && mounted) {
        setState(() {
          if (_bleResults.isEmpty) {
            _step = ProvisioningStep.error;
            _errorMessage = 'No Ventra Hub found nearby. Ensure it is powered on and in setup mode.';
          } else {
            _step = ProvisioningStep.selectBle;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = ProvisioningStep.error;
          _errorMessage = 'Bluetooth scan error: $e';
        });
      }
    }
  }

  Future<void> _connectToBleDevice(BluetoothDevice device) async {
    setState(() {
      _targetDevice = device;
      _step = ProvisioningStep.connectingBle;
      _statusMessage = 'Connecting to ${device.platformName.isNotEmpty ? device.platformName : "Ventra Hub"}...';
    });

    try {
      await FlutterBluePlus.stopScan();
      await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 8));

      // Request MTU 512 on Android to prevent ATT truncation on Wi-Fi scan list
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
        } catch (_) {}
      }

      final services = await device.discoverServices();
      for (var s in services) {
        if (s.uuid.toString().toLowerCase().contains('19b10000')) {
          for (var c in s.characteristics) {
            final uuid = c.uuid.toString().toLowerCase();
            if (uuid.contains('19b10001')) _scanChar = c;
            if (uuid.contains('19b10002')) _configChar = c;
            if (uuid.contains('19b10003')) _statusChar = c;
          }
        }
      }

      if (_configChar == null) {
        throw Exception('Ventra setup service characteristics not found.');
      }

      // Listen to status characteristic
      if (_statusChar != null) {
        await _statusChar!.setNotifyValue(true);
        _statusSub = _statusChar!.onValueReceived.listen((value) {
          final str = utf8.decode(value);
          _handleStatusNotification(str);
        });
      }

      // Trigger Wi-Fi scan on ESP32
      _scanWifiNetworks();

    } catch (e) {
      if (mounted) {
        setState(() {
          _step = ProvisioningStep.error;
          _errorMessage = 'Failed to connect to Ventra Hub: $e';
        });
      }
    }
  }

  Future<void> _scanWifiNetworks() async {
    setState(() {
      _step = ProvisioningStep.scanningWifi;
      _statusMessage = 'Requesting Wi-Fi scan from Ventra Hub...';
      _wifiNetworks.clear();
    });

    try {
      if (_scanChar != null) {
        final val = await _scanChar!.read();
        final jsonStr = utf8.decode(val);
        if (jsonStr.isNotEmpty) {
          final List<dynamic> list = jsonDecode(jsonStr);
          setState(() {
            _wifiNetworks = list.map((e) {
              final m = Map<String, dynamic>.from(e);
              return {
                "ssid": m["s"] ?? m["ssid"] ?? "",
                "rssi": m["r"] ?? m["rssi"] ?? -100,
                "auth": m["a"] ?? m["auth"] ?? false,
              };
            }).toList();
            _step = ProvisioningStep.selectWifi;
          });
          return;
        }
      }
    } catch (_) {}

    // Fallback if read was empty or errored
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _step = ProvisioningStep.selectWifi;
      });
    }
  }

  void _handleStatusNotification(String status) {
    // Format: "1:Connecting", "2:192.168.1.150", "3:Failed"
    if (status.startsWith('2:')) {
      final ip = status.substring(2);
      setState(() {
        _step = ProvisioningStep.success;
        _statusMessage = 'Connected! Assigned IP: $ip';
      });
      HapticFeedback.heavyImpact();
    } else if (status.startsWith('3:')) {
      setState(() {
        _step = ProvisioningStep.error;
        _errorMessage = 'Ventra Hub could not connect. Check Wi-Fi password and try again.';
      });
      HapticFeedback.vibrate();
    }
  }

  Future<void> _sendWifiCredentials() async {
    if (_selectedSsid.isEmpty) return;

    setState(() {
      _step = ProvisioningStep.provisioning;
      _statusMessage = 'Sending Wi-Fi credentials to Ventra Hub...';
    });

    try {
      final payload = jsonEncode({
        "ssid": _selectedSsid,
        "password": _passwordController.text.trim()
      });

      await _configChar!.write(utf8.encode(payload), withoutResponse: false);

      setState(() {
        _statusMessage = 'Ventra Hub is connecting to $_selectedSsid...';
      });
    } catch (e) {
      setState(() {
        _step = ProvisioningStep.error;
        _errorMessage = 'Failed to transmit Wi-Fi credentials: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
        left: 24, right: 24, top: 16
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF161618),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 24),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: widget.accentColor.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(Icons.bluetooth_searching_rounded, color: widget.accentColor, size: 24),
              ),
              const SizedBox(width: 16),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ventra Wi-Fi Setup', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  Text('In-App Bluetooth Provisioning', style: TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildBodyForStep(),
        ],
      ),
    );
  }

  Widget _buildBodyForStep() {
    switch (_step) {
      case ProvisioningStep.scanningBle:
      case ProvisioningStep.connectingBle:
      case ProvisioningStep.scanningWifi:
      case ProvisioningStep.provisioning:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 36.0),
          child: Column(
            children: [
              CircularProgressIndicator(color: widget.accentColor),
              const SizedBox(height: 24),
              Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ),
        );

      case ProvisioningStep.selectBle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SELECT YOUR VENTRA HUB', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5)),
            const SizedBox(height: 12),
            ..._bleResults.map((r) => ListTile(
              onTap: () => _connectToBleDevice(r.device),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              tileColor: Colors.white.withValues(alpha: 0.05),
              title: Text(r.device.platformName.isNotEmpty ? r.device.platformName : 'Ventra Hub', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              subtitle: Text(r.device.remoteId.str, style: const TextStyle(color: Colors.white38, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
            )),
          ],
        );

      case ProvisioningStep.selectWifi:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('SELECT HOME WI-FI (2.4 GHz)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5)),
                GestureDetector(
                  onTap: _scanWifiNetworks,
                  child: Text('Rescan', style: TextStyle(fontSize: 12, color: widget.accentColor, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_wifiNetworks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                child: TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Enter Wi-Fi Network Name (SSID)',
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) => _selectedSsid = val,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _wifiNetworks.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final net = _wifiNetworks[index];
                    final ssid = net['ssid'] ?? '';
                    final bool isLocked = net['auth'] == true;
                    return ListTile(
                      onTap: () {
                        setState(() {
                          _selectedSsid = ssid;
                          _step = ProvisioningStep.enteringPassword;
                        });
                      },
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      tileColor: Colors.white.withValues(alpha: 0.05),
                      leading: Icon(isLocked ? Icons.wifi_password_rounded : Icons.wifi_rounded, color: widget.accentColor),
                      title: Text(ssid, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.accentColor,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () {
                if (_selectedSsid.isNotEmpty) {
                  setState(() => _step = ProvisioningStep.enteringPassword);
                }
              },
              child: const Text('Next', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );

      case ProvisioningStep.enteringPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect to "$_selectedSsid"', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Wi-Fi Password',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () => setState(() => _step = ProvisioningStep.selectWifi),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.accentColor,
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _sendWifiCredentials,
                    child: const Text('Connect Hub', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        );

      case ProvisioningStep.success:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: Colors.green, size: 40),
              ),
              const SizedBox(height: 20),
              const Text('Ventra Hub Connected!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.accentColor,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );

      case ProvisioningStep.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 24.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 40),
              ),
              const SizedBox(height: 20),
              const Text('Setup Failed', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              Text(_errorMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.accentColor,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _onRetry,
                      child: const Text('Try Again', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
    }
  }
}
