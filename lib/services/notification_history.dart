import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// سجل محلي لسجل الإشعارات على الجهاز فقط (بلا تخزين على السيرفر).
///
/// السبب: جدول notifications صار **طابوراً مؤقتاً** — يُحذف فور تسليمه،
/// فلا يستهلك تخزين Supabase. ولكي لا يفقد المستخدم السجل، نحتفظ بآخر
/// [max] عنصر على الجهاز (حجمه بالكيلوبايتات، لا ميغابايتات).
///
/// ★★ 2026-11-25 (طلب الأدمن): «اجعل الرسائل بالارقام وليست بالكاشات».
///   كان السجل مفتاحاً واحداً للجهاز كله (`notify_history_v1`)، فمن
///   يسجّل الخروج بحساب ويدخل بآخر على نفس الجهاز يرى إشعارات الأول
///   في جرسه — أي «كل الحسابات ترى رسائل بعضها». الآن لكل رقم حساب
///   سجله الخاص، ولا يُقرأ ولا يُكتب شيء بلا حساب داخل.
///   والسجل القديم المختلط يُمسح مرة واحدة عند أول فتح بعد التحديث،
///   فلا يبقى فيه سطر لغيره.
class NotificationHistory {
  NotificationHistory._();
  static final NotificationHistory instance = NotificationHistory._();

  static const int max = 20;

  /// السجل القديم المشترك بين كل الحسابات — يُمسح مرة واحدة.
  static const String _legacyKey = 'notify_history_v1';
  static const String _keyPrefix = 'notify_history_v2_';

  /// نفس مفتاحَي الحساب في `auth_service` (تقرؤهما أيضاً خدمة الخلفية).
  static const String _authPhoneKey = 'auth_phone';
  static const String _authLoggedKey = 'auth_logged_in';

  static bool _legacyPurged = false;

  /// ★ مدة بقاء إشعار الطلب **المكتمل/المرفوض**: ٢٤ ساعة ثم يُحذف
  ///   من سجل الجهاز. بقية الأنواع لا تُمسّ.
  static const Duration doneRetention = Duration(hours: 24);

  /// هل النوع يخص طلباً مكتملاً أو مرفوضاً؟
  ///
  /// الخادم يكتب للزبون `delivered`/`rejected`، وللمندوب
  /// `driver_delivered`/`driver_rejected` ⇒ اللاحقة تكفي.
  static bool isDoneType(String? type) {
    final t = (type ?? '').trim().toLowerCase();
    if (t.isEmpty) return false;
    return t == 'delivered' ||
        t == 'rejected' ||
        t.endsWith('_delivered') ||
        t.endsWith('_rejected');
  }

  /// هل مرّ على الإشعار المكتمل/المرفوض [doneRetention]؟
  static bool isExpiredDone({String? type, String? at, DateTime? now}) {
    if (!isDoneType(type)) return false;
    final dt = DateTime.tryParse((at ?? '').trim());
    if (dt == null) return false;
    return (now ?? DateTime.now()).difference(dt) >= doneRetention;
  }

  /// يحذف من القائمة ما انتهت مدته، ويخبر إن تغيّرت.
  /// ★ رسائل الدردشة تبقى ٢٤ ساعة فقط: تُحذف من القاعدة بعدها، فيجب
  ///   أن يسقط سطرها من جرس الجهاز أيضاً — كان يبقى أبد الدهر.
  static bool isExpiredChat({String? type, String? at, DateTime? now}) {
    if ((type ?? '').trim().toLowerCase() != 'chat') return false;
    final dt = DateTime.tryParse((at ?? '').trim());
    if (dt == null) return false;
    return (now ?? DateTime.now()).difference(dt) >= doneRetention;
  }

  static bool _dropExpired(List<Map<String, dynamic>> list) {
    final before = list.length;
    list.removeWhere(
      (e) =>
          isExpiredDone(type: e['type']?.toString(), at: e['at']?.toString()) ||
          isExpiredChat(type: e['type']?.toString(), at: e['at']?.toString()),
    );
    return list.length != before;
  }

  /// آخر ١٠ أرقام — نفس قاعدة القاعدة في كل مكان.
  static String _last10(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length <= 10) return digits;
    return digits.substring(digits.length - 10);
  }

  /// مفتاح سجل **الحساب الحالي** وحده، أو null إن لم يكن هناك حساب.
  ///
  /// والمسح القديم يقع هنا أول مرة: أي ملف سابق ليس لصاحب حساب واحد
  /// بعينه (كان مفتاحاً واحداً للجهاز) فلا يجوز عرضه لحساب ما.
  static Future<String?> _accountKey(SharedPreferences prefs) async {
    if (!_legacyPurged) {
      _legacyPurged = true;
      if (prefs.containsKey(_legacyKey)) {
        try {
          await prefs.remove(_legacyKey);
        } catch (_) {}
      }
    }
    if (!(prefs.getBool(_authLoggedKey) ?? false)) return null;
    final key = _last10(prefs.getString(_authPhoneKey) ?? '');
    if (key.isEmpty) return null;
    return '$_keyPrefix$key';
  }

  Future<void> add({
    required String title,
    required String body,
    String? type,
    String? logo,
    DateTime? at,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _accountKey(prefs);
      if (key == null) return;
      final raw = prefs.getString(key);
      final list = <Map<String, dynamic>>[];
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) list.add(Map<String, dynamic>.from(e));
          }
        }
      }
      // حذف المنتهي (مكتمل/مرفوض أقدم من ٢٤ ساعة) قبل الإضافة.
      _dropExpired(list);
      // لا نكرر نفس العنوان في نفس الدقيقة.
      final iso = (at ?? DateTime.now()).toUtc().toIso8601String();
      final top = list.isEmpty ? null : list.first;
      if (top != null &&
          top['title'] == title &&
          top['body'] == body &&
          ((DateTime.tryParse(
                        '${top['at']}',
                      )?.difference(at ?? DateTime.now()).inMinutes ??
                      99)
                  .abs() <
              1)) {
        return;
      }
      list.insert(0, {
        'title': title,
        'body': body,
        'type': type,
        'logo': logo,
        'at': iso,
      });
      if (list.length > max) list.removeRange(max, list.length);
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {
      // السجل المحلي ميزة تجميلية — فشله لا يؤثر.
    }
  }

  /// آخر الإشعارات **لهذا الحساب** (الأحدث أولاً)، مع تقليم المنتهي أولاً.
  Future<List<Map<String, dynamic>>> all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _accountKey(prefs);
      if (key == null) return const [];
      final raw = prefs.getString(key);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final list = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (_dropExpired(list)) {
        await prefs.setString(key, jsonEncode(list));
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// حذف عنصر واحد من سجل الحساب الحالي (عند الضغط عليه).
  Future<void> removeOne(String at) async {
    if (at.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _accountKey(prefs);
      if (key == null) return;
      final raw = prefs.getString(key);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list =
          decoded
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
            ..removeWhere((e) => '${e['at']}' == at);
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {}
  }

  /// يمسح سجل الحساب الحالي وحده (سجل الحسابات الأخرى لا يُمسّ).
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _accountKey(prefs);
      if (key == null) return;
      await prefs.remove(key);
    } catch (_) {}
  }
}
