import 'package:flutter/material.dart';
import 'screens/ac_remote_dashboard.dart';

void main() {
  runApp(const SmartACApp());
}

class SmartACApp extends StatelessWidget {
  const SmartACApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ventra',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0C),
        colorScheme: const ColorScheme.dark(),
        splashFactory: NoSplash.splashFactory,
      ),
      home: const ACRemoteDashboard(),
    );
  }
}
