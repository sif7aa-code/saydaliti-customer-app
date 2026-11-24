import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/doctor_profile.dart';
import 'auth_service.dart';
import 'supabase_service.dart';

/// عدّادات بروفايل الطبيب كما تحسبها القاعدة (بلا تقييم إطلاقاً):
/// زيارات الملف وعدد من أضافوه للمفضلة.
class DoctorProfileStats {
  const DoctorProfileStats({
    required this.visits,
    required this.favorites,
    required this.isFavorite,
  });

  final int visits;
  final int favorites;
  final bool isFavorite;

  static DoctorProfileStats? fromRow(Map<String, dynamic>? row) {
    if (row == null || row['ok'] != true) return null;
    int n(Object? v) =>
        v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    return DoctorProfileStats(
      visits: n(row['visits']),
      favorites: n(row['favorites']),
      isFavorite: row['is_favorite'] == true,
    );
  }
}

/// قسم في دليل الأطباء: الثلاثة الأساسية (أطباء/مجمعات/مختبرات) + أي
/// قسم جديد يضيفه الأدمن من لوحة التحكم (جدول `doctor_categories`).
class DoctorCategory {
  const DoctorCategory({required this.key, required this.label});

  final String key;
  final String label;

  static DoctorCategory? fromJson(Map<String, dynamic> row) {
    final key = row['key']?.toString().trim() ?? '';
    final label = row['label']?.toString().trim() ?? '';
    return (key.isEmpty || label.isEmpty)
        ? null
        : DoctorCategory(key: key, label: label);
  }
}

/// خدمة دليل الأطباء/المجمعات/المختبرات (جدول `doctors`).
///
/// ★ الكتابة من التطبيق لسهولة الإدارة من لوحة الأدمن عبر
///   `SupabaseService.addDoctor/updateDoctor/deleteDoctor`، ومحمية
///   بسياسات `(select public.admin_gate())` في tmp/doctors_table.sql.
///   [generation] يُنبَّه بعد كل كتابة فتتحدّث الشاشات المفتوحة فوراً.
///
///   الكاش: النسخة الأخيرة الناجحة تُحفظ على القرص (`doctors_v1`) فتظهر
///   الدليل فور فتح الشاشة حتى بلا شبكة، والسحب للتحديث يتجاوزها.
///   ★ لا قائمة مرجعية مدمجة: الجدول الفارغ يعني «لا أطباء» فعلاً — حذف
///   الكل لا يُعيد أطباء تصميم قديمين (بلاغ 2026-11-20).
class DoctorDirectoryService {
  DoctorDirectoryService._();

  static final DoctorDirectoryService instance = DoctorDirectoryService._();

  /// يزداد بعد كل كتابة ناجحة (إضافة/تعديل/حذف) — الشاشات المفتوحة
  /// تستمع إليه فتظهر التغييرات بلا إعادة تشغيل ولا انتظار تبويب.
  final ValueNotifier<int> generation = ValueNotifier<int>(0);

  void _bumpGeneration() {
    if (generation.value < 1 << 30) generation.value++;
  }

  static const String _diskKey = 'doctors_v1';
  static const String _favsKey = 'doctor_favs_v1';

  List<DoctorProfile>? _memory;

  /// ★ زمن آخر **محاولة** شبكة (نجحت أو فشلت). النسخة المعروضة تُعاد
  ///   فوراً دائماً، ثم تُجلب الجديدة بهدوء إن مرّ على المحاولة السابقة
  ///   [revalidateGap]. كان الباب سابقاً «90 ثانية من آخر جلب ناجح»،
  ///   فطبيب يضيفه الأدمن بعد أقل من 90 ثانية من فتح التطبيق لا يصل
  ///   للناس في تلك الجلسة أبداً (لا شيء يعيد المحاولة بعدها) — بلاغ
  ///   2026-11-20 «أضفت طبيب/ممرض ولم يظهر في الدليل».
  DateTime? _lastNetAttempt;

  /// الفاصل بين محاولتين خلفيتين — يمنع حلقة جلب: التحديث الخلفي
  /// ينبّه الشاشات، فتعيد الجلب، ولا نريد طلب شبكة آخر فوراً.
  static const Duration revalidateGap = Duration(seconds: 15);
  static const String _diskTimeKey = 'doctors_v1_at';

  /// إعادة جلب صامتة جارية — تمنع تكرارها مع كل شاشة تطلب القائمة.
  bool _revalidating = false;

  /// أول إطار: الذاكرة إن حُمِّلت، وإلا فارغة — فحذف كل الأطباء يبقى
  /// محذوفاً ولا تعود قائمة مرجعية قديمة للظهور (بلاغ 2026-11-20).
  List<DoctorProfile> get initial => _memory ?? const [];

