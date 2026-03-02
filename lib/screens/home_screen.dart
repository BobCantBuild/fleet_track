import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  double _totalKm = 0.0;
  String _techName = '';
  String _franchise = '';
  bool _isTracking = false;
  StreamSubscription? _bgSub;
  Timer? _uiTimer;

  // Work hours
  static const int _startHour = 9;
  static const int _startMinute = 0;
  static const int _endHour = 18;
  static const int _endMinute = 30;

  bool get _isWorkHours {
    final now = DateTime.now();
    final start =
        now.copyWith(hour: _startHour, minute: _startMinute, second: 0);
    final end = now.copyWith(hour: _endHour, minute: _endMinute, second: 0);
    return now.isAfter(start) && now.isBefore(end);
  }

  String get _nextEventLabel {
    final now = DateTime.now();
    if (_isWorkHours) {
      final end = now.copyWith(hour: _endHour, minute: _endMinute, second: 0);
      final diff = end.difference(now);
      return 'Tracking stops in ${diff.inHours}h ${diff.inMinutes % 60}m';
    } else {
      var start =
          now.copyWith(hour: _startHour, minute: _startMinute, second: 0);
      if (now.isAfter(start)) start = start.add(const Duration(days: 1));
      final diff = start.difference(now);
      return 'Tracking starts in ${diff.inHours}h ${diff.inMinutes % 60}m';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();

    _bgSub = FlutterBackgroundService().on('update').listen((event) {
      if (event != null && mounted) {
        final km = (event['totalKm'] as num?)?.toDouble() ?? _totalKm;
        if (km != _totalKm) setState(() => _totalKm = km);
      }
    });

    _uiTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted) return;
      await _refreshState();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshState();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    setState(() {
      _techName = prefs.getString('name') ?? '';
      _franchise = prefs.getString('franchise') ?? '';
      _totalKm = prefs.getDouble('total_km') ?? 0.0;
      _isTracking = prefs.getBool('is_punched_in') ?? false;
    });
  }

  Future<void> _refreshState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final km = prefs.getDouble('total_km') ?? _totalKm;
    final trk = prefs.getBool('is_punched_in') ?? false;
    if (mounted)
      setState(() {
        _totalKm = km;
        _isTracking = trk;
      });
  }

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

    FlutterBackgroundService().invoke('stopService');

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bgSub?.cancel();
    _uiTimer?.cancel();
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
            // ── Identity card ────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF1E3A8A), Color(0xFF1D4ED8)]),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.blue.withOpacity(0.2), blurRadius: 12)
                ],
              ),
              child: Row(children: [
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
                )),
              ]),
            ),
            const SizedBox(height: 20),

            // ── Today km card ────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _InfoTile(
                    icon: Icons.directions_car,
                    label: 'Today\'s Distance',
                    value: '${_totalKm.toStringAsFixed(2)} km',
                    color: Colors.green,
                  ),
                  Container(
                      width: 1, height: 50, color: const Color(0xFF334155)),
                  _InfoTile(
                    icon: Icons.schedule,
                    label: 'Work Hours',
                    value: '9:00 AM – 6:30 PM',
                    color: Colors.blue,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Status banner ────────────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _isTracking
                    ? const Color(0xFF052E16)
                    : const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _isTracking ? Colors.green : Colors.grey.shade700,
                  width: 2,
                ),
              ),
              child: Column(children: [
                Row(children: [
                  // Animated dot
                  if (_isTracking) ...[
                    _PulsingDot(),
                    const SizedBox(width: 10),
                  ] else ...[
                    const Icon(Icons.location_off,
                        color: Colors.grey, size: 22),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                      child: Text(
                    _isTracking
                        ? 'Location Monitoring Active'
                        : 'Monitoring Off Hours',
                    style: TextStyle(
                      color: _isTracking ? Colors.green[300] : Colors.grey[400],
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  )),
                ]),
                const SizedBox(height: 8),
                Text(
                  _nextEventLabel,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ]),
            ),
            const SizedBox(height: 16),

            // ── Schedule card ────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('📅 Auto-Tracking Schedule',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  _ScheduleRow(
                    time: '9:00 AM',
                    label: 'Tracking starts automatically',
                    color: Colors.green,
                    icon: Icons.play_circle,
                  ),
                  const SizedBox(height: 8),
                  _ScheduleRow(
                    time: '6:30 PM',
                    label: 'Tracking stops automatically',
                    color: Colors.red,
                    icon: Icons.stop_circle,
                  ),
                  const SizedBox(height: 8),
                  _ScheduleRow(
                    time: 'Always',
                    label: 'GPS → WiFi → Cell fallback',
                    color: Colors.blue,
                    icon: Icons.signal_cellular_alt,
                  ),
                ],
              ),
            ),

            const Spacer(),

            // ── Consent note at bottom ───────────────────────────────
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF1E3A8A), width: 1),
              ),
              child: const Text(
                '🔒 Location is monitored during work hours as per '
                'your employment agreement.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ── Pulsing dot widget ────────────────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: Colors.green,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: Colors.green.withOpacity(0.6), blurRadius: 6)
          ],
        ),
      ),
    );
  }
}

// ── Info tile ─────────────────────────────────────────────────────────────────
class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _InfoTile(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, color: color, size: 26),
      const SizedBox(height: 6),
      Text(value,
          style: TextStyle(
              color: color, fontSize: 16, fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
    ]);
  }
}

// ── Schedule row ──────────────────────────────────────────────────────────────
class _ScheduleRow extends StatelessWidget {
  final String time;
  final String label;
  final Color color;
  final IconData icon;
  const _ScheduleRow(
      {required this.time,
      required this.label,
      required this.color,
      required this.icon});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 10),
      Text(time,
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 13)),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ]);
  }
}
