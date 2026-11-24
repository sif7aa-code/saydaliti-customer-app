import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../services/auth_service.dart';
import '../services/real_data_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';

/// ★ منتجات صاحب الصيدلية — تعديل وحذف لكل منتج.
///
/// ★ تعديل السعر **ينشر نفسه فوراً** على الطلبات غير المكتملة التي تحمل
///   المنتج — لكن الناشر الآن هو **القاعدة** (تريجر `trg_products_price_cascade`
///   على `products.price`، ملف `SQL_PRICE_LIVE_FOR_ALL.sql`) لا حلقة نداءات
///   من هذا الجهاز: فالبند يُحدَّث والإجمالي يُعاد والزبون يُشعر في نفس
///   لحظة الحفظ، ومن أي مصدر جاء التغيير.
class ShopOwnerProductsScreen extends StatefulWidget {
  const ShopOwnerProductsScreen({super.key, this.onChanged});

  /// ★ يُستدعى بعد كل تغيير ناجح (إطفاء/تشغيل/تعديل/حذف).
  ///
  /// ★ لماذا لا نكتفي بانتظار حدث السيرفر؟ لأن الحدث يصل بعد
  ///   دورة استطلاع (≈ثانيتان) وقد لا يصل إطلاقاً إن كان
  ///  notify-server متوقف، فيبقى معطلاً في كاش التاجر
  ///   رغم أن القاعدة متغيّرة. أما الزبائن فمسارهم منفصل (§
  ///   `RealtimeService`) ولا يُعالَج هنا.
  final Future<void> Function()? onChanged;

  @override
  State<ShopOwnerProductsScreen> createState() =>
      _ShopOwnerProductsScreenState();
}

