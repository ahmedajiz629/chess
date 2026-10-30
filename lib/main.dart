import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const ChessTrackerApp());
}

class ChessTrackerApp extends StatefulWidget {
  const ChessTrackerApp({super.key});

  @override
  State<ChessTrackerApp> createState() => _ChessTrackerAppState();
}

class _ChessTrackerAppState extends State<ChessTrackerApp> {
  final AppState _state = AppState();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4A79A8),
        brightness: Brightness.dark,
      ),
      home: HomePage(state: _state),
    );
  }
}
