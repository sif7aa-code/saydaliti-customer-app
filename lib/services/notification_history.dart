import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// سجل محلي لسجل الإشعارات على الجهاز فقط (بلا تخزين على السيرفر).
///
/// السبب: جدول notifications صار **طابوراً مؤقتاً** — يُحذف فور تسليمه،
/// فلا يستهلك تخزين Supabase. ولكي لا يفقد المستخدم السجل، نحتفظ بآخر
/// [max] عنصر على الجهاز (حجمه بالكيلوبايتات، لا ميغابايتات).
class NotificationHistory {
  NotificationHistory._();
  static final NotificationHistory instance = NotificationHistory._();

  static const int max = 20;
  static const String _k = 'notify_history_v1';

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
  static bool _dropExpired(List<Map<String, dynamic>> list) {
    final before = list.length;
    list.removeWhere(
      (e) =>
          isExpiredDone(type: e['type']?.toString(), at: e['at']?.toString()),
    );
    return list.length != before;
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
      final raw = prefs.getString(_k);
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
      await prefs.setString(_k, jsonEncode(list));
    } catch (_) {
      // السجل المحلي ميزة تجميلية — فشله لا يؤثر.
    }
  }

  /// آخر الإشعارات (الأحدث أولاً)، مع تقليم المنتهي أولاً.
  Future<List<Map<String, dynamic>>> all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_k);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final list = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (_dropExpired(list)) {
        await prefs.setString(_k, jsonEncode(list));
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// حذف عنصر واحد من السجل المحلي (عند الضغط عليه).
  Future<void> removeOne(String at) async {
    if (at.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_k);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list =
          decoded
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
            ..removeWhere((e) => '${e['at']}' == at);
      await prefs.setString(_k, jsonEncode(list));
    } catch (_) {}
  }

  /// عدد غير المقروء محلياً (غير مستخدم حالياً: كل إشعار كان معروضاً).
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_k);
    } catch (_) {}
  }
}
