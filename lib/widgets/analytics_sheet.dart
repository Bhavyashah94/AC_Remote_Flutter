import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;

class AnalyticsSheet extends StatefulWidget {
  final String endpoint;
  final Color accentColor;

  const AnalyticsSheet({super.key, required this.endpoint, required this.accentColor});

  @override
  State<AnalyticsSheet> createState() => _AnalyticsSheetState();
}

class _AnalyticsSheetState extends State<AnalyticsSheet> {
  List<double> temperatures = [];
  List<double> humidities = [];
  List<double> motionHits = [];
  bool isLoading = true;
  int _selectedHours = 24;

  @override
  void initState() {
    super.initState();
    _fetchAnalytics();
  }

  Future<void> _fetchAnalytics() async {
    setState(() => isLoading = true);
    try {
      final uri = Uri.parse('${widget.endpoint}/api/analytics?hours=$_selectedHours');
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            temperatures = List<double>.from(data['temperatures']?.map((x) => x.toDouble()) ?? []);
            humidities = List<double>.from(data['humidities']?.map((x) => x.toDouble()) ?? []);
            motionHits = List<double>.from(data['motion_hits']?.map((x) => x.toDouble()) ?? []);
            isLoading = false;
          });
        }
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    double minT = temperatures.isNotEmpty ? temperatures.reduce((a, b) => a < b ? a : b) : 0;
    double maxT = temperatures.isNotEmpty ? temperatures.reduce((a, b) => a > b ? a : b) : 0;
    double avgT = temperatures.isNotEmpty ? temperatures.reduce((a, b) => a + b) / temperatures.length : 0;
    int totalMotion = motionHits.fold(0, (acc, val) => acc + (val > 0 ? 1 : 0));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF141416),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Climate Analytics', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                  Text('Telemetry & Room Occupancy', style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
              Row(
                children: [2, 24, 168].map((hours) {
                  bool isSel = _selectedHours == hours;
                  String label = hours == 2 ? '2h' : (hours == 24 ? '24h' : '7d');
                  return Padding(
                    padding: const EdgeInsets.only(left: 6.0),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedHours = hours);
                        _fetchAnalytics();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isSel ? widget.accentColor.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isSel ? widget.accentColor : Colors.transparent),
                        ),
                        child: Text(label, style: TextStyle(color: isSel ? widget.accentColor : Colors.white60, fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Summary Stats Cards
          Row(
            children: [
              _buildStatCard('AVG TEMP', '${avgT.toStringAsFixed(1)}°', Icons.thermostat_rounded, widget.accentColor),
              const SizedBox(width: 10),
              _buildStatCard('RANGE', '${minT.toStringAsFixed(0)}° - ${maxT.toStringAsFixed(0)}°', Icons.swap_vert_rounded, Colors.orange),
              const SizedBox(width: 10),
              _buildStatCard('MOTION EVENTS', '$totalMotion', Icons.directions_walk_rounded, Colors.purpleAccent),
            ],
          ),
          const SizedBox(height: 28),

          if (isLoading)
            SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator(color: widget.accentColor)),
            )
          else ...[
            // Temperature Graph
            const Text('TEMPERATURE HISTORY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5)),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: temperatures.isEmpty
                  ? const Center(child: Text('No telemetry records yet', style: TextStyle(color: Colors.white38)))
                  : LineChart(
                      LineChartData(
                        gridData: const FlGridData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: temperatures.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                            isCurved: true,
                            color: widget.accentColor,
                            barWidth: 3,
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: widget.accentColor.withValues(alpha: 0.15),
                            ),
                          ),
                          LineChartBarData(
                            spots: humidities.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                            isCurved: true,
                            color: Colors.blueAccent.withValues(alpha: 0.6),
                            barWidth: 1.5,
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 24),

            // Motion Bar Chart
            const Text('OCCUPANCY HITS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5)),
            const SizedBox(height: 12),
            SizedBox(
              height: 90,
              child: motionHits.isEmpty
                  ? const Center(child: Text('No motion data recorded', style: TextStyle(color: Colors.white38)))
                  : BarChart(
                      BarChartData(
                        gridData: const FlGridData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        barGroups: motionHits.asMap().entries.map((e) => BarChartGroupData(
                          x: e.key,
                          barRods: [BarChartRodData(
                            toY: e.value > 0 ? e.value : 0.05,
                            color: e.value > 0 ? Colors.purpleAccent : Colors.white10,
                            width: 6,
                            borderRadius: BorderRadius.circular(3)
                          )],
                        )).toList(),
                      ),
                    ),
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Expanded(child: Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white38), overflow: TextOverflow.ellipsis)),
              ],
            ),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}