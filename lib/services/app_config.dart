import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_service.dart';

/// إعدادات عامة يضبطها الأدمن من لوحة التحكم — **بلا تحديث للتطبيق**.
///
/// تُقرأ من جدول `app_settings` في Supabase، فأي تغيير يظهر لدى كل
/// المستخدمين فور فتح التطبيق (أو عند إقلاعه).
///
/// ⚠️ نظام النقاط محذوف. المتبقّي هنا هو **رسالة الترحيب فقط**، وحالتها
/// (هل رآها هذا المستخدم) على الخادم لا على الجهاز — دالة
/// `welcome_note_pending` في `reward_welcome_state`.
class AppConfig {
  AppConfig._();
  static final AppConfig instance = AppConfig._();

  static const String _kCacheKey = 'welcome_cfg_cache_v1';

  /// نص رسالة الترحيب.
  static const String welcomeDefault =
      'أهلاً بك في اطباء ذي قار! طلباتك تصلك من باب بيتك بكل سهولة.';

  bool _loaded = false;
  bool _welcomeEnabled = true;
  String _welcomeText = welcomeDefault;

  bool get loaded => _loaded;
  bool get welcomeEnabled => _welcomeEnabled;
  String get welcomeText => _welcomeText;

  /// يقرأ الإعدادات من السيرفر (مع نسخة محلية للسرعة).
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;

    // 1) نسخة محلية فورية.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final parts = raw.split('|');
        if (parts.length == 2) {
          _welcomeEnabled = parts[0] == '1';
          _welcomeText = parts[1];
          _loaded = true;
          return;
        }
      }
    } catch (_) {}

    // 2) من السيرفر.
    final cfg = await SupabaseService.instance.fetchAppConfig();
    if (cfg == null) {
      _loaded = true;
      return;
    }
    _welcomeEnabled = cfg['welcome_enabled'] == true;
    _welcomeText = (cfg['welcome_text']?.toString().trim().isNotEmpty ?? false)
        ? cfg['welcome_text'].toString()
        : welcomeDefault;
    _loaded = true;
    await _cache();
  }

  Future<void> _cache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCacheKey,
        [_welcomeEnabled ? '1' : '0', _welcomeText].join('|'),
      );
    } catch (_) {}
  }

  Future<void> reload() => load(force: true);
}
