import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/beam.dart';
import 'screens/dashboard.dart';
import 'screens/drone_tab.dart';
import 'screens/wifi_vision.dart';
import 'screens/settings.dart';
import 'screens/tracking.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Drone tab video (media_kit/libmpv). Required before any Player
  // is constructed; a no-op cost when the tab is never opened.
  MediaKit.ensureInitialized();
  runApp(const RfSentryApp());
}

/// Shepherd — dark-mode-only companion app for a Silvus StreamCaster
/// mesh-radio tripwire.
class RfSentryApp extends StatefulWidget {
  const RfSentryApp({super.key});

  @override
  State<RfSentryApp> createState() => _RfSentryAppState();
}

class _RfSentryAppState extends State<RfSentryApp> {
  final AppState _state = AppState();
  int _tab = 0;

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = buildDarkTheme();
    return MaterialApp(
      title: 'Shepherd',
      theme: theme,
      darkTheme: theme,
      // Dark mode first, always: there is no light theme by design.
      themeMode: ThemeMode.dark,
      home: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SHEPHERD',
                  style: SentryType.section(16).copyWith(
                    color: SentryColors.onDark,
                    letterSpacing: 5,
                    fontWeight: FontWeight.w700,
                  )),
              Text('RF MESH SENSING OBSERVATORY',
                  style: SentryType.section(9)),
            ],
          ),
        ),
        body: _tab == 0
            ? DashboardScreen(state: _state)
            : _tab == 1
                ? TrackingScreen(state: _state)
                : _tab == 2
                    ? BeamScreen(state: _state)
                    : _tab == 3
                        ? WifiVisionScreen(state: _state)
                        : _tab == 4
                            ? DroneTab(state: _state)
                            : SettingsScreen(state: _state),
        bottomNavigationBar: BottomNavigationBar(
          // Six destinations: fixed type keeps every label visible
          // (the shifting default would hide unselected labels).
          type: BottomNavigationBarType.fixed,
          currentIndex: _tab,
          onTap: (i) => setState(() => _tab = i),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.radar), label: 'Alerts'),
            BottomNavigationBarItem(
                icon: Icon(Icons.map), label: 'Tracking'),
            BottomNavigationBarItem(
                icon: Icon(Icons.view_in_ar), label: 'Beam'),
            BottomNavigationBarItem(
                icon: Icon(Icons.wifi), label: 'WiFi'),
            BottomNavigationBarItem(
                icon: Icon(Icons.flight), label: 'Drone'),
            BottomNavigationBarItem(
                icon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
