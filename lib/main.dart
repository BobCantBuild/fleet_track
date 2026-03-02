import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';
import 'services/background_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.init();
  await initBackgroundService();

  // ✅ Auto-start background service immediately on launch
  await FlutterBackgroundService().startService();

  runApp(const FleetTrackApp());
}

class FleetTrackApp extends StatelessWidget {
  const FleetTrackApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fleet Track',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
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
    return FutureBuilder<_AuthState>(
      future: _checkAuth(),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F172A),
            body: Center(child: CircularProgressIndicator(color: Colors.blue)),
          );
        }
        final auth = snap.data!;
        return auth.loggedIn && auth.techId.isNotEmpty
            ? const HomeScreen()
            : const LoginScreen();
      },
    );
  }

  Future<_AuthState> _checkAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final loggedIn = prefs.getBool('is_logged_in') ?? false;
    final techId = prefs.getString('tech_id') ?? '';
    final name = prefs.getString('name') ?? '';
    if (loggedIn && (techId.isEmpty || name.isEmpty)) {
      await prefs.clear();
      return _AuthState(loggedIn: false, techId: '');
    }
    return _AuthState(loggedIn: loggedIn, techId: techId);
  }
}

class _AuthState {
  final bool loggedIn;
  final String techId;
  const _AuthState({required this.loggedIn, required this.techId});
}
