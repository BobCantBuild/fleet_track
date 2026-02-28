import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/location_service.dart';
import '../utils/constants.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isPunchedIn = false;
  double _totalKm = 0.0;
  String _techName = '';
  String _franchise = '';
  String _techId = '';
  String? _sessionId;
  StreamSubscription? _bgSub;
  DateTime? _punchInTime;

  @override
  void initState() {
    super.initState();
    _loadState();

    // Listen to km updates from background service
    _bgSub = FlutterBackgroundService().on('locationUpdate').listen((event) {
      if (event != null && mounted) {
        setState(() => _totalKm = (event['totalKm'] as num).toDouble());
      }
    });
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _techName = prefs.getString('name') ?? '';
      _franchise = prefs.getString('franchise') ?? '';
      _techId = prefs.getString('tech_id') ?? '';
      _isPunchedIn = prefs.getBool('is_punched_in') ?? false;
      _totalKm = prefs.getDouble('total_km') ?? 0.0;
      final punchStr = prefs.getString('punch_in_time');
      if (punchStr != null) _punchInTime = DateTime.parse(punchStr);
    });
  }

  Future<void> _punchIn() async {
    final granted = await LocationService.requestPermissions();
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission required')),
      );
      return;
    }

    final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_punched_in', true);
    await prefs.setString('session_id', sessionId);
    await prefs.setDouble('total_km', 0.0);
    await prefs.setString('punch_in_time', DateTime.now().toIso8601String());

    // Create session document
    await FirebaseFirestore.instance
        .collection(AppConstants.sessionsCollection)
        .doc(sessionId)
        .set({
      'techId': _techId,
      'name': _techName,
      'franchise': _franchise,
      'punchIn': FieldValue.serverTimestamp(),
      'punchOut': null,
      'totalKm': 0.0,
      'status': 'active',
    });

    // Start background GPS service
    await FlutterBackgroundService().startService();

    setState(() {
      _isPunchedIn = true;
      _totalKm = 0.0;
      _sessionId = sessionId;
      _punchInTime = DateTime.now();
    });
  }

  Future<void> _punchOut() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = prefs.getString('session_id') ?? '';

    // Stop background service (it self-checks is_punched_in)
    await prefs.setBool('is_punched_in', false);
    FlutterBackgroundService().invoke('stopService');

    // Close session doc
    if (sessionId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection(AppConstants.sessionsCollection)
          .doc(sessionId)
          .update({
        'punchOut': FieldValue.serverTimestamp(),
        'totalKm': _totalKm,
        'status': 'completed',
      });
    }

    // Update technician live doc status
    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(_techId)
        .set({'status': 'offline'}, SetOptions(merge: true));

    await prefs.setDouble('total_km', _totalKm);
    setState(() {
      _isPunchedIn = false;
    });
  }

  Future<void> _logout() async {
    if (_isPunchedIn) await _punchOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  String _formatDuration() {
    if (_punchInTime == null) return '--:--';
    final diff = DateTime.now().difference(_punchInTime!);
    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    return '$h h $m m';
  }

  @override
  void dispose() {
    _bgSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Track'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Identity card ───────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_techName,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(_franchise,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Stats row ───────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    icon: Icons.directions_walk,
                    label: 'Distance',
                    value: '${_totalKm.toStringAsFixed(2)} km',
                    color: Colors.green,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    icon: Icons.timer,
                    label: 'On Field',
                    value: _formatDuration(),
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Status indicator ────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color:
                    _isPunchedIn ? Colors.green.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isPunchedIn ? Colors.green : Colors.grey,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isPunchedIn ? Icons.location_on : Icons.location_off,
                    color: _isPunchedIn ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isPunchedIn
                        ? 'Tracking Active — Location sharing ON'
                        : 'Not Tracking — Punch IN to start',
                    style: TextStyle(
                      color: _isPunchedIn ? Colors.green : Colors.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),

            // ── Punch IN / OUT button ───────────────────────────────
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _isPunchedIn ? Colors.red : Colors.blue,
                minimumSize: const Size.fromHeight(56),
              ),
              icon: Icon(_isPunchedIn ? Icons.stop_circle : Icons.play_circle),
              label: Text(
                _isPunchedIn ? 'Punch OUT' : 'Punch IN',
                style: const TextStyle(fontSize: 18),
              ),
              onPressed: _isPunchedIn ? _punchOut : _punchIn,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatCard(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
