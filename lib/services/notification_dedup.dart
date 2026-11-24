/// سجلّ منع تكرار الإشعارات — مشترك بين كل قنوات العرض، ودائم.
///
/// ★ لماذا هذا الملف؟
///   الإشعار الواحد كان يصل عبر **أربع قنوات مستقلة**:
///     1) استطلاع `NotificationCenter` (كل ٣ ثوانٍ)
///     2) استطلاع `background_poller` (كل دقيقة من الخدمة الأمامية)
///     3) FCM من السيرفر
///     4) `StatusCenter.broadcast` المباشر داخل التطبيق
///   وقبل هذا الملف كانت كل قناة تستعمل مفتاحها الخاص، فكان
///   الإشعار يظهر مرتين (وبصوتين) في الخلفية. الحل: **مفتاح واحد
///   موحّد** + **سجل دائم** ⇒ لا يتكرر الصوت ولا الشعار أبداً،
///   حتى بعد إعادة تشغيل التطبيق أو إعادة تشغيل الهاتف.
///
/// النافذة الزمنية الافتراضية طويلة جداً (٢٤ ساعة) عملياً "أبداً"
/// فيما يخص إشعاراً واحداً بعينه.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationDedup {
  NotificationDedup._();
  static final NotificationDedup instance = NotificationDedup._();

  /// النافذة: يوم كامل. أي إشعار بنفس المفتاح بعدها يُعتبر جديداً.
  static const Duration _window = Duration(hours: 24);

  /// أقصى عدد مفاتيح محفوظة (حماية من تضخّم التخزين).
  static const int _maxKeys = 300;

  static const String _prefsKey = 'notify_announced_v2';

  /// ذاكرة وسيطة ⇒ استدعاءات متزامنة في نفس اللحظة لا تتجاوز،
  /// ولا ننتظر قرصاً في كل مرة.
  static final Map<String, int> _memo = {};

  /// هل عُرض هذا الإشعار من قبل خلال النافذة؟
  ///
  /// **نعم** ⇒ لا تعرضه ولا تنطق ولا تشغّل الصوت مرة أخرى.
  static bool isAnnounced(String? key) {
    if (key == null || key.isEmpty) return false;
    final hit = _memo[key];
    if (hit != null) {
      final age = DateTime.now().millisecondsSinceEpoch - hit;
      if (age < _window.inMilliseconds) return true;
      _memo.remove(key);
    }
    return false;
  }

  /// يطلب «حق العرض» للإشعار. يُرجع true مرة واحدة فقط لكل مفتاح.
  ///
  /// هذا هو **البوابة الوحيدة** التي تمرّ منها كل قنوات العرض.
  static Future<bool> claim(String? key) async {
    if (key == null || key.isEmpty) return true;
    if (isAnnounced(key)) return false;
    _memo[key] = DateTime.now().millisecondsSinceEpoch;

    try {
      final prefs = await SharedPreferences.getInstance();
      // ★★ قراءة طازجة من القرص أولاً: للخلفية عملية (isolate)
      //   مستقلة بنسختها من التخزين، فقد تكون حجزت المفتاح قبل
      //   لحظات. بدون `reload` نقرأ نسخة قديمة فنحجز مرة ثانية ⇒
      //   صوتان لنفس الإشعار.
      await prefs.reload();
      final now = DateTime.now();
      final map = <String, String>{};
      for (final k in prefs.getStringList(_prefsKey) ?? const <String>[]) {
        final sep = k.lastIndexOf('@');
        if (sep <= 0) continue;
        final ts = int.tryParse(k.substring(sep + 1));
        if (ts == null) continue;
        if (now.difference(DateTime.fromMillisecondsSinceEpoch(ts)) > _window) {
          continue; // منتهية ⇒ احذفها
        }
        map[k.substring(0, sep)] = k.substring(sep + 1);
      }
      // ★★ حجزه غيره (عملية أخرى) على القرص ⇒ تراجع.
      if (map.containsKey(key)) {
        _memo.remove(key);
        return false;
      }
      map[key] = now.millisecondsSinceEpoch.toString();

      // اقتطع الأقدم إن تجاوزنا الحد.
      if (map.length > _maxKeys) {
        final sorted = map.keys.toList()
          ..sort((a, b) => (map[a] ?? '0').compareTo(map[b] ?? '0'));
        for (final k in sorted.take(map.length - _maxKeys)) {
          map.remove(k);
        }
      }
      await prefs.setStringList(
        _prefsKey,
        map.entries.map((e) => '${e.key}@${e.value}').toList(),
      );
    } catch (e) {
      // التخزين غير متاح (نادر) — الذاكرة وحدها تكفي للدورة الحالية.
      debugPrint('dedup persist failed: $e');
    }
    return true;
  }

  /// مسح السجل (عند تسجيل الخروج مثلاً — الحسابات منفصلة).
  static Future<void> clear() async {
    _memo.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  /// يبني مفتاح موحّداً لصف إشعار.
  ///
  /// **هذا هو المعيار الوحيد** — كل طبقة عرض تستعمله كما هو،
  /// وإلا ظهر التكرار. المفتاح: `order:{orderId}:{type}` للطلبات،
  /// و`row:{id}` لغيرها.
  static String keyFor({
    String? orderId,
    String? type,
    String? rowId,
  }) {
    if (orderId != null && orderId.isNotEmpty && type != null && type.isNotEmpty) {
      return 'order:$orderId:$type';
    }
    if (rowId != null && rowId.isNotEmpty) return 'row:$rowId';
    if (orderId != null && orderId.isNotEmpty) return 'order:$orderId';
    if (type != null && type.isNotEmpty) return 'type:$type';
    return 'none';
  }
}
