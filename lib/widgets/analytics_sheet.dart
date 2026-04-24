import 'dart:convert';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _fetchAnalytics();
  }

  Future<void> _fetchAnalytics() async {
    try {
      final response = await http.get(Uri.parse('${widget.endpoint}/api/analytics'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          temperatures = List<double>.from(data['temperatures'].map((x) => x.toDouble()));
          humidities = List<double>.from(data['humidities'].map((x) => x.toDouble()));
          motionHits = List<double>.from(data['motion_hits'].map((x) => x.toDouble()));
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Color(0xFF161618),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: isLoading
          ? Center(child: CircularProgressIndicator(color: widget.accentColor))
          : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Environment Analytics', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          const Text('Rolling window of recent data logs.', style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 32),

          // Temperature Graph
          const Text('TEMPERATURE & HUMIDITY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5)),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(show: false),
                titlesData: FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: temperatures.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                    isCurved: true,
                    color: widget.accentColor,
                    barWidth: 3,
                    dotData: FlDotData(show: false),
                    belowBarData: BarAreaData(show: true, color: widget.accentColor.withOpacity(0.1)),
                  ),
                  LineChartBarData(
                    spots: humidities.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                    isCurved: true,
                    color: Colors.blue,
                    barWidth: 2,
                    dotData: FlDotData(show: false),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Motion Bar Chart
          const Text('MOTION EVENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38, letterSpacing: 1.5)),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: BarChart(
              BarChartData(
                gridData: FlGridData(show: false),
                titlesData: FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                barGroups: motionHits.asMap().entries.map((e) => BarChartGroupData(
                  x: e.key,
                  barRods: [BarChartRodData(toY: e.value, color: Colors.orange, width: 8, borderRadius: BorderRadius.circular(4))],
                )).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}