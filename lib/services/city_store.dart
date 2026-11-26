import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// مدينة الزبون التي يختارها مرة واحدة عند أول فتح للتطبيق.
///
/// تُحفظ على الجهاز (localStorage على الويب) فلا يُسأل مرة أخرى،
/// وتبقى جاهزة لأي فلترة أو عرض لاحق باسم [chosen].
class CityStore {
  CityStore._();

  static final CityStore instance = CityStore._();

  static const String _key = 'app_city';

  /// المدن المتاحة الآن — «المزيد قريباً» ليس مدينة، فلا يُحفظ.
  static const List<String> cities = <String>['الشطرة', 'الناصرية'];

  /// مدن معلنة في القائمة لكنها غير مفتوحة بعد — تُعرض بشعار
  /// «قريباً» ولا تُختار، فلا تدخل هنا [cities] ولا تُحفظ.
  static const List<String> upcomingCities = <String>[
    'الرفاعي',
    'الغراف',
    'النصر',
    'قلعة سكر',
  ];

  String? _chosen;

  String? get chosen => _chosen;

  bool get hasChoice => (_chosen ?? '').trim().isNotEmpty;

  /// يُنبَّه عند كل اختيار مدينة (أول مرة أو تبديل لاحق) فتتحدّث الشاشات
  /// المفتوحة فوراً — بدونه بقي الدليل يعرض دكاترة مدينة غير المختارة.
  final ValueNotifier<String?> changed = ValueNotifier<String?>(null);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key)?.trim() ?? '';
      _chosen = saved.isEmpty ? null : saved;
    } catch (_) {}
  }

  Future<void> save(String city) async {
    final value = city.trim();
    if (!cities.contains(value)) return;
    _chosen = value;
    changed.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value);
    } catch (_) {}
  }
}
