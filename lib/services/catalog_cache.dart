import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// ذاكرة دائمة صغيرة على الجهاز لنسخ الكتالوج (أقسام/صيدليات/منتجات/بانرات).
/// تجعل الشاشات تعرض المحتوى فوراً عند فتح التطبيق حتى مع بطء أو انقطاع
/// الإنترنت، ثم تُحدَّث البيانات في الخلفية من السيرفر (stale-while-revalidate).
class CatalogCache {
  CatalogCache._();
  static final CatalogCache instance = CatalogCache._();

  /// أقصى عمر تُعتبر معه النسخة «حديثة»؛ لا يُطبَّق على العرض — نحن لا
  /// نرمي البيانات أبداً، فقط نحدّثها في الخلفية عند توفر الاتصال.
  static const Duration maxAge = Duration(days: 1);

  final Map<String, List<Map<String, dynamic>>?> _mem = {};

  /// مرآة الذاكرة للنسخ المفردة (سجل طلبات / لقطة تتبّع)، بمفتاح كامل.
  final Map<String, Map<String, dynamic>?> _objMem = {};
  Future<SharedPreferences>? _prefs;

  Future<SharedPreferences> get _store =>
      _prefs ??= SharedPreferences.getInstance();

  /// يُقرأ دائماً المحفوظ: لا نرمي البيانات أبداً عند ضعف/انقطاع الشبكة،
  /// فقط نحدّثها في الخلفية عند توفر الاتصال.
  /// يُعيد null فقط إن لم توجد نسخة محفوظة أصلاً.
  Future<List<Map<String, dynamic>>?> read(String key) async {
    final cached = _mem[key];
    if (cached != null) return cached;
    try {
      final prefs = await _store;
      final raw = prefs.getString('catalog_$key');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final rows = ((data['rows'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _mem[key] = rows;
      return rows;
    } catch (_) {
      return null;
    }
  }

  /// يحفظ نسخة من الصفوف مع وقت الحفظ.
  Future<void> write(String key, List<Map<String, dynamic>> rows) async {
    _mem[key] = rows;
    try {
      final prefs = await _store;
      await prefs.setString(
        'catalog_$key',
        jsonEncode({
          'saved_at': DateTime.now().toIso8601String(),
          'rows': rows,
        }),
      );
    } catch (_) {}
  }

  /// يحذف النسخة المخزّنة (يُستدعى من لوحة الأدمن بعد أي تعديل).
  Future<void> clearFor(String key) async {
    _mem.remove(key);
    try {
      final prefs = await _store;
      await prefs.remove('catalog_$key');
    } catch (_) {}
  }

  /// ★ أقصى سطراً واحداً بمعرفه من **كل** النسخ التي تبدأ بـ [keyPrefix]
  ///   على القرص، وأعاد المفاتيح التي تغيّرت فعلاً.
  ///
  /// لماذا لا تكفي `clearFor`/`write` على مفتاح واحد؟ لأن نسخ الصيدليات
  /// تُحفظ بأسماء `products_<shopId>` يولّدها الكاش عند أول فتح لكل صيدلية:
  /// قائمة المفاتيح في الذاكرة تكون فارغة بعد تشغيل التطبيق، فلا يعرف
  /// أحد أيّ نسخة تحمل المنتج المحذوف. هنا نسأل القرص نفسه، فتمسح
  /// **كل** نسخة عليها ذلك السطر — وتبقى بقيتها كما هي حرفياً.
  Future<List<String>> purgeRowFrom(String keyPrefix, String id) async {
    if (id.isEmpty) return const [];
    return purgeWhereFrom(
      keyPrefix,
      (r) => (r['id']?.toString() ?? '') == id,
    );
  }

  /// ★ يمسح من **كل** النسخ التي تبدأ بـ [keyPrefix] الأسطر التي يقبلها
  ///   [drop]، ويعيد المفاتيح التي تغيّرت فعلاً.
  ///
  /// وهو العمود الذي يقوم عليه حذف الصيدلية: منتجات الصيدلية تُعرَف بـ
  /// `shop_id` لا بـ `id`، فلا تنفع `purgeRowFrom`. و[removeKey] يحذف
  /// مفتاح نسخة كاملة (نسخة الصيدلية المحذوف نفسه) بدل تفريغها.
  Future<List<String>> purgeWhereFrom(
    String keyPrefix,
    bool Function(Map<String, dynamic> row) drop, {
    String? removeKey,
  }) async {
    final touched = <String>[];
    try {
      final prefs = await _store;
      for (final full in prefs.getKeys().toList()) {
        if (!full.startsWith('catalog_$keyPrefix')) continue;
        final key = full.substring('catalog_'.length);
        if (removeKey != null && key == removeKey) {
          _mem.remove(key);
          await prefs.remove(full);
          touched.add(key);
          continue;
        }
        final raw = prefs.getString(full);
        if (raw == null) continue;
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final rows = ((data['rows'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final kept = rows.where((r) => !drop(r)).toList(growable: false);
        if (kept.length == rows.length) continue; // لا سطر هنا
        _mem[key] = kept;
        await prefs.setString(
          full,
          jsonEncode({
            'saved_at': DateTime.now().toIso8601String(),
            'rows': kept,
          }),
        );
        touched.add(key);
      }
    } catch (_) {}
    return touched;
  }

  // ── نسخ مفردة (ليست صفوف كتالوج) ───────────────────────────────────────
  //
  // ★ لماذا طريقة منفصلة عن `read`/`write`؟
  //   الشاشات الخاصة بالزبون (سجل طلباتي، تتبّع طلب) لا تحفظ «قائمة صفوف»
  //   بل حالة شاشة كاملة (قائمة + بيانات مشحونة + اسم المندوب). المفتوح
  //   هنا هو ما رسمته الشاشة آخر مرة، فيُعرض فوراً في الإطار التالي قبل
  //   أي رحلة شبكة — وهو المطلوب: «تخزين محلي يسرّع الفتح».
  //   لا علاقة له بلوحة الأدمن: مفاتيح مختلفة تماماً ولا تُقرَأ من أي
  //   شاشة أدمن.

  /// يقرأ النسخة المفردة محفوظة تحت `snap_<key>` (مع وقت الحفظ في
  /// `_saved_at`). يُعيد null إن لم توجد نسخة.
  Future<Map<String, dynamic>?> readObject(String key) async {
    final cached = _objMem[key];
    if (cached != null) return cached;
    try {
      final prefs = await _store;
      final raw = prefs.getString('snap_$key');
      if (raw == null) return null;
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _objMem[key] = data;
      return data;
    } catch (_) {
      return null;
    }
  }

  /// يحفظ النسخة المفردة. لا ينتظر نجاح القرص: الفشل هنا يعني فقط أن
  /// الافتتاح القادم سيكون من الشبكة، ولا يجب أن يعطّل العرض الحالي.
  Future<void> writeObject(String key, Map<String, dynamic> data) async {
    _objMem[key] = data;
    try {
      final prefs = await _store;
      final payload = Map<String, dynamic>.from(data);
      payload['_saved_at'] = DateTime.now().toIso8601String();
      await prefs.setString('snap_$key', jsonEncode(payload));
    } catch (_) {}
  }

  /// يحذف نسخة مفردة (تسجيل الخروج / طلب جديد لنفس الزبون).
  Future<void> clearObject(String key) async {
    _objMem.remove(key);
    try {
      final prefs = await _store;
      await prefs.remove('snap_$key');
    } catch (_) {}
  }

  /// ★ يمسح **كل** اللقطات المفردة عند تسجيل الخروج.
  ///
  /// لماذا؟ اللقطات محفوظة بأرقام الهواتف ومعرفات الطلبات، فلو بقيت بعد
  /// الخروج لتصفّحها حسابٌ آخر على الجهاز نفسه (محل هاتفات، جهاز عائلي).
  /// المسح آمن تماماً: الشبكة هي المصدر، وهذه نسخ عرض فقط تُكتب من جديد
  /// عند أول فتح. لا تمس لقطات الكتالوج (`catalog_*`) فهي عامة بلا بيانات
  /// شخصية، ومسحها يُبطئ الفتح — أي عكس المطلوب.
  Future<void> clearAllObjects() async {
    _objMem.clear();
    try {
      final prefs = await _store;
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith('snap_')) await prefs.remove(key);
      }
    } catch (_) {}
  }
}
