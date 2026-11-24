/// ★★ حارس المنتجات المحذوفة — «حُذف ⇒ لا يظهر مرة أخرى أبداً، ولو كاش».
///
/// المشكلة التي يحلّها هذا الملف (بلاغ الأدمن ٢٠٢٦-١٠-٢٨: «عند حذف منتج
/// يبقى ظاهرًا في الشاشة الرئيسية للزبائن»):
///
///   الحذف في القاعدة نهائي (`delete_product` يمسح الصف)، لكن نسخ الكتالوج
///   المحلية تعيش في مكانين: ذاكرة `_Dataset._value` وقرص `CatalogCache`.
///   وكان المسار القديم هكذا:
///     ١) يصل حدث `product.deleted` ⇒ `purgeProductFromCaches` يمسح السطر
///        من القرص ويُبطِل الذاكرة؛
///     ٢) وفي **نفس اللحظة** كان هناك جلب شبكة **جارٍ أصلاً** (بدأ قبل
///        الحذف، أو أطلقه `refreshProducts` مباشرة بعد المسح)؛
///     ٣) ذلك الجلب يرجع بالسطر المحذوف (لأنه انطلق قبل الحذف)، فيكتبه في
///        الذاكرة **وفي القرص من جديد** — فيعود المنتج بعد اختفاءٍ ثانيةٍ
///        واحدة، ويُسكِت مقارن الهوية التحديثَ لأن «قبل = بعد».
///   والنتيجة: يبقى المحذوف معروضاً على الرئيسية حتى يُغلق الزبون التطبيق
///   ويعيده — وهو بالضبط ما شكا منه.
///
/// العلاج: شاهد (tombstone) لكل معرّف حُذف. أي صف يحمل هذا المعرّف يُطرَد
/// في **كل** قراءة — من القرص أو من الشبكة — مهما كانت ترتيبات التزامن،
/// فلا يوجد مسار «يُحيي» المحذوف. والشاهد ينتهي من نفسه بعد [ttl]؛
/// لو أعاد الأدمن إنشاء منتج فله معرّف uuid جديد لا يتعارض معه.
///
/// لا شبكة هنا ولا قرص: كائن نقي تماماً، لأنه يُختبَر بلا إضافات.
class DeletedProductsGuard {
  DeletedProductsGuard({
    this.ttl = _defaultTtl,
    this.maxEntries = _defaultMaxEntries,
  });

  /// ★ خمس عشرة دقيقة: أوسع من أي عمر كاش في التطبيق (الذاكرة ٦٠ ثانية،
  ///   ونسخة القرص تُستبدل عند كل جلب)، وأضيق من جلسة استخدام طويلة
  ///   يتوقع فيها الأدمن إعادة نشر.
  static const Duration _defaultTtl = Duration(minutes: 15);
  static const int _defaultMaxEntries = 512;

  final Duration ttl;
  final int maxEntries;

  final Map<String, DateTime> _marked = <String, DateTime>{};

  /// كم شاهداً حيّاً الآن؟ (للاختبار والتشخيص)
  int get length => _marked.length;

  /// هل لهذا المعرّف شاهد حيّ؟ يسقط المنتهي تلقائياً عند السؤال.
  bool blocks(String id, {DateTime? at}) {
    if (id.isEmpty) return false;
    final markedAt = _marked[id];
    if (markedAt == null) return false;
    final now = at ?? DateTime.now();
    if (now.difference(markedAt) >= ttl) {
      _marked.remove(id);
      return false;
    }
    return true;
  }

  /// سجّل حذف منتج. السطر الفارغ لا يُسجَّل (لو كان المعرّف مجهولاً
  /// فالحذف سيُطبَّق بمسارات أخرى، ولا نملك حق إخفاء كل المنتجات).
  void mark(String id, {DateTime? at}) {
    if (id.isEmpty) return;
    _marked[id] = at ?? DateTime.now();
    // ترتيب الإدخال = ترتيب القِدم في الخريطة، فالتقليم يحذف الأقدم.
    if (_marked.length > maxEntries) {
      final excess = _marked.length - maxEntries;
      var i = 0;
      _marked.removeWhere((deadId, deadAt) => ++i <= excess);
    }
  }

  /// ★ فلترة صف واحد: يُبقي ما لا شاهد عليه ويسقط المحذوف.
  ///
  /// تُستدعى داخل `parse` لكل مجموعة منتجات (الكتالوج الكامل ونسخ كل
  /// صيدلية) — أي في **المجر وحده**، فتغطي القرص والشبكة معاً بلا حاجة إلى
  /// تنسيق بين المسارات.
  bool keeps(Map<String, dynamic> row, {DateTime? at}) {
    final id = row['id']?.toString() ?? '';
    return !blocks(id, at: at);
  }

  /// نسخة مفلترة من صفوف كثيرة (راحة المستدعين + اختبار مباشر).
  List<Map<String, dynamic>> filterRows(
    List<Map<String, dynamic>> rows, {
    DateTime? at,
  }) =>
      rows.where((r) => keeps(r, at: at)).toList(growable: false);

  /// ★ إسقاط شاهد بعد ثبوت أنه كان إنذاراً كاذباً.
  ///
  /// لماذا هذا موجود: الحذف الحقيقي لا رجعة فيه (الصف مُحِي من القاعدة،
  ///   والمعرّف uuid لا يُعاد استعماله)، فظهور المعرّف في جلبٍ **طازج**
  ///   يعني أن الحدث كان
  ///   كذباً — لا أن المنتج «عاد إلى الحياة». بلا هذه البوابة يكفي ردّ شبكة
  ///   ناقص من السيرفر ليُخفي منتجاً حيّاً خمس عشرة دقيقة، وهذا أسوأ من
  ///   الشكوى الأصلية. انظر [RealDataService.recheckDeletedProduct].
  void unmark(String id) => _marked.remove(id);

  /// كل الشواهد الحيّة (للتشخيص عند فحص الهاتف).
  List<String> get liveIds => _marked.keys.toList(growable: false);

  /// مسح كامل: عند تبديل الحساب أو تفريغ الكتالوج من الذاكرة إلى الصفر،
  /// لأن الشواهد تخصّ الجلسة السابقة لا هذه.
  void clear() => _marked.clear();
}
