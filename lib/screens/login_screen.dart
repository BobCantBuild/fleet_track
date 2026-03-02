import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/notification_service.dart';
import '../utils/constants.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ── State ────────────────────────────────────────────────────────────────
  String? _selectedFranchise;
  String? _selectedTechId;
  String? _selectedTechName;
  bool _isLoading = false;
  bool _isLoadingTechs = false;
  String _error = '';

  List<String> _franchises = [];
  List<Map<String, String>> _technicians = [];

  final List<String> _hardcodedFranchises = [
    'MFBS',
    'PromptCare',
    'Krisma Tech',
  ];

  @override
  void initState() {
    super.initState();
    _loadFranchises();
  }

  // ── Load franchises ───────────────────────────────────────────────────────
  Future<void> _loadFranchises() async {
    setState(() => _franchises = _hardcodedFranchises);
  }

  // ── Load technicians by franchise ─────────────────────────────────────────
  Future<void> _loadTechnicians(String franchise) async {
    setState(() {
      _isLoadingTechs = true;
      _technicians = [];
      _selectedTechId = null;
      _selectedTechName = null;
      _error = '';
    });

    try {
      // ✅ Removed .orderBy() — no composite index needed
      final snap = await FirebaseFirestore.instance
          .collection(AppConstants.techniciansCollection)
          .where('franchise', isEqualTo: franchise)
          .get();

      // Sort client-side instead
      final list = snap.docs
          .map((doc) => {
                'id': doc.id,
                'name': (doc.data()['name'] ?? 'Unknown') as String,
              })
          .toList();

      // ✅ Sort alphabetically on client side
      list.sort((a, b) => a['name']!.compareTo(b['name']!));

      setState(() {
        _technicians = list;
        _isLoadingTechs = false;
      });

      if (list.isEmpty) {
        setState(() => _error = 'No technicians found for $franchise.');
      }
    } catch (e) {
      setState(() {
        _isLoadingTechs = false;
        _error = 'Error: ${e.toString()}';
      });
    }
  }

  // ── LOGIN ─────────────────────────────────────────────────────────────────
  Future<void> _login() async {
    if (_selectedFranchise == null) {
      setState(() => _error = 'Please select a franchise.');
      return;
    }
    if (_selectedTechId == null || _selectedTechName == null) {
      setState(() => _error = 'Please select your name.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      // Save to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tech_id', _selectedTechId!);
      await prefs.setString('name', _selectedTechName!);
      await prefs.setString('franchise', _selectedFranchise!);
      await prefs.setBool('is_logged_in', true);
      await prefs.setBool('is_punched_in', false);
      await prefs.setBool('is_on_leave', false);

      // ✅ Schedule daily 10 AM punch reminder
      await NotificationService.scheduleDailyPunchReminder();

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Login failed: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ── Logo ────────────────────────────────────────────────
                Container(
                  width: 86,
                  height: 86,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E3A8A), Color(0xFF1D4ED8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.35),
                        blurRadius: 22,
                        spreadRadius: 2,
                      )
                    ],
                  ),
                  child: const Icon(Icons.local_shipping_rounded,
                      color: Colors.white, size: 44),
                ),
                const SizedBox(height: 22),

                // ── Title ────────────────────────────────────────────────
                const Text('Fleet Track',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 6),
                const Text('Select your franchise and name to continue',
                    style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    textAlign: TextAlign.center),
                const SizedBox(height: 36),

                // ── Step 1: Franchise Dropdown ────────────────────────────
                _SectionLabel(label: 'Step 1 — Select Franchise'),
                const SizedBox(height: 8),
                _DropdownBox(
                  hint: 'Choose your franchise...',
                  value: _selectedFranchise,
                  items: _franchises
                      .map(
                        (f) => DropdownMenuItem(
                          value: f,
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  color: f == 'MFBS'
                                      ? const Color(0xFF8B5CF6)
                                      : f == 'PromptCare'
                                          ? const Color(0xFF10B981)
                                          : const Color(0xFFF59E0B),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              Text(f,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 15)),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedFranchise = val;
                      _selectedTechId = null;
                      _selectedTechName = null;
                      _error = '';
                    });
                    if (val != null) _loadTechnicians(val);
                  },
                ),
                const SizedBox(height: 20),

                // ── Step 2: Technician Dropdown ───────────────────────────
                _SectionLabel(label: 'Step 2 — Select Your Name'),
                const SizedBox(height: 8),

                if (_isLoadingTechs)
                  Container(
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF3B82F6)),
                      ),
                    ),
                  )
                else
                  _DropdownBox(
                    hint: _selectedFranchise == null
                        ? 'Select franchise first...'
                        : _technicians.isEmpty
                            ? 'No technicians found'
                            : 'Choose your name...',
                    value: _selectedTechId,
                    items: _technicians
                        .map(
                          (t) => DropdownMenuItem(
                            value: t['id'],
                            child: Text(t['name']!,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 15)),
                          ),
                        )
                        .toList(),
                    onChanged: _selectedFranchise == null
                        ? null
                        : (val) {
                            setState(() {
                              _selectedTechId = val;
                              _selectedTechName = _technicians
                                  .firstWhere((t) => t['id'] == val)['name'];
                              _error = '';
                            });
                          },
                  ),

                const SizedBox(height: 12),

                // ── Selected preview ──────────────────────────────────────
                if (_selectedTechName != null && _selectedFranchise != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF052E16),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.green.shade800),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          '${_selectedTechName!}  ·  ${_selectedFranchise!}',
                          style: const TextStyle(
                              color: Colors.green,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 12),

                // ── Error ─────────────────────────────────────────────────
                if (_error.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7F1D1D),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_error,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                if (_error.isNotEmpty) const SizedBox(height: 12),

                // ── Login Button ──────────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _selectedTechId != null
                          ? const Color(0xFF1D4ED8)
                          : const Color(0xFF1E293B),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: _selectedTechId != null ? 4 : 0,
                    ),
                    onPressed:
                        (_isLoading || _selectedTechId == null) ? null : _login,
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2.5))
                        : const Text('Start Tracking',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 28),

                // ── Footer ────────────────────────────────────────────────
                const Text(
                  'Contact your manager if your name is not listed.',
                  style: TextStyle(color: Color(0xFF475569), fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Reusable Section Label ────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(label,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
              letterSpacing: 0.4)),
    );
  }
}

// ── Reusable Dropdown Box ─────────────────────────────────────────────────────
class _DropdownBox extends StatelessWidget {
  final String hint;
  final String? value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?>? onChanged;
  const _DropdownBox({
    required this.hint,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color:
              value != null ? const Color(0xFF3B82F6) : const Color(0xFF334155),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(hint,
              style: const TextStyle(color: Color(0xFF475569), fontSize: 14)),
          isExpanded: true,
          dropdownColor: const Color(0xFF1E293B),
          iconEnabledColor: const Color(0xFF3B82F6),
          iconDisabledColor: const Color(0xFF475569),
          items: items,
          onChanged: onChanged,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }
}
