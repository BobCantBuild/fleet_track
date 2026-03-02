import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../services/notification_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // ✅ FIX #10 — observe app lifecycle
  bool _isPunchedIn = false;
  bool _isOnLeave = false;
  double _totalKm = 0.0;
  String _techName = '';
  String _franchise = '';
  String _techId = '';
  String _sessionId = '';
  DateTime? _punchInTime;
  StreamSubscription? _bgSub;
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // ✅ FIX #10
    _loadState();

    // ✅ PRIMARY: background service event listener
    _bgSub = FlutterBackgroundService().on('update').listen((event) {
      if (event != null && mounted) {
        final km = (event['totalKm'] as num?)?.toDouble() ?? _totalKm;
        if (km != _totalKm) {
          setState(() => _totalKm = km);
          SharedPreferences.getInstance()
              .then((p) => p.setDouble('total_km', km));
        }
      }
    });

    // ✅ FIX #4 — timer started only if punched in (checked inside)
    _startUiTimerIfNeeded();
  }

  // ✅ FIX #10 — Resume timer and refresh km when app comes to foreground
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshKmFromPrefs(); // Immediately sync km
      _startUiTimerIfNeeded(); // Restart timer if needed
    } else if (state == AppLifecycleState.paused) {
      _stopUiTimer(); // Stop timer when backgrounded
    }
  }

  void _startUiTimerIfNeeded() {
    if (_uiTimer != null && _uiTimer!.isActive) return;
    // ✅ FIX #4 — Only run timer when actually punched in
    if (!_isPunchedIn) return;
    _uiTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      await _refreshKmFromPrefs();
    });
  }

  void _stopUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = null;
  }

  Future<void> _refreshKmFromPrefs() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // ✅ Force fresh read
    final km = prefs.getDouble('total_km') ?? _totalKm;
    if (km != _totalKm && mounted) {
      setState(() => _totalKm = km);
    }
    // ✅ FIX #10 — Also refresh duration display
    if (mounted) setState(() {});
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    setState(() {
      _techName = prefs.getString('name') ?? '';
      _franchise = prefs.getString('franchise') ?? '';
      _techId = prefs.getString('tech_id') ?? '';
      _isPunchedIn = prefs.getBool('is_punched_in') ?? false;
      _isOnLeave = prefs.getBool('is_on_leave') ?? false;
      _totalKm = prefs.getDouble('total_km') ?? 0.0;
      _sessionId = prefs.getString('session_id') ?? '';
      final pt = prefs.getString('punch_in_time');
      if (pt != null) _punchInTime = DateTime.parse(pt);
    });
    // ✅ FIX #4 — Start timer AFTER state loaded if punched in
    _startUiTimerIfNeeded();
  }

  // ── LOCATION PERMISSION ───────────────────────────────────────────────────
  Future<bool> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('📍 Location Required',
              style: TextStyle(color: Colors.white)),
          content: const Text('Please turn ON GPS to Punch IN.',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await Geolocator.openLocationSettings();
              },
              child: const Text('Open Settings',
                  style: TextStyle(color: Color(0xFF3B82F6))),
            ),
          ],
        ),
      );
      return false;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) {
        _showSnack('Location permission denied.');
        return false;
      }
    }
    if (perm == LocationPermission.deniedForever) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Permission Required',
              style: TextStyle(color: Colors.white)),
          content: const Text(
              'Enable location from App Settings to use this app.',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await openAppSettings();
              },
              child: const Text('Open Settings',
                  style: TextStyle(color: Color(0xFF3B82F6))),
            ),
          ],
        ),
      );
      return false;
    }
    return true;
  }

  // ── PUNCH IN ──────────────────────────────────────────────────────────────
  Future<void> _punchIn() async {
    final granted = await _requestLocationPermission();
    if (!granted) return;

    final sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    final punchInTime = DateTime.now();
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('is_punched_in', true);
    await prefs.setBool('is_on_leave', false);
    await prefs.setString('session_id', sessionId);
    await prefs.setDouble('total_km', 0.0);
    await prefs.setString('punch_in_time', punchInTime.toIso8601String());
    // ✅ FIX #1 — Clear saved last position so new session starts fresh
    await prefs.remove('last_lat');
    await prefs.remove('last_lng');

    setState(() {
      _isPunchedIn = true;
      _isOnLeave = false;
      _totalKm = 0.0;
      _sessionId = sessionId;
      _punchInTime = punchInTime;
    });

    await NotificationService.cancelTodayReminderOnly();

    // Initial GPS write
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await _writeLocation(pos, 0.0, sessionId, 'active');
    } catch (_) {}

    // Firestore session doc
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

    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(_techId)
        .set({
      'status': 'active',
      'leaveStatus': null,
    }, SetOptions(merge: true));

    await FlutterBackgroundService().startService();

    // ✅ FIX #4 — Start timer now that we are punched in
    _startUiTimerIfNeeded();
    _showSnack('✅ Punched IN — GPS tracking started!');
  }

  // ── PUNCH OUT ─────────────────────────────────────────────────────────────
  Future<void> _punchOut() async {
    // ✅ FIX #2 — Get latest km before stopping service
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final latestKm = prefs.getDouble('total_km') ?? _totalKm;

    await prefs.setBool('is_punched_in', false);
    await prefs.setDouble('total_km', latestKm);
    // ✅ FIX #1 — Clear last position on punch out
    await prefs.remove('last_lat');
    await prefs.remove('last_lng');

    setState(() {
      _totalKm = latestKm;
      _isPunchedIn = false;
    });

    // ✅ FIX #4 — Stop timer when not tracking
    _stopUiTimer();

    // ✅ FIX #2 — Small delay so background service does its final sync
    FlutterBackgroundService().invoke('stopService');
    await Future.delayed(const Duration(seconds: 2));

    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(_techId)
        .set({'status': 'offline'}, SetOptions(merge: true));

    if (_sessionId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection(AppConstants.sessionsCollection)
          .doc(_sessionId)
          .update({
        'punchOut': FieldValue.serverTimestamp(),
        'totalKm': latestKm, // ✅ FIX #2 — Accurate final km
        'status': 'completed',
      });
    }

    _showSnack('👋 Punched OUT. Total: ${latestKm.toStringAsFixed(2)} km');
  }

  // ── APPLY LEAVE ───────────────────────────────────────────────────────────
  Future<void> _applyLeave() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title:
            const Text('🏖 Apply Leave', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Mark today as Leave?\nThis will be visible to your manager.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, Apply Leave'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final leaveId = 'leave_${DateTime.now().millisecondsSinceEpoch}';
    final today = DateTime.now();
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('is_on_leave', true);
    await prefs.setBool('is_punched_in', false);

    setState(() {
      _isOnLeave = true;
      _isPunchedIn = false;
    });

    // ✅ FIX #4 — Stop timer when on leave
    _stopUiTimer();

    // ✅ FIX #9 — Stop background service if somehow still running
    FlutterBackgroundService().invoke('stopService');

    await NotificationService.cancelTodayReminderOnly();

    await FirebaseFirestore.instance
        .collection(AppConstants.leavesCollection)
        .doc(leaveId)
        .set({
      'techId': _techId,
      'name': _techName,
      'franchise': _franchise,
      'date': FieldValue.serverTimestamp(),
      'dateStr': '${today.day}/${today.month}/${today.year}',
      'status': 'approved',
      'type': 'casual',
    });

    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(_techId)
        .set({
      'status': 'leave',
      'leaveStatus': 'on_leave',
      'name': _techName,
      'franchise': _franchise,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _showSnack('🏖 Leave applied successfully!');
  }

  // ── WRITE LOCATION ────────────────────────────────────────────────────────
  Future<void> _writeLocation(
      Position pos, double km, String sessionId, String status) async {
    final now = DateTime.now(); // ✅ FIX #11 — single DateTime for consistency
    final locRef = FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(_techId);

    await locRef.set({
      'lat': pos.latitude,
      'lng': pos.longitude,
      'accuracy': pos.accuracy,
      'speed': pos.speed,
      'totalKm': km,
      'sessionId': sessionId,
      'franchise': _franchise,
      'name': _techName,
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await locRef.collection('trail').add({
      'lat': pos.latitude,
      'lng': pos.longitude,
      'totalKm': km,
      'sessionId': sessionId,
      'timestamp': FieldValue.serverTimestamp(),
      'dateStr': '${now.day}/${now.month}/${now.year}',
    });
  }

  // ── CANCEL LEAVE & PUNCH IN ───────────────────────────────────────────────
  Future<void> _cancelLeaveAndPunchIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_on_leave', false);
    setState(() => _isOnLeave = false);
    await FirebaseFirestore.instance
        .collection(AppConstants.locationsCollection)
        .doc(_techId)
        .set({
      'status': 'offline',
      'leaveStatus': null,
    }, SetOptions(merge: true));
    await _punchIn();
  }

  // ── LOGOUT ────────────────────────────────────────────────────────────────
  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    if (_isPunchedIn) await _punchOut();

    // ✅ FIX #9 — Always stop service on logout
    FlutterBackgroundService().invoke('stopService');
    _stopUiTimer();

    await NotificationService.cancelPunchReminder();

    // ✅ FIX #13 — Only clear auth keys, NOT km/session keys
    // (in case background service is still doing final write)
    final prefs = await SharedPreferences.getInstance();
    final keysToKeep = ['total_km', 'session_id', 'punch_in_time'];
    final allKeys = prefs.getKeys();
    for (final key in allKeys) {
      if (!keysToKeep.contains(key)) {
        await prefs.remove(key);
      }
    }
    // ✅ Small delay then clear remaining keys
    await Future.delayed(const Duration(seconds: 2));
    await prefs.clear();

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF1E293B),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ✅ FIX #10 — Duration updates correctly when returning from background
  String _formatDuration() {
    if (_punchInTime == null || !_isPunchedIn) return '--:--';
    final diff = DateTime.now().difference(_punchInTime!);
    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    return '$h h $m m';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // ✅ FIX #10
    _bgSub?.cancel();
    _stopUiTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Fleet Track',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Identity card ──────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E3A8A), Color(0xFF1D4ED8)],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.blue.withOpacity(0.2), blurRadius: 12)
                ],
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: Colors.white24,
                    child: Text(
                      _techName.isNotEmpty ? _techName[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_techName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis),
                        Text(_franchise,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── Stats row ──────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                    child: _StatCard(
                  icon: Icons.directions_walk,
                  label: 'Distance',
                  value: '${_totalKm.toStringAsFixed(2)} km',
                  color: Colors.green,
                )),
                const SizedBox(width: 12),
                Expanded(
                    child: _StatCard(
                  icon: Icons.timer,
                  label: 'On Field',
                  value: _formatDuration(),
                  color: Colors.orange,
                )),
              ],
            ),
            const SizedBox(height: 14),

            // ── Status banner ──────────────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _isOnLeave
                    ? const Color(0xFF451A03)
                    : _isPunchedIn
                        ? const Color(0xFF052E16)
                        : const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isOnLeave
                      ? Colors.orange
                      : _isPunchedIn
                          ? Colors.green
                          : Colors.grey.shade700,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isOnLeave
                        ? Icons.beach_access
                        : _isPunchedIn
                            ? Icons.location_on
                            : Icons.location_off,
                    color: _isOnLeave
                        ? Colors.orange
                        : _isPunchedIn
                            ? Colors.green
                            : Colors.grey,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _isOnLeave
                          ? '🏖 On Leave Today\nVisible to your manager'
                          : _isPunchedIn
                              ? '🟢 Tracking Active\nLocation is being shared'
                              : '⚫ Not Tracking\nPunch IN to start work',
                      style: TextStyle(
                        color: _isOnLeave
                            ? Colors.orange[200]
                            : _isPunchedIn
                                ? Colors.green[200]
                                : Colors.grey[400],
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            // ── Punch IN ───────────────────────────────────────────────
            if (!_isPunchedIn && !_isOnLeave) ...[
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1D4ED8),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 4,
                  ),
                  icon: const Icon(Icons.play_circle_outlined, size: 26),
                  label: const Text('Punch IN',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  onPressed: _punchIn,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange, width: 1.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.beach_access, size: 22),
                  label: const Text('Apply Leave',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  onPressed: _applyLeave,
                ),
              ),
            ],

            // ── Punch OUT ──────────────────────────────────────────────
            if (_isPunchedIn)
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[700],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 4,
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 26),
                  label: const Text('Punch OUT',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  onPressed: _punchOut,
                ),
              ),

            // ── Cancel Leave ───────────────────────────────────────────
            if (_isOnLeave)
              SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey,
                    side: const BorderSide(color: Colors.grey),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.undo, size: 22),
                  label: const Text('Cancel Leave & Punch IN',
                      style: TextStyle(fontSize: 15)),
                  onPressed: _cancelLeaveAndPunchIn,
                ),
              ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ── Stat Card ──────────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}
