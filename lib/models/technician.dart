class Technician {
  final String franchise;
  final String name;
  final bool isCustomName; // true when "Others" was selected

  const Technician({
    required this.franchise,
    required this.name,
    this.isCustomName = false,
  });

  Map<String, dynamic> toMap() => {
        'franchise': franchise,
        'name': name,
        'isCustomName': isCustomName,
        'registeredAt': DateTime.now().toIso8601String(),
      };
}