  /// نسخة من الذاكرة إن حُمِّلت (لتسخين أول إطار قبل أي await).
  List<DoctorProfile>? get memory => _memory;

  /// نسخة معروضة تُعاد فوراً، ويُجدَّد مصدرها في الخلفية إن مضى على آخر
  /// محاولة [revalidateGap] — فما يضيفه الأدمن من جهاز آخر يظهر هنا بلا
  /// سحب ولا إعادة تشغيل، وبلا طلب شبكة مكرّر مع كل إعادة رسم.
  void _maybeRevalidate() {
    if (_revalidating) return;
    final at = _lastNetAttempt;
    if (at != null && DateTime.now().difference(at) < revalidateGap) return;
    _revalidate();
  }

  Future<List<DoctorProfile>> fetch({bool force = false}) async {
    if (force) return _runNetwork();
    if (_memory != null) {
      _maybeRevalidate();
      return _memory!;
    }
    final cached = await _readDisk();
    // ★ القائمة الفارغة المحفوظة نتيجة حقيقية (حُذف الكل) لا «لا كاش»:
    //   كانت تُتجاهل فتظهر قائمة قديمة أو مرجعية بعد الحذف.
    if (cached != null) {
      _memory = cached;
      _maybeRevalidate();
      return cached;
    }
    return _runNetwork();
  }

  /// يعيد قائمة الشبكة الحقيقية ويحدّث الذاكرة والقرص.
  ///
  /// ★ الحذف الكامل يُفرّغ الكاش: الجدول بلا صفوف ⇒ قائمة فارغة تُكتب
  ///   على القرص أيضاً، فلا تعود قائمة قديمة للظهور. أما تعذّر الشبكة
  ///   فلا يمسح المعروض.
  Future<List<DoctorProfile>> _fetchNetwork() async {
    _lastNetAttempt = DateTime.now();
    final rows = await SupabaseService.instance.fetchDoctorsOrNull();
    if (rows == null) {
      final keep = _memory ?? const <DoctorProfile>[];
      _memory = keep;
      return keep;
    }
    final list = rows
        .map((r) => DoctorProfile.fromJson(Map<String, dynamic>.from(r)))
        .toList(growable: false);
    _memory = list;
    await _writeDisk(list);
    return list;
  }

  Future<List<DoctorProfile>> _runNetwork() async {
    _revalidating = true;
    try {
      return await _fetchNetwork();
    } finally {
      _revalidating = false;
    }
  }

  /// نسخة قديمة معروضة الآن: نُظهرها فوراً ثم نجلب الجديد بهدوء
  /// ونُنبّه الشاشات — فالطبيب الجديد يظهر بلا سحب ولا إعادة فتح.
  void _revalidate() {
    if (_revalidating) return;
    _revalidating = true;
    unawaited(() async {
      try {
        await _fetchNetwork();
        _bumpGeneration();
      } catch (_) {
        // بلا شبكة تبقى القائمة المعروضة — هذا هو الغرض من الكاش.
      } finally {
        _revalidating = false;
      }
    }());
  }