class _ShopOwnerProductsScreenState extends State<ShopOwnerProductsScreen>
    with TabRefreshTarget<ShopOwnerProductsScreen> {
  @override
  String get tabId => 'owner_products';

  /// ★ نقرة زرّ «منتجاتي»: تصعد لأول منتج وتعيد القائمة من القاعدة —
  ///   فيرى سعره الجديد أو المنتج المحذوف مع الرنّة.
  @override
  Future<void> Function() onTabRefresh() => _load;

  List<Map<String, dynamic>> _products = [];
  String _shopId = '';
  String _shopName = '';
  bool _loading = true;
  String? _error;

  /// ★ بحث محلي بالاسم — التاجر يكتب جزءاً من اسم المنتج فيتصفّى
  ///   فوراً. القاعدة هي المصدر الكامل أصلاً (قائمة صيدليته صغيرة)،
  ///   فلا حاجة لرحلة خادم مع كل حرف.
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final phone = AuthService.instance.phone ?? '';
    var shop = await SupabaseService.instance.fetchShopByOwnerPhone(phone);
    // إعادة محاولة واحدة: انقطاع شبكة لحظي عند فتح الشاشة كان يعرض
    // «لا يوجد صيدلية مرتبط» رغم وجود صيدلية (الدالة تُرجع null عند أي خطأ).
    if (shop == null && phone.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 400));
      shop = await SupabaseService.instance.fetchShopByOwnerPhone(phone);
    }
    final shopId = shop?['id']?.toString() ?? '';
    final products = shopId.isEmpty
        ? <Map<String, dynamic>>[]
        : await SupabaseService.instance.fetchProducts(shopId: shopId);
    if (!mounted) return;
    setState(() {
      _products = products;
      _shopId = shopId;
      _shopName = shop?['name']?.toString().trim() ?? '';
      _loading = false;
      if (shopId.isEmpty) _error = 'لا توجد صيدلية مرتبطة بهذا الحساب';
    });
  }

  double _d(Object? v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  void _toast(String msg, bool ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
          // ★ 6 ثوانٍ: الرسالة صارت سطرًا ثانيًا فيه عدد المنتجات الجديد.
          duration: const Duration(seconds: 6),
        ),
      );
  }

  /// ★ عدد منتجات الصيدلية **المعروضة للزبائن** (`is_active = true`) بعد العملية
  ///   — وهو رقم «منتجات» في بطاقة «أصحاب الصيدليات» عند الأدمن، فلا يتناقضان.
  ///   يُستعمل بعد تجديد القائمة (`_products`) في رسالة الإضافة/التعديل/
  ///   الإطفاء/الحذف؛ وعند الفشل لا يُذكر رقم.
  String _countTail() {
    final shown = _products.where((e) => e['is_active'] == true).length;
    return ' · عدد منتجاتك المعروضة الآن $shown';
  }

  Future<void> _edit(Map<String, dynamic> p) async {
    final id = p['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final nameCtrl = TextEditingController(text: p['name']?.toString() ?? '');
    final priceCtrl = TextEditingController(
      text: _d(p['price']).toStringAsFixed(0),
    );
    var editRx = p['requires_prescription'] == true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تعديل المنتج',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: 'اسم المنتج',
                labelStyle: GoogleFonts.cairo(),
                border: const OutlineInputBorder(),
              ),
              style: GoogleFonts.cairo(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'السعر',
                labelStyle: GoogleFonts.cairo(),
                border: const OutlineInputBorder(),
              ),
              style: GoogleFonts.cairo(),
            ),
            const SizedBox(height: 10),
            // ★ نشرُ السعر على الطلبات الجارية سلوك ظاهر، فيُعلن.
            Text(
              'تغيير السعر ينشره فوراً على الطلبات غير المكتملة '
              'التي تحمل هذا المنتج، ويتصل بصاحبها.',
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                height: 1.6,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            // ★ يتطلب وصفة طبية — عند تفعيله لا يُقبل طلب المنتج بلا صورة
            //   وصفة مرفقة في السلة، وتظهر الوصفة للصيدلي وللأدمن فقط.
            Container(
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                value: editRx,
                onChanged: (v) => setDialogState(() => editRx = v),
                title: Text(
                  'يتطلب وصفة طبية',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  'الزبون لن يُرسل طلبه بلا صورة وصفة مرفقة',
                  style: GoogleFonts.cairo(fontSize: 11),
                ),
                secondary: const Icon(Icons.medical_information_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('حفظ', style: GoogleFonts.cairo()),
          ),
        ],
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final newPrice = double.tryParse(priceCtrl.text.trim()) ?? 0;
    final newName = nameCtrl.text.trim();
    final oldPrice = _d(p['price']);
    if (newPrice <= 0) {
      _toast('السعر يجب أن يكون أكبر من صفر', false);
      return;
    }

    final ok = await SupabaseService.instance.updateProduct(id, {
      'name': newName.isEmpty ? p['name'] : newName,
      'price': newPrice,
      // ★ وصفة طبية: تُفعَّل/تُلغى من هنا كما من لوحة الأدمن.
      'requires_prescription': editRx,
    });
    if (!mounted) return;
    if (!ok) {
      _toast('تعذّر حفظ التعديل', false);
      return;
    }

    // ★ النشر صار في القاعدة نفسها (تريجر `products.price` — ملف
    //   `SQL_PRICE_LIVE_FOR_ALL.sql`): بند كل طلبٍ جارٍ يأخذ سعرك الجديد
    //   لحظة الحفظ، ويُعاد حساب إجمالي الطلب، ويُشعر الزبون بنغمة
    //   «تغيّر سعر» — وي عمل هذا مهما كان مصدر التغيير (لوحتك أو شاشةك أو
    //   تصحيح يدوي في القاعدة).
    //   ★ حُذف النداء الذي كان هنا (`propagateProductPriceToOpenOrders`)
    //   لأنه كان يعيد الكتابة بعد نجاح الحفظ فيُشعر الزبون مرتين على الطلب
    //   نفسه، ويترك السعر معلّقاً إن أُغلق الجهاز قبل أن تكتمل الحلقة —
    //   والدالة باقية في الخدمة لمن يريد النشر اليدوي.
    final priceChanged = newPrice != oldPrice;
    if (!mounted) return;
    // ★ قائمتنا تُجدَّد أولاً — كالإطفاء والحذف تماماً — ثم تُعرض الرسالة،
    //   حتى يكون «عدد المنتجات المعروضة» المذكور هو الرقم **بعد** الحفظ.
    //   اختبار حقيقي على الجهاز كشف أن البطاقة كانت تبقى بالسعر
    //   القديم بعد «حفظ» حتى تحديث يدوي، فيظنّ التاجر أن الحفظ
    //   فشل وهو نجح على الخادم.
    final fresh = await SupabaseService.instance.fetchProducts(shopId: _shopId);
    if (!mounted) return;
    setState(() => _products = fresh);
    _toast(
      priceChanged
          ? 'تم الحفظ · السعر $newPrice نافذ فوراً على طلباتك الجارية'
          : 'تم الحفظ'
                '${_countTail()}',
      true,
    );
    // ★ نفس `[onChanged]` المستعمل في الإطفاء: تعديل السعر والسعر
    //   يغيّران ما يراه الزبون، فكاش الكتالوج عند التاجر يجب أن
    //   يتحدّث الآن لا عند إعادة فتح الشاشة.
    await widget.onChanged?.call();
  }

  /// ★ إطفاء/تشغيل المنتج.
  ///
  /// ★ الإطفاء **يخفيه فوراً عن كل الزبائن**: الاستعلامات تصفّي
  ///   `is_active=eq.true` على الخادم، والحدث يُبَثّ للزبائن فيُحدِّث
  ///   كاشهم خلال ثوانٍ — بلا فتح التطبيق.
  ///
  /// ★ ولا يمسّ الطلبات الجارية: سطور الطلبsnapshot كاملة (اسم +
  ///   سعر)، فطلبٌ فيه هذا المنتج يبقى صحيحاً بعد الإطفاء.
  ///
  /// ★ [onChanged] يُستدعى بعد نجاح التحديث فقط — تستعمله الكتالوج
  ///   لتحديث كاشها فوراً (بلا انتظار الحدث next من السيرفر).
  Future<void> _toggle(Map<String, dynamic> p, bool on) async {
    final id = p['id']?.toString() ?? '';
    final name = p['name']?.toString() ?? 'المنتج';
    if (id.isEmpty) return;
    setState(() => _busyId = id);
    final ok = await SupabaseService.instance.updateProduct(id, {
      'is_active': on,
    });
    if (!mounted) return;
    if (!ok) {
      setState(() => _busyId = null);
      _toast('تعذّر تغيير حالة المنتج', false);
      return;
    }
    // ★ التاجر يرى منتجاته كلها — المعطّل منها included — فالجلب
    //   هنا بلا `activeOnly`، وهذا سبب حاجتنا لتحديث القائمة.
    final fresh = await SupabaseService.instance.fetchProducts(shopId: _shopId);
    if (!mounted) return;
    setState(() {
      _products = fresh;
      _busyId = null;
    });
    await widget.onChanged?.call();
    if (!mounted) return;
    _toast(
      '${on ? 'تم تشغيل «$name»' : 'تم إطفاء «$name» — اختفى من الزبائن'}'
      '${_countTail()}',
      true,
    );
  }

  String? _busyId;

  Future<void> _delete(Map<String, dynamic> p) async {
    final id = p['id']?.toString() ?? '';
    final name = p['name']?.toString() ?? 'المنتج';
    if (id.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف $name',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'يُحذف المنتج من الكتالوج. الطلبات السابقة تحتفظ بسطرها.',
          style: GoogleFonts.cairo(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text('حذف', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await SupabaseService.instance.deleteProduct(id);
    if (!mounted) return;
    if (!ok) {
      _toast(
        SupabaseService.instance.lastDeleteError.isEmpty
            ? 'تعذّر الحذف'
            : SupabaseService.instance.lastDeleteError,
        false,
      );
      return;
    }
    // ★ الحذف **فوراً لكل الناس وعلى هذا الجهاز**: يُقصى المعرّف من نسخ
    //   القرص (الكتالوج + نسخ الصيدليات) قبل أي رسم، فلا يبقى منتج محذوف
    //   معروضاً من كاش. بقية المنتجات لا تُمسّ.
    // `deletionConfirmed: true` — نجاح ردّ السيرفر معروف قبل هذا السطر،
    //   فتُحرَّر صورة المنتج من القرص والذاكرة في نفس اللحظة.
    await RealDataService.instance.purgeProductFromCaches(
      id,
      deletionConfirmed: true,
    );
    // ★★ 2026-11-08 (تقليل الاستهلاك بلا تغيير سلوك):
    //   كان: `_load()` يعيد طلب صيدلية + طلب منتجات (٢) ثم `onChanged`
    //   يستدعي `refreshProducts()` (طلب منتجات ثالث). الحذف مؤكّد،
    //   فنحذف السطر محلياً فوراً ونحدّث الكتالوج العام مرة واحدة فقط.
    if (!mounted) return;
    setState(() {
      _products = List<Map<String, dynamic>>.from(_products)
        ..removeWhere((e) => e['id']?.toString() == id);
    });
    await widget.onChanged?.call();
    if (!mounted) return;
    _toast('تم حذف المنتج${_countTail()}', true);
  }

  @override
  Widget build(BuildContext context) {
    // ★ القائمة المعروضة = تصفية البحث المحلية (أو الكل بلا بحث).
    final q = _query.trim();
    final shown = q.isEmpty
        ? _products
        : _products
              .where((p) => (p['name']?.toString() ?? '').contains(q))
              .toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'منتجاتي',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        // ★ «تحديث» في البداية (يمين RTL) لا في `actions`.
        //   أزرار `actions` في RTL تهبط على الحافة **اليسرى** —
        //   حيث يطفو زر الخروج العائم في `ShopOwnerShell` فوقها
        //   فيبتلع اللمس. اختبار حقيقي على الجهاز: النقر على
        //   «تحديث» كان يفتح نافذة الخروج ولا يحدّث القائمة أبداً.
        leading: IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loading ? null : () => AppRefresh.run(_load),
          tooltip: 'تحديث',
        ),
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_products.isEmpty
                  ? ListView(
                      controller: tabScroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 90),
                        Center(
                          child: Text(
                            _error ?? 'لا توجد منتجات. أضِفها من لوحة الأدمن.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.cairo(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: tabScroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(12),
                      itemCount: shown.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          final off = _products
                              .where((e) => e['is_active'] != true)
                              .length;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  // ★ عدّ المعطّل: التاجر قد ينسى أنه أطفأ
                                  //   منتجاً، فيظنّ أن الزبائن يرونه.
                                  '$_shopName · ${_products.length} منتج'
                                  '${off > 0 ? ' · $off مطفأ' : ''}',
                                  style: GoogleFonts.cairo(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: off > 0
                                        ? AppColors.danger
                                        : AppColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // ★ زرّ البحث: تصفية فورية بالاسم.
                                TextField(
                                  controller: _searchCtrl,
                                  onChanged: (v) => setState(() => _query = v),
                                  textInputAction: TextInputAction.search,
                                  style: GoogleFonts.cairo(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    filled: true,
                                    fillColor: AppColors.surface,
                                    hintText: 'بحث باسم المنتج…',
                                    hintStyle: GoogleFonts.cairo(
                                      fontSize: 13,
                                      color: AppColors.textHint,
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.search_rounded,
                                      size: 20,
                                      color: AppColors.textSecondary,
                                    ),
                                    suffixIcon: q.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: 'مسح البحث',
                                            onPressed: () {
                                              _searchCtrl.clear();
                                              setState(() => _query = '');
                                            },
                                            icon: const Icon(
                                              Icons.close_rounded,
                                              size: 18,
                                            ),
                                          ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(
                                        color: AppColors.divider,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(
                                        color: AppColors.divider,
                                      ),
                                    ),
                                  ),
                                ),
                                if (shown.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 28),
                                    child: Text(
                                      'لا نتائج مطابقة لـ «$q»',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.cairo(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }
                        final p = shown[i - 1];
                        final isOn = p['is_active'] == true;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: AppColors.divider),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: AppImage(
                                      p['image_path']?.toString() ??
                                          p['logo_image']?.toString() ??
                                          '',
                                      width: 56,
                                      height: 56,
                                      fit: BoxFit.cover,
                                      cacheWidth: 112,
                                      cacheHeight: 112,
                                      errorBuilder: (_, _, _) =>
                                          const ColoredBox(
                                            color: AppColors.surfaceTint,
                                          ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p['name']?.toString() ?? 'منتج',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.cairo(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w900,
                                          // ★ المعطّل باهت + كلمة
                                          //   «مطفأ»: يُفهم أنه
                                          //   اختفى عن الزبائن بلا
                                          //   قراءة واجهة.
                                          color: isOn
                                              ? AppColors.textPrimary
                                              : AppColors.textHint,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text(
                                            CurrencyFormatter.format(
                                              _d(p['price']),
                                            ),
                                            style: GoogleFonts.cairo(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              color: isOn
                                                  ? AppColors.primary
                                                  : AppColors.textHint,
                                            ),
                                          ),
                                          if (!isOn) ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              'مطفأ',
                                              style: GoogleFonts.cairo(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                                color: AppColors.danger,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                // ★ المقبض قبل التعديل والحذف: الإطفاء
                                //   أكثر تكراراً من الحذف.
                                if (_busyId == '${p['id']}')
                                  const SizedBox(
                                    width: 42,
                                    height: 42,
                                    child: Center(
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  Tooltip(
                                    message: isOn
                                        ? 'إطفاء — يختفي من الزبائن'
                                        : 'تشغيل — يظهر للزبائن',
                                    child: Switch(
                                      value: isOn,
                                      activeThumbColor: AppColors.success,
                                      onChanged: (v) => _toggle(p, v),
                                    ),
                                  ),
                                IconButton(
                                  tooltip: 'تعديل',
                                  onPressed: () => _edit(p),
                                  icon: const Icon(
                                    Icons.edit_rounded,
                                    size: 20,
                                    color: AppColors.primary,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'حذف',
                                  onPressed: () => _delete(p),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                    color: AppColors.danger,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    )),
      ),
    );
  }
}
