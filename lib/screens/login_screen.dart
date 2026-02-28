import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? _selectedFranchise;
  String? _selectedName;
  bool _isOthers = false;
  bool _isLoading = false;
  List<String> _names = [];
  final _customNameCtrl = TextEditingController();

  Future<void> _loadNames(String franchise) async {
    setState(() {
      _isLoading = true;
      _names = [];
      _selectedName = null;
    });
    final snap = await FirebaseFirestore.instance
        .collection(AppConstants.techniciansCollection)
        .where('franchise', isEqualTo: franchise)
        .get();

    final names = snap.docs.map((d) => d['name'] as String).toList()
      ..sort()
      ..add('Others');

    setState(() {
      _names = names;
      _isLoading = false;
    });
  }

  Future<void> _login() async {
    final name = _isOthers ? _customNameCtrl.text.trim() : _selectedName;

    if (_selectedFranchise == null || name == null || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all fields')),
      );
      return;
    }

    setState(() => _isLoading = true);

    // If "Others", add the technician to Firestore for next time
    String techId;
    if (_isOthers) {
      final ref = await FirebaseFirestore.instance
          .collection(AppConstants.techniciansCollection)
          .add({
        'franchise': _selectedFranchise,
        'name': name,
        'isCustomName': true,
        'addedAt': FieldValue.serverTimestamp(),
      });
      techId = ref.id;
    } else {
      // Fetch existing doc ID
      final snap = await FirebaseFirestore.instance
          .collection(AppConstants.techniciansCollection)
          .where('franchise', isEqualTo: _selectedFranchise)
          .where('name', isEqualTo: name)
          .limit(1)
          .get();
      techId = snap.docs.first.id;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_logged_in', true);
    await prefs.setString('tech_id', techId);
    await prefs.setString('franchise', _selectedFranchise!);
    await prefs.setString('name', name);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 64, color: Colors.blue),
              const SizedBox(height: 16),
              Text('Fleet Track',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('Technician Login',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 40),

              // ── Franchise dropdown ──────────────────────────────────
              DropdownButtonFormField<String>(
                value: _selectedFranchise,
                decoration: const InputDecoration(
                    labelText: 'Select Franchise',
                    border: OutlineInputBorder()),
                items: AppConstants.franchises
                    .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                    .toList(),
                onChanged: (val) {
                  _selectedFranchise = val;
                  if (val != null) _loadNames(val);
                },
              ),
              const SizedBox(height: 16),

              // ── Name dropdown ───────────────────────────────────────
              if (_names.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: _selectedName,
                  decoration: const InputDecoration(
                      labelText: 'Select Your Name',
                      border: OutlineInputBorder()),
                  items: _names
                      .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                      .toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedName = val;
                      _isOthers = val == 'Others';
                    });
                  },
                ),

              // ── Custom name field for "Others" ──────────────────────
              if (_isOthers) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _customNameCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Enter your name',
                      border: OutlineInputBorder()),
                ),
              ],

              const SizedBox(height: 32),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : FilledButton.icon(
                      icon: const Icon(Icons.login),
                      label: const Text('Continue'),
                      onPressed: _login,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