  /// بعد كتابة الأدمن: يُسقط الذاكرة والقرص ويعيد الجلب من الشبكة، ثم
  /// يُنبّه الشاشات — فلا تعرض نسخة محفوظة قديمة.
  Future<List<DoctorProfile>> refreshNow() async {
    _memory = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_diskKey);
      await prefs.remove(_diskTimeKey);
    } catch (_) {}
    final list = await fetch(force: true);
    _bumpGeneration();
    return list;
  }

  // ---- أقسام الدليل (شرائح الرئيسية) ----

  /// ★ «الأطباء» وحدها الأساسية: تظهر دائماً — حتى قبل إنشاء الجدول أو
  ///   بلا شبكة، ولا تُحذف من اللوحة. أما «المجمعات الطبية» و«المختبرات»
  ///   فكانتا أساسيتين، وحُذفتا بطلب الأدمن (2026-11-20) مع أي قسم آخر،
  ///   فصار كل قسم غير «الأطباء» قابلاً للحذف من اللوحة.
  static const List<DoctorCategory> builtinCategories = [
    DoctorCategory(key: 'doctors', label: 'الأطباء'),
  ];

  static const String _catsDiskKey = 'doctor_cats_v1';
  static const String _catsDiskTimeKey = 'doctor_cats_v1_at';

  List<DoctorCategory>? _cats;
  DateTime? _catsLastNetAttempt;
  bool _catsRevalidating = false;

  /// أول إطار: آخر قائمة محفوظة، وإلا الأساسية فوراً بلا await.
  List<DoctorCategory> get initialCategories => _cats ?? builtinCategories;

  /// نفس قاعدة الأطباء: الشرائح المعروضة تُعاد فوراً، وتُجدَّد في الخلفية
  /// إذا مرّ [revalidateGap] على آخر محاولة — فقسم يضيفه الأدمن يظهر
  /// للناس في نفس الجلسة بلا إعادة فتح.
  void _maybeRevalidateCategories() {
    if (_catsRevalidating) return;
    final at = _catsLastNetAttempt;
    if (at != null && DateTime.now().difference(at) < revalidateGap) return;
    _revalidateCategories();
  }

  Future<List<DoctorCategory>> fetchCategories({bool force = false}) async {
    if (force) return _fetchCategoriesSafe();
    if (_cats != null) {
      _maybeRevalidateCategories();
      return _cats!;
    }
    final cached = await _readCatsDisk();
    if (cached != null && cached.isNotEmpty) {
      _cats = cached;
      _maybeRevalidateCategories();
      return cached;
    }
    return _fetchCategoriesSafe();
  }

  Future<List<DoctorCategory>> _fetchCategoriesSafe() async {
    final fresh = await _fetchCategoriesNetwork();
    return fresh ?? _cats ?? builtinCategories;
  }

  /// null = تعذّر الجلب (شبكة أو الجدول غير منشأ أو فارغ) — تبقى
  /// المعروضات كما هي بدل أن تُختفي شرائح المستخدم.
  Future<List<DoctorCategory>?> _fetchCategoriesNetwork() async {
    _catsLastNetAttempt = DateTime.now();
    final rows = await SupabaseService.instance.fetchDoctorCategories();
    if (rows.isEmpty) return null;
    final list = rows
        .map((r) => DoctorCategory.fromJson(Map<String, dynamic>.from(r)))
        .whereType<DoctorCategory>()
        .toList(growable: false);
    if (list.isEmpty) return null;
    _cats = list;
    await _writeCatsDisk(list);
    return list;
  }

  void _revalidateCategories() {
    if (_catsRevalidating) return;
    _catsRevalidating = true;
    unawaited(() async {
      try {
        final fresh = await _fetchCategoriesNetwork();
        if (fresh != null) _bumpGeneration();
      } catch (_) {
        // بلا شبكة تبقى الشرائح المعروضة.
      } finally {
        _catsRevalidating = false;
      }
    }());
  }

  /// يضيف الأدمن قسماً جديداً — يظهر في الرئيسية فور نجاحه.
  Future<bool> addCategory(String label) async {
    final name = label.trim();
    if (name.isEmpty) return false;
    // مفتاح لاتيني ثابت لا يتغيّر أبداً (الاسم العربي للعرض فقط).
    final key =
        'cat_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final current = await fetchCategories();
    final ok = await SupabaseService.instance.addDoctorCategory(
      key: key,
      label: name,
      sortOrder: 100 + current.length * 10,
    );
    if (!ok) return false;
    await _afterCategoriesWrite();
    return true;
  }

  /// حذف قسم أضافه الأدمن (الأقسام الأساسية محمية).
  Future<bool> deleteCategory(String key) async {
    if (builtinCategories.any((c) => c.key == key)) return false;
    final ok = await SupabaseService.instance.deleteDoctorCategory(key);
    if (!ok) return false;
    await _afterCategoriesWrite();
    return true;
  }

  /// ★ ترتيب شرائح الدليل الذي يختاره الأدمن (تثبيت الأول والثاني...):
  ///   يُكتب `sort_order` = 10, 20, 30... حسب القائمة المعطاة، فتظهر
  ///   الشرائح للناس بنفس ترتيب شاشة اللوحة. القسم الجديد يبقى آخراً
  ///   لأن `addCategory` يعطيه 100+؛ فلا يزحزح ما ثبّته الأدمن.
  Future<bool> reorderCategories(List<String> orderedKeys) async {
    if (orderedKeys.isEmpty) return false;
    for (var i = 0; i < orderedKeys.length; i++) {
      final ok = await SupabaseService.instance.updateDoctorCategory(
        orderedKeys[i],
        sortOrder: (i + 1) * 10,
      );
      if (!ok) {
        // فشل في المنتصف: نعرض ما استقر عليه الخادم فعلاً بدل وهم محلي.
        await _afterCategoriesWrite();
        return false;
      }
    }
    await _afterCategoriesWrite();
    return true;
  }

  /// بعد كتابة ناجحة: نجلب القائمة الجديدة، وإن فشل الجلب نُبقي السابقة
  /// (فلا تختفي شرائح كانت معروضة بسبب انقطاع لحظي)، ثم نُنبّه الشاشات.
  Future<void> _afterCategoriesWrite() async {
    final prev = _cats;
    final fresh = await _fetchCategoriesNetwork();
    _cats = fresh ?? prev ?? builtinCategories;
    _bumpGeneration();
  }

  Future<List<DoctorCategory>?> _readCatsDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_catsDiskKey);
      if (raw == null || raw.isEmpty) return null;
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => DoctorCategory.fromJson(Map<String, dynamic>.from(m)))
          .whereType<DoctorCategory>()
          .toList(growable: false);
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCatsDisk(List<DoctorCategory> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _catsDiskKey,
        jsonEncode([
          for (final c in list) {'key': c.key, 'label': c.label},
        ]),
      );
      await prefs.setString(_catsDiskTimeKey, DateTime.now().toIso8601String());
    } catch (_) {}
  }

  // ---- المفضلة (على الجهاز فقط، بلا حساب) ----

  Set<String> _favs = {};

  Future<Set<String>> favorites() async {
    if (_favs.isNotEmpty) return _favs;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_favsKey) ?? const [];
      _favs = raw.toSet();
    } catch (_) {}
    return _favs;
  }

  Future<bool> toggleFavorite(String id) async {
    final favs = await favorites();
    final now = !favs.contains(id);
    if (now) {
      favs.add(id);
    } else {
      favs.remove(id);
    }
    _favs = favs;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_favsKey, favs.toList());
    } catch (_) {}
    return now;
  }

  // ---- البروفايل: زيارات ومفضلة حقيقية في القاعدة ----

  /// فتح بروفايل: تسجّل زيارة واحدة لكل حساب/IP — القيد الفريد في
  /// `doctor_visits` يمنع تكرارها — وتعيد العدّادَين الحقيقيين.
  ///
  /// null يعني أن tmp/doctors_profile.sql لم يُشغَّل بعد أو تعذّر
  /// الاتصال؛ الشاشة تعرض أصفاراً وتظل تعمل.
  Future<DoctorProfileStats?> visitProfile(String doctorId) async {
    try {
      final row = await SupabaseService.instance.rpcOne(
        'visit_doctor_profile',
        {
          'p_doctor_id': doctorId,
          'p_patient': AuthService.instance.phone ?? '',
        },
      );
      return DoctorProfileStats.fromRow(row);
    } catch (_) {
      return null;
    }
  }

  /// تبديل المفضلة في القاعدة لهذا الحساب/IP وتعيد العدّادات الجديدة.
  /// تنجح مع الصفوف المزروعة في القاعدة (معرّفات الأطباء المرجعية
  /// المدمجة ليست في القاعدة، فتبقى على المفضلة المحلية).
  Future<DoctorProfileStats?> toggleFavoriteRemote(String doctorId) async {
    try {
      final row = await SupabaseService.instance.rpcOne(
        'toggle_doctor_favorite',
        {
          'p_doctor_id': doctorId,
          'p_patient': AuthService.instance.phone ?? '',
        },
      );
      final stats = DoctorProfileStats.fromRow(row);
      if (stats != null) await _setLocalFavorite(doctorId, stats.isFavorite);
      return stats;
    } catch (_) {
      return null;
    }
  }

  /// مزامنة مفضلة الجهاز مع قرار الخادم — حتى تبقى قلوب الدليل متطابقة.
  Future<void> _setLocalFavorite(String id, bool on) async {
    final favs = await favorites();
    if (on == favs.contains(id)) return;
    if (on) {
      favs.add(id);
    } else {
      favs.remove(id);
    }
    _favs = favs;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_favsKey, favs.toList());
    } catch (_) {}
  }

  // ---- القرص ----

  Future<List<DoctorProfile>?> _readDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_diskKey);
      if (raw == null || raw.isEmpty) return null;
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => DoctorProfile.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
      return list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(List<DoctorProfile> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _diskKey,
        jsonEncode([
          for (final d in list)
            {
              'id': d.id,
              'name': d.name,
              'title': d.title,
              'specialty': d.specialty,
              'info': d.info,
              'phone': d.phone,
              'image_path': d.imagePath,
              'area': d.area,
              'city': d.city,
              'category': d.category,
              'is_featured': d.isFeatured,
              'is_hero': d.isHero,
              'is_verified': d.verified,
              'bio': d.bio,
              'working_hours': d.workingHours,
              'notes': d.notes,
              'clinic_address': d.clinicAddress,
              'facebook_url': d.facebookUrl,
            },
        ]),
      );
      await prefs.setString(_diskTimeKey, DateTime.now().toIso8601String());
    } catch (_) {}
  }
}
