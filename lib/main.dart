import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';
import 'services/background_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await NotificationService.init();
  await initBackgroundService();

  runApp(const FleetTrackApp());
}

class FleetTrackApp extends StatelessWidget {
  const FleetTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fleet Track',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: _loadPrefs(),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F172A),
            body: Center(
              child: CircularProgressIndicator(color: Colors.blue),
            ),
          );
        }
        final prefs = snap.data!;
        final loggedIn = prefs.getBool('is_logged_in') ?? false;
        return loggedIn ? const HomeScreen() : const LoginScreen();
      },
    );
  }

  // ✅ Always reload before auth check — avoids stale login state
  Future<SharedPreferences> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }
}
