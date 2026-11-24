import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/keyboard_sheet.dart';
import '../core/utils/shop_rename.dart';
import '../services/doctor_directory_service.dart';
import '../services/real_data_service.dart';
import '../services/recent_view_store.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/app_image.dart';
import 'admin_products_screen.dart';

/// خط عربي موحّد لعناصر قوائم الاختيار في لوحة الأدمن.
///
/// ★ `DropdownButtonFormField` بلا `style`/`itemTextStyle` يرث الخط الافتراضي
///   في Material (Roboto) لا Cairo، فتظهر العربية بخط مختلف تماماً عن بقية
///   الشاشة — وهو ما كان يحدث في قائمتَي «القسم» و«أيام العمل».
TextStyle get _dropStyle => GoogleFonts.cairo(
  fontSize: 13.5,
  fontWeight: FontWeight.w600,
  color: AppColors.textPrimary,
);

/// إدارة الصيدليات: إضافة صيدلية مع صورة من المعرض (تُضغط وتُحفظ محلياً)، حذف صيدلية.
class AdminShopsScreen extends StatefulWidget {
  const AdminShopsScreen({super.key});

  @override
  State<AdminShopsScreen> createState() => _AdminShopsScreenState();
}

class _AdminShopsScreenState extends State<AdminShopsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _shops = [];
  List<Map<String, dynamic>> _categories = [];

  /// أقسام الرئيسية (دليل الأقسام) — لنقل صيدلية إليها.
  List<DoctorCategory> _doctorCats = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait<Object>([
      SupabaseService.instance.fetchShops(),
      SupabaseService.instance.fetchCategories(),
      DoctorDirectoryService.instance.fetchCategories(force: true),
    ]);
    await RealDataService.instance.clearCache();
    RealDataService.instance.catalogGeneration.value++;
    if (!mounted) return;
    setState(() {
      _shops = results[0] as List<Map<String, dynamic>>;
      _categories = results[1] as List<Map<String, dynamic>>;
      _doctorCats = results[2] as List<DoctorCategory>;
      _loading = false;
    });
  }

  /// اسم القسم الحقيقي للصيدلية: من `shops.category_id`، أو من القسم الذي
  /// سُجّل له هذه الصيدلية (`categories.shop_id`).
  String _categoryNameOf(Map<String, dynamic> shop) {
    final id = shop['id']?.toString() ?? '';
    final catId = shop['category_id']?.toString() ?? '';
    for (final c in _categories) {
      if (c['id']?.toString() == catId) {
        return c['name_ar']?.toString() ?? 'قسم';
      }
    }
    for (final c in _categories) {
      if (c['shop_id']?.toString() == id) {
        return c['name_ar']?.toString() ?? 'قسم';
      }
    }
    return 'بلا قسم';
  }

  void _showMessage(String msg, bool ok) {
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
        ),
      );
  }

  Future<void> _addShop() async {
    final nameCtrl = TextEditingController();
    String? newImageUrl;
    // ★ القسم الذي تنتمي إليه الصيدلية. بدونه كان `shops.category_id`
    //   يُكتب فارغاً فلا يظهر الصيدلية في شاشة القسم ولا منتجاته.
    String? categoryId;
    // ★ فشل رفع صورة. بدونه كان الصيدلية يُنشأ بلا صورة صامتاً: الأدمن
    //   يرى المعاينة المحلية فيظنّها نجحت، ولا يرى الزبائن شيئاً.
    String? uploadFailure;
    // ★ حقيبة الصور المرفوعة في هذا النموذج — تُمسح إن أُلغي أو فشل الإدراج.
    final uploads = AdminUploads();
    final picked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'إضافة صيدلية جديدة',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 18),
              AdminImageUploader(
                folder: 'shops',
                height: 150,
                uploads: uploads,
                placeholder:
                    'اضغط لاختيار صورة الصيدلية (تُرفع للسيرفر وتظهر للجميع)',
                onChanged: (url) => newImageUrl = url,
                onFailed: (msg) => setSheetState(() => uploadFailure = msg),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                textAlign: TextAlign.right,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: 'اسم الصيدلية',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              // ★ اختيار القسم:_products تُنسب لهذا القسم تلقائياً.
              DropdownButtonFormField<String?>(
                // ☆ `initialValue` لا بد أن يكون واحداً من العناصر، وإلا
                //   _assertOutstanding: قسماً محذوفاً أو معطّلاً كان يرمي
                //   استثناءً عند فتح الورقة ⇒ لا تفتح أصلاً.
                initialValue:
                    _categories.any(
                      (c) =>
                          c['is_active'] != false &&
                          c['id']?.toString() == categoryId,
                    )
                    ? categoryId
                    : null,
                isExpanded: true,
                // ★ كان بنصّه بلا `style`، فيرث خط Material الافتراضي
                //   (Roboto) لا Cairo: العربية تظهر بخط مختلف عن كل ما حولها.
                style: _dropStyle,
                selectedItemBuilder: (context) => [
                  for (final value in <String?>[
                    null,
                    ..._categories
                        .where((c) => c['is_active'] != false)
                        .map((c) => c['id']?.toString()),
                  ])
                    Text(
                      value ?? 'بلا قسم',
                      style: _dropStyle,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
                decoration: InputDecoration(
                  labelText: 'القسم',
                  helperText: 'قسم الصيدلية (تظهر منتجاتها ضمنه في الرئيسية)',
                  helperStyle: GoogleFonts.cairo(
                    fontSize: 11.5,
                    color: AppColors.textHint,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(
                      'بلا قسم',
                      style: _dropStyle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final c in _categories)
                    if (c['is_active'] != false)
                      DropdownMenuItem<String?>(
                        value: c['id']?.toString(),
                        child: Text(
                          c['name_ar']?.toString() ?? 'قسم',
                          style: _dropStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                ],
                onChanged: (v) => setSheetState(() => categoryId = v),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          'أدخل اسم الصيدلية',
                          style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                        ),
                        behavior: SnackBarBehavior.floating,
                        backgroundColor: AppColors.danger,
                      ),
                    );
                    return;
                  }
                  // ★ لا صيدلية بلا صورة بعد محاولة رفع فشلت: ننبّه
                  //   ونُبقي الورقة مفتوحة بدل إنشاء صيدلية مقطوع
                  //   الرأس يظنّ الأدمن أنه أضافه بصورة.
                  final failure = uploadFailure;
                  if (failure != null) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          'لم تُرفع الصورة. $failure',
                          style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                          textAlign: TextAlign.center,
                        ),
                        behavior: SnackBarBehavior.floating,
                        backgroundColor: AppColors.danger,
                        duration: const Duration(seconds: 7),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  'إضافة الصيدلية',
                  style: GoogleFonts.cairo(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != true) {
      uploads.discard();
      return;
    }
    final name = nameCtrl.text.trim();
    final ok = await SupabaseService.instance.addShop(
      name: name,
      imagePath: newImageUrl,
      imageUrl: newImageUrl,
      categoryId: categoryId,
    );
    if (!mounted) return;
    // ★ نجح الإدراج فالصورة ملك الصف الآن؛ فشل فالفراغ يبقى في السحابة
    //   بلا صيدلية — نمسحه.
    if (ok) {
      uploads.keep();
    } else {
      uploads.discard();
    }
    _showMessage(ok ? 'تمت إضافة الصيدلية' : 'تعذر إضافة الصيدلية', ok);
    if (ok) _load();
  }

  /// قسم المنتجات المطابق لاسم قسم دليل — يُنشأ تلقائياً إن لم يوجد، بنفس
  /// قاعدة عرض منتجات القسم في الرئيسية (المطابقة بالاسم).
  Future<String?> _ensureCategoryForLabel(String label) async {
    final name = label.trim();
    if (name.isEmpty) return null;
    var cats = await SupabaseService.instance.fetchCategories();
    for (final c in cats) {
      if ((c['name_ar']?.toString().trim() ?? '') != name) continue;
      final id = c['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      if (c['is_active'] == false) {
        await SupabaseService.instance.updateCategory(id, {'is_active': true});
      }
      return id;
    }
    final ok = await SupabaseService.instance.addCategory(name: name);
    if (!ok) return null;
    cats = await SupabaseService.instance.fetchCategories();
    for (final c in cats) {
      if ((c['name_ar']?.toString().trim() ?? '') == name) {
        return c['id']?.toString();
      }
    }
    return null;
  }

  String? _categoryIdForLabel(String label) {
    final name = label.trim();
    for (final c in _categories) {
      if ((c['name_ar']?.toString().trim() ?? '') == name) {
        return c['id']?.toString();
      }
    }
    return null;
  }

  Widget _sheetGroup(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Text(
      text,
      style: GoogleFonts.cairo(
        fontSize: 11.5,
        fontWeight: FontWeight.w900,
        color: AppColors.textHint,
      ),
    ),
  );

  /// ★ تعديل قسم الصيدلية: الربط بـ`shops.category_id` هو ما يجعل
  ///   الصيدلية يظهر في شاشة قسمه ومنتجاته في ذلك القسم. بدونه الصيدلية
  ///   «بلا قسم» فلا يظهر في أي قسم مهما أنشأ الأدمن من أقسام.
  ///
  ///   ★ 2026-11-20: صار بالإمكان نقل الصيدلية إلى قسم من أقسام الرئيسية
  ///   (دليل الأقسام): يُجهَّز قسم المنتجات المطابق لاسم القسم تلقائياً
  ///   ويُربط به، فتظهر منتجات الصيدلية تحت شريحة القسم في الرئيسية ولا
  ///   تظهر كشريحة في صفحة الأدوية.
  Future<void> _changeShopCategory(Map<String, dynamic> shop) async {
    final current = (shop['category_id']?.toString() ?? '').trim();
    final categories = _categories
        .where((c) => c['is_active'] != false)
        .toList();
    final picked = await showModalBottomSheet<({String mode, String value})>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Text(
                'قسم الصيدلية',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                'قسم «${shop['name']?.toString() ?? ''}»',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              ListTile(
                onTap: () => Navigator.pop(ctx, (mode: 'none', value: '')),
                leading: Icon(
                  current.isEmpty
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  color: current.isEmpty
                      ? AppColors.primary
                      : AppColors.textHint,
                ),
                title: Text(
                  'بلا قسم',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (categories.isNotEmpty) ...[
                _sheetGroup('أقسام صفحة الأدوية'),
                for (final c in categories)
                  ListTile(
                    onTap: () => Navigator.pop(ctx, (
                      mode: 'category',
                      value: c['id']?.toString() ?? '',
                    )),
                    leading: Icon(
                      c['id']?.toString() == current
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: c['id']?.toString() == current
                          ? AppColors.primary
                          : AppColors.textHint,
                    ),
                    title: Text(
                      c['name_ar']?.toString() ?? 'قسم',
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
              ],
              const Divider(height: 18),
              _sheetGroup('أقسام الرئيسية (دليل الأقسام)'),
              for (final d in _doctorCats)
                ListTile(
                  onTap: () =>
                      Navigator.pop(ctx, (mode: 'directory', value: d.label)),
                  leading: Icon(
                    _categoryIdForLabel(d.label) == current
                        ? Icons.check_circle_rounded
                        : Icons.public_rounded,
                    color: _categoryIdForLabel(d.label) == current
                        ? AppColors.primary
                        : AppColors.textHint,
                  ),
                  title: Text(
                    d.label,
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    'تظهر منتجات الصيدلية تحت القسم في الرئيسية',
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      color: AppColors.textHint,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;

    String? target;
    if (picked.mode == 'none') {
      target = null;
    } else if (picked.mode == 'category') {
      target = picked.value;
    } else {
      target = await _ensureCategoryForLabel(picked.value);
      if (!mounted) return;
      if (target == null) {
        _showMessage(
          SupabaseService.instance.lastAdminError.isEmpty
              ? 'تعذر تجهيز قسم «${picked.value}»'
              : SupabaseService.instance.lastAdminError,
          false,
        );
        return;
      }
    }
    if ((target ?? '') == current) return;
    final ok = await SupabaseService.instance.updateShop(
      shop['id'].toString(),
      {'category_id': target},
    );
    if (!mounted) return;
    _showMessage(
      ok
          ? (picked.mode == 'directory'
                ? 'نُقلت الصيدلية إلى «${picked.value}» في الرئيسية'
                : 'تم تحديث قسم الصيدلية')
          : 'تعذر تحديث القسم',
      ok,
    );
    if (ok) _load();
  }

  /// مفاتيح أقسام الدليل المسجلة للصيدلية (قد تكون أكثر من قسم).
  List<String> _directoryKeysOf(Map<String, dynamic> shop) =>
      shop['directory_keys'] is List
      ? (shop['directory_keys'] as List)
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
      : const [];

  /// أسماء أقسام الدليل للعرض — المفتاح بلا قسم معروف يُكتب كما هو.
  String _directoryLabelsOf(Map<String, dynamic> shop) {
    final labels = <String>[];
    for (final key in _directoryKeysOf(shop)) {
      String label = key;
      for (final d in _doctorCats) {
        if (d.key == key) {
          label = d.label;
          break;
        }
      }
      labels.add(label);
    }
    return labels.join(' • ');
  }

  /// ★ أقسام دليل الرئيسية التي تظهر فيها بطاقة الصيدلية (طلب 2026-11-20:
  ///   «زر ينقل الصيدليات المسجلة لدليل اي قسم يعجبني عند الضغط على
  ///   بروفايله تظهر منتجاتها»). تعدد الأقسام مقصود: الصيدلية الواحدة
  ///   قد تنتمي إلى «صيدليات» و«العناية بالبشرة» معاً.
  Future<void> _changeShopsDirectorySections(Map<String, dynamic> shop) async {
    final shopName = shop['name']?.toString() ?? '';
    final current = _directoryKeysOf(shop).toSet();
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final sel = {...current};
        return StatefulBuilder(
          builder: (ctx, setSheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Text(
                  'أقسام الدليل',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '«$shopName» — اختر قسماً واحداً أو أكثر',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                if (_doctorCats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'لا توجد أقسام بعد — أضفها من «أقسام دليل الأطباء»',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textHint,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final d in _doctorCats)
                            CheckboxListTile(
                              value: sel.contains(d.key),
                              activeColor: AppColors.primary,
                              onChanged: (v) => setSheet(() {
                                if (v == true) {
                                  sel.add(d.key);
                                } else {
                                  sel.remove(d.key);
                                }
                              }),
                              title: Text(
                                d.label,
                                style: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              subtitle: Text(
                                'تظهر بطاقة الصيدلية في الرئيسية تحت هذا القسم',
                                style: GoogleFonts.cairo(
                                  fontSize: 10.5,
                                  color: AppColors.textHint,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(
                            'إلغاء',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                          ),
                          onPressed: () => Navigator.pop(ctx, sel),
                          child: Text(
                            'حفظ',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    final ok = await SupabaseService.instance.updateShop(
      shop['id'].toString(),
      {'directory_keys': picked.toList()},
    );
    if (!mounted) return;
    final err = SupabaseService.instance.lastAdminError;
    final needsSql =
        !ok && (err.contains('directory_keys') || err.contains('42703'));
    _showMessage(
      ok
          ? (picked.isEmpty
                ? 'أُزيلت «$shopName» من دليل الأقسام'
                : 'تظهر «$shopName» في ${picked.length} قسم من الدليل')
          : needsSql
          ? 'شغّل SQL_SHOP_DIRECTORY_KEYS.sql أولاً'
          : (err.isEmpty ? 'تعذر حفظ أقسام الدليل' : err),
      ok,
    );
    if (ok) _load();
  }

  /// ★ حذف الصيدلية من لوحة الأدمن — على مرحلتين (طلب 2026-10-10).
  ///
  ///   كان الرفض «الصيدلية مرتبط بطلبات — عطّله بدل حذفه» حاجزاً داخل دالة
  ///   القاعدة نفسها. الآن: المرحلة الأولى تستطلِع الأثر، والثانية تحذف
  ///   فوراً بعد تأكيد يعرض بالأرقام ما سيُمحى (طلبات، منتجات، أقسام،
  ///   دفعات). صيدلية بلا طلبات يُحذف من النداء الأول مباشرة بلا سؤال ثانٍ.
  Future<void> _deleteShop(Map<String, dynamic> shop) async {
    final shopId = shop['id'].toString();
    final name = shop['name']?.toString().trim() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف الصيدلية',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل تريد حذف "${shop['name']}"؟',
          style: GoogleFonts.cairo(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'حذف',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final impact = await SupabaseService.instance.deleteShopDetailed(shopId);
    if (!mounted) return;

    // لا طلبات له ⇒ حُذف في هذا النداء نفسه.
    if (impact['ok'] == true) {
      _finishShopDelete(impact, shopId);
      return;
    }

    // منع من الأدمن (أو خطأ شبكة): رسالة صريحة بلا نافذة ثانية.
    if ((impact['error'] ?? '').toString() != 'SHOP_HAS_ORDERS') {
      _showMessage(
        SupabaseService.instance.lastDeleteError.isEmpty
            ? 'تعذر حذف الصيدلية'
            : SupabaseService.instance.lastDeleteError,
        false,
      );
      return;
    }

    // له طلبات: تأكيد ثانٍ بالأرقام، ثم الحذف المؤكَّد.
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف «${name.isEmpty ? 'الصيدلية' : name}» نهائياً؟',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          _shopImpactLine(impact),
          style: GoogleFonts.cairo(fontSize: 13.5, height: 1.8),
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'احذف فوراً',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (go != true) return;

    final res = await SupabaseService.instance.deleteShopDetailed(
      shopId,
      force: true,
    );
    if (!mounted) return;
    if (res['ok'] == true) {
      _finishShopDelete(res, shopId);
      return;
    }
    _showMessage(
      SupabaseService.instance.lastDeleteError.isEmpty
          ? 'تعذر حذف الصيدلية'
          : SupabaseService.instance.lastDeleteError,
      false,
    );
  }

  /// عدد صحيح من جسم jsonb العائد من القاعدة (غيّر المفتاح = صفر، لا انهيار).
  static int _intFrom(Map<String, dynamic> data, String key) =>
      (data[key] as num?)?.toInt() ?? 0;

  /// سطر الأثر بالعربية: ما سيُمحى بالضبط إن أُكّد الحذف.
  String _shopImpactLine(Map<String, dynamic> data) {
    final paid = (data['paid'] as num?)?.toDouble() ?? 0;
    final lines = <String>[
      '${_intFrom(data, 'orders')} طلبات — تُحذف معه',
      '${_intFrom(data, 'products')} منتجات',
      '${_intFrom(data, 'categories')} أقسام',
      if (_intFrom(data, 'payouts') > 0)
        'إبطال ${_intFrom(data, 'payouts')} دفعة بمبلغ '
            '${paid.toStringAsFixed(0)} د.ع',
    ];
    return '${lines.map((e) => '• $e').join('\n')}\n\n'
        'الطلبات المحذوفة قد تغيّر أرقام محفظة المندوبين المرتبطة بها.';
  }

  /// ما بعد نجاح الحذف: الشعار يتيم في السحابة فنمسحه، ثم تلخيص ما مُحى.
  void _finishShopDelete(Map<String, dynamic> res, String shopId) {
    // ★ الصيدلية المحذوف يختفي فوراً: سطره وكل منتجاته وأقسامه من الكاش،
    //   ومن «شاهدتها مؤخراً» — لا تنتظر دورة تحديث لتُعيد رسم صيدليةٍ مات.
    unawaited(RealDataService.instance.purgeShopFromCaches(shopId));
    unawaited(RecentViewsStore.instance.removeShop(shopId));

    // الشعار كان مرتبطاً بالصف الذي حُذف للتوّ؛ الحذف غير متزامن حتى لا
    // تنتظر الشاشة الشبكة، وهو آمن: لا رجعة في حذف الصيدلية أصلاً.
    final logos = <String>{
      (res['logo'] ?? '').toString().trim(),
      (res['logo_path'] ?? '').toString().trim(),
    }.where((u) => u.isNotEmpty);
    for (final url in logos) {
      unawaited(SupabaseService.instance.deleteImage(url));
    }

    final parts = <String>[
      if (_intFrom(res, 'deleted_orders') > 0)
        '${_intFrom(res, 'deleted_orders')} طلبات',
      if (_intFrom(res, 'deleted_products') > 0)
        '${_intFrom(res, 'deleted_products')} منتجات',
      if (_intFrom(res, 'deleted_categories') > 0)
        '${_intFrom(res, 'deleted_categories')} أقسام',
      if (_intFrom(res, 'voided_payouts') > 0)
        'وأُبطلت ${_intFrom(res, 'voided_payouts')} دفعة',
    ];
    _showMessage(
      parts.isEmpty
          ? 'تم حذف الصيدلية'
          : 'تم حذف الصيدلية مع ${parts.join(' · ')}',
      true,
    );
    _load();
  }

  /// ★ إعدادات الصيدلية: الاسم + أوقات العمل + تعيين صاحبه (من الأدمن).
  ///
  /// إعداد الاسم يتم عبر [SupabaseService.renameShop] لا بـ PATCH مباشر
  /// على `shops` — لأن الاسم منسوخ أيضاً في `products` و`order_items`
  /// (مفتاح ربط المحفظة)، فتغيير `shops` وحده يُصفِّر أرقام صاحب الصيدلية.
  Future<void> _editShopSettings(Map<String, dynamic> shop) async {
    final oldName = shop['name']?.toString().trim() ?? '';
    final nameCtrl = TextEditingController(text: oldName);
    // ★ خطأ الاسم يُعرض تحت الحقل لحظة الكتابة — فلا يضغط الأدمن «حفظ»
    //   على اسم فارغ أو طويل أو مطابقة حرفية.
    String? nameError;
    final splitHours = (shop['working_hours']?.toString() ?? '')
        .split(' - ')
        .map((e) => e.trim());
    var openTime = splitHours.toList();
    var open = openTime.isNotEmpty && openTime.first.isNotEmpty
        ? openTime.first
        : '09:00';
    var close = openTime.length > 1 && openTime[1].isNotEmpty
        ? openTime[1]
        : '23:00';
    var workingDays = shop['working_days']?.toString() ?? 'يومياً';
    var isOpen = shop['is_open'] != false;
    final ownerCtrl = TextEditingController(
      text: shop['owner_phone']?.toString() ?? '',
    );

    Future<void> pickTime(
      BuildContext ctx,
      bool isOpenTime,
      void Function(void Function()) setSheet,
    ) async {
      final base = isOpenTime ? open : close;
      final parts = base.split(':').map(int.tryParse).toList();
      final initial = TimeOfDay(
        hour: parts.isNotEmpty && parts.first != null ? parts.first! : 9,
        minute: parts.length > 1 && parts[1] != null ? parts[1]! : 0,
      );
      final picked = await showTimePicker(
        context: ctx,
        initialTime: initial,
        helpText: isOpenTime ? 'وقت فتح الصيدلية' : 'وقت إغلاق الصيدلية',
      );
      if (picked == null) return;
      String two(int n) => n.toString().padLeft(2, '0');
      final value = '${two(picked.hour)}:${two(picked.minute)}';
      setSheet(() {
        if (isOpenTime) {
          open = value;
        } else {
          close = value;
        }
      });
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // ★ سقف ارتفاع الورقة = ما يبقى من الشاشة **فوق الكيبورد**.
          //   `showModalBottomSheet` لا يراعي `viewInsets` من نفسه (بخلاف
          //   `Dialog`)، فكانت الكتابة في حقل الاسم تغطي الحقل وزر الحفظ.
          final keyboard = KeyboardSheet.bottomInset(
            MediaQuery.of(ctx).viewInsets.bottom,
          );
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + keyboard),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: KeyboardSheet.maxHeight(
                  screenSize: MediaQuery.sizeOf(ctx),
                  keyboardInset: keyboard,
                ),
              ),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'إعدادات ${shop['name']?.toString() ?? 'الصيدلية'}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    // ★ اسم الصيدلية: يُرسل إلى `admin_rename_shop` التي تكتب
                    //   الاسم في كل نسخه، فلا تصفّر أرقام صاحب الصيدلية.
                    TextField(
                      controller: nameCtrl,
                      textAlign: TextAlign.right,
                      maxLength: ShopRename.maxNameLength,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'اسم الصيدلية (تظهر للزبائن)',
                        counterText: '',
                        errorText: nameError,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onChanged: (v) => setSheetState(() {
                        final cleaned = ShopRename.clean(v);
                        if (cleaned.isEmpty) {
                          nameError = 'اكتب اسم الصيدلية أولاً';
                          return;
                        }
                        nameError = cleaned == ShopRename.clean(oldName)
                            ? null
                            : ShopRename.validate(v, current: oldName);
                      }),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _TimeTile(
                            label: 'وقت الفتح',
                            value: open,
                            icon: Icons.wb_sunny_outlined,
                            onTap: () => pickTime(ctx, true, setSheetState),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _TimeTile(
                            label: 'وقت الإغلاق',
                            value: close,
                            icon: Icons.dark_mode_outlined,
                            onTap: () => pickTime(ctx, false, setSheetState),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      // ☆ نفس الحماية: قيمة قديمة خارج العناصر الأربعة كانت
                      //   تُسقط الورقة باستثناء. نبدأ من «يومياً» بدل(null).
                      initialValue:
                          const [
                            'يومياً',
                            'السبت - الخميس',
                            'الجمعة فقط',
                            'عطلة أسبوعية',
                          ].contains(workingDays)
                          ? workingDays
                          : 'يومياً',
                      isExpanded: true,
                      // ★ نفس المشكلة: خط Cairo لكل عناصر هذه القائمة.
                      style: _dropStyle,
                      selectedItemBuilder: (context) => [
                        Text(
                          'يومياً (7 أيام)',
                          style: _dropStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'السبت - الخميس',
                          style: _dropStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'الجمعة فقط',
                          style: _dropStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'عطلة أسبوعية',
                          style: _dropStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: 'أيام العمل',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'يومياً',
                          child: Text(
                            'يومياً (7 أيام)',
                            style: _dropStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'السبت - الخميس',
                          child: Text(
                            'السبت - الخميس',
                            style: _dropStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'الجمعة فقط',
                          child: Text(
                            'الجمعة فقط',
                            style: _dropStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'عطلة أسبوعية',
                          child: Text(
                            'عطلة أسبوعية',
                            style: _dropStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) setSheetState(() => workingDays = v);
                      },
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: ownerCtrl,
                      textAlign: TextAlign.right,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'رقم هاتف صاحب الصيدلية',
                        hintText: 'مثال: 07801234567',
                        hintStyle: GoogleFonts.cairo(fontSize: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        isOpen ? 'الصيدلية مفتوحة الآن' : 'الصيدلية مغلقة الآن',
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                      value: isOpen,
                      activeTrackColor: AppColors.primary,
                      onChanged: (v) => setSheetState(() => isOpen = v),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        // ★ الاسم أولاً: إن تعذّر تغييره لا نكتب بقية
                        //   الإعدادات فوقه، فيبقى الأدمن أمام رسالة واحدة
                        //   سببها واضح بدل حالة لا يُعرف ما نُفّذ منها.
                        final cleanedName = ShopRename.clean(nameCtrl.text);
                        final renameWanted =
                            cleanedName.isNotEmpty &&
                            cleanedName != ShopRename.clean(oldName);
                        if (renameWanted && nameError != null) {
                          _showMessage(nameError!, false);
                          return;
                        }
                        Map<String, dynamic>? renamed;
                        if (renameWanted) {
                          renamed = await SupabaseService.instance.renameShop(
                            shop['id'].toString(),
                            cleanedName,
                          );
                          if (!ctx.mounted) return;
                          if (renamed['ok'] != true) {
                            Navigator.pop(ctx);
                            if (!mounted) return;
                            _showMessage(
                              ShopRename.failureLine(renamed),
                              false,
                            );
                            return;
                          }
                        }

                        final okHours = await SupabaseService.instance
                            .updateShopWorkingHours(
                              shop['id'].toString(),
                              openTime: open,
                              closeTime: close,
                              workingDays: workingDays,
                              isOpen: isOpen,
                            );
                        final ownerPhone = ownerCtrl.text.trim();
                        var okOwner = true;
                        if (ownerPhone.isNotEmpty ||
                            (shop['owner_phone']?.toString() ?? '')
                                .isNotEmpty) {
                          okOwner = await SupabaseService.instance.updateShop(
                            shop['id'].toString(),
                            {'owner_phone': ownerPhone},
                          );
                        }
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        if (!mounted) return;
                        final okAll = okHours && okOwner;
                        if (renamed != null) {
                          // ★ النجاح يقول الحصيلة: كم منتجاً وسطراً وقسماً
                          //   تبعت الاسم الجديد.
                          _showMessage(
                            okAll
                                ? ShopRename.resultLine(
                                    renamed,
                                    oldName: oldName,
                                  )
                                : '${ShopRename.resultLine(renamed, oldName: oldName)}'
                                      ' — لكن تعذّر حفظ الأوقات',
                            okAll,
                          );
                        } else {
                          _showMessage(
                            okAll
                                ? 'تم حفظ إعدادات الصيدلية'
                                : 'تعذر حفظ الإعدادات',
                            okAll,
                          );
                        }
                        _load();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        'حفظ الإعدادات',
                        style: GoogleFonts.cairo(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    // ★ الحقلان ملك هذه الورقة فقط: أُغلقت فلا حاجة لبقائهما في الذاكرة.
    //   لكن التخلّص لا يكون فور إغلاقها: TextField ما زال يستخدمهما أثناء
    //   حركة خروج الورقة، والتخلّص الفوري كان يُسقط التطبيق بخطأ
    //   «used after being disposed». ننتظر انتهاء الحركة (~200ms) ثم نمسحهما.
    Future.delayed(const Duration(milliseconds: 400), () {
      nameCtrl.dispose();
      ownerCtrl.dispose();
    });
  }

  /// تغيير صورة الصيدلية وحفظها في قاعدة البيانات.
  ///
  /// الرفع والحفظ يوليان معاً: بمجرّد نجاح رفع الصورة إلى Supabase
  /// Storage نكتب الرابط في قاعدة البيانات مباشرة. فائدة ذلك أن الأدمن
  /// لا يستطيع أن يغلق الورقة وفي جيبه صورة لم تُحفظ.
  Future<void> _changeShopImage(Map<String, dynamic> shop) async {
    final shopId = shop['id'].toString();
    if (shopId.isEmpty) return;
    final shopName = shop['name']?.toString() ?? 'الصيدلية';
    final current =
        shop['image_path']?.toString() ?? shop['logo_image']?.toString() ?? '';
    var saving = false;
    // ★ الرابط الذي يشير إليه صف الصيدلية **الآن** في القاعدة. كل كتابة
    //   ناجحة تنقله إلى الجديد، فيصير القديم بلا مرجع.
    //   الترتيب مقصود: حذف القديم **بعد** نجاح كتابة القاعدة — فلو حذفناه
    //   قبلها وأخفقت الكتابة لبقى الصف يشير إلى ملف لم يعد موجودًا.
    var liveUrl = current.trim();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'صورة $shopName',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    saving
                        ? 'جاري الحفظ في قاعدة البيانات...'
                        : 'اختر الصورة من المعرض أو الكاميرا — تُحفظ فوراً وتظهر لكل الأجهزة.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 18),
                  AdminImageUploader(
                    folder: 'shops',
                    initialUrl: current,
                    height: 180,
                    placeholder: 'اختر صورة شعار الصيدلية',
                    // ★ هذه الشاشة تكتب القاعدة فور كل تغيير، فهي المسؤولة
                    //   عن حذف الملفات من السحابة — لا الرافع نفسه.
                    handleRemovalExternally: true,
                    onChanged: (url) async {
                      // رفعان متتاليان (وضع ثم مسح مثلاً) ⇒ الأول فقط.
                      if (saving) return;
                      // ★ `null` هنا الآن = **حذف صريح** فقط. كان
                      //   فشل الرفع يطلق `null` أيضاً فتمسح هذه الدالة
                      //   الأعمدة الثلاثة ويمحو شعاراً يعمل لمجرّد
                      //   تعثّر الشبكة — وهو «الصور ما تظهر للكل».
                      saving = true;
                      setSheetState(() {});
                      final ok = await SupabaseService.instance.updateShopImage(
                        shopId,
                        url,
                      );
                      saving = false;
                      if (!ctx.mounted) return;
                      setSheetState(() {});
                      _showMessage(
                        ok ? 'تم حفظ صورة الصيدلية' : 'تعذر حفظ الصورة',
                        ok,
                      );
                      if (ok) {
                        // ★ القاعدة صارت تشير إلى [url] (أو لا تشير إلى
                        //   شيء بعد المسح). الرابط السابق إذن يتيم الآن
                        //   ⇒ يُمسح من السحابة، فلا تتكدّس شعارات قديمة.
                        final superseded = liveUrl;
                        liveUrl = (url ?? '').trim();
                        if (superseded.isNotEmpty && superseded != liveUrl) {
                          unawaited(
                            SupabaseService.instance.deleteImage(superseded),
                          );
                        }
                        Navigator.pop(ctx);
                        _load();
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      'إغلاق',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'الصيدليات',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addShop,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'صيدلية جديدة',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _shops.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 140),
                        const Icon(
                          Icons.storefront_rounded,
                          size: 64,
                          color: AppColors.textHint,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            'لا توجد صيدليات بعد',
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      itemCount: _shops.length,
                      itemBuilder: (_, i) {
                        final shop = _shops[i];
                        final image =
                            shop['image_path']?.toString() ??
                            shop['logo_image']?.toString() ??
                            '';
                        final dirLabels = _directoryLabelsOf(shop);
                        return Card(
                          elevation: 1.5,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => AdminProductsScreen(
                                    shopId: shop['id'].toString(),
                                  ),
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: image.isEmpty
                                        ? Container(
                                            width: 56,
                                            height: 56,
                                            color: AppColors.surfaceTint,
                                            child: const Icon(
                                              Icons.storefront_rounded,
                                              color: AppColors.textHint,
                                              size: 28,
                                            ),
                                          )
                                        : AppImage(
                                            image,
                                            width: 56,
                                            height: 56,
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          shop['name']?.toString() ?? 'صيدلية',
                                          // ★ كان بلا maxLines ولا overflow: داخل Expanded/Column يأخذ
                                          //   سطراً واحداً طويلاً، فيقصّه Flutter عند حدود العمود ويُظهر
                                          //   كلمات مقطوعة بلا "…". الآن سطران مع علامة قصّ واضحة.
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: true,
                                          style: GoogleFonts.cairo(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.textPrimary,
                                            height: 1.3,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        // ★ القسم الحقيقي: يُقرأ من
                                        //   `shops.category_id` ثم من القسم
                                        //   المسجّل له صيدلية.
                                        Text(
                                          'القسم: ${_categoryNameOf(shop)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.cairo(
                                            fontSize: 11,
                                            color:
                                                _categoryNameOf(shop) ==
                                                    'بلا قسم'
                                                ? AppColors.danger
                                                : AppColors.brandDark,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        // ★ زرّ أقسام الدليل: يظهر تحت
                                        //   القسم ويضغطه الأدمن لاختيار
                                        //   أقسام الرئيسية (متعدد).
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          onTap: () =>
                                              _changeShopsDirectorySections(
                                                shop,
                                              ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 4,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.account_tree_rounded,
                                                  size: 13,
                                                  color: AppColors.brandDark,
                                                ),
                                                const SizedBox(width: 3),
                                                Flexible(
                                                  child: Text(
                                                    dirLabels.isEmpty
                                                        ? 'دليل الأقسام: لا يظهر'
                                                        : 'دليل الأقسام: $dirLabels',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: GoogleFonts.cairo(
                                                      fontSize: 10.5,
                                                      color: dirLabels.isEmpty
                                                          ? AppColors.textHint
                                                          : AppColors.brandDark,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      decoration: TextDecoration
                                                          .underline,
                                                      decorationStyle:
                                                          TextDecorationStyle
                                                              .dotted,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        Text(
                                          shop['is_open'] == false
                                              ? 'مغلق • ${shop['working_hours']?.toString() ?? '—'}'
                                              : 'مفتوح • ${shop['working_hours']?.toString() ?? 'اضغط للإدارة'} ${shop['working_days']?.toString().isNotEmpty == true ? '• ${shop['working_days']}' : ''}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.cairo(
                                            fontSize: 11,
                                            color: shop['is_open'] == false
                                                ? AppColors.danger
                                                : AppColors.textSecondary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.category_rounded,
                                      color: AppColors.brandDark,
                                    ),
                                    tooltip: 'القسم الذي تنتمي إليه الصيدلية',
                                    onPressed: () => _changeShopCategory(shop),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.settings_rounded,
                                      color: AppColors.primary,
                                    ),
                                    tooltip: 'اسم الصيدلية وأوقات العمل',
                                    onPressed: () => _editShopSettings(shop),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.photo_camera_rounded,
                                      color: AppColors.info,
                                    ),
                                    tooltip: 'تغيير صورة الصيدلية',
                                    onPressed: () => _changeShopImage(shop),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      color: AppColors.danger,
                                    ),
                                    onPressed: () => _deleteShop(shop),
                                  ),
                                  const Icon(
                                    Icons.chevron_left_rounded,
                                    color: AppColors.textHint,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

/// خانة اختيار وقت (فتح/إغلاق صيدلية).
class _TimeTile extends StatelessWidget {
  const _TimeTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.primaryLight.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary, size: 20),
            const SizedBox(height: 6),
            Text(
              label,
              style: GoogleFonts.cairo(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: GoogleFonts.cairo(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
