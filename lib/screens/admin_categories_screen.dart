import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/doctor_directory_service.dart';
import '../services/real_data_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/app_image.dart';

/// إدارة الأقسام: إضافة قسم (اسم + صورة من المعرض تُحفظ محلياً)، حذف قسم.
class AdminCategoriesScreen extends StatefulWidget {
  const AdminCategoriesScreen({super.key});

  @override
  State<AdminCategoriesScreen> createState() => _AdminCategoriesScreenState();
}

class _AdminCategoriesScreenState extends State<AdminCategoriesScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _categories = [];

  /// الصيدليات المتاحة لربط القسم بواحد منها.
  List<Map<String, dynamic>> _shops = [];

  /// أقسام الرئيسية (دليل الأقسام): قسم منتجات يطابق اسمها يظهر هناك
  /// ولا يظهر كشريحة في صفحة الأدوية.
  List<DoctorCategory> _doctorCats = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait<Object>([
      SupabaseService.instance.fetchCategories(),
      SupabaseService.instance.fetchShops(),
      DoctorDirectoryService.instance.fetchCategories(force: true),
    ]);
    await RealDataService.instance.clearCache();
    RealDataService.instance.catalogGeneration.value++;
    if (!mounted) return;
    setState(() {
      _categories = results[0] as List<Map<String, dynamic>>;
      _shops = results[1] as List<Map<String, dynamic>>;
      _doctorCats = results[2] as List<DoctorCategory>;
      _loading = false;
    });
  }

  /// معرّف الصيدلية الذي يملك هذا القسم؛ null لقسم عام.
  String? _catShopId(Map<String, dynamic> cat) {
    final owner = cat['shop_id']?.toString().trim();
    return (owner == null || owner.isEmpty || owner == 'null') ? null : owner;
  }

  /// اسم قسم الرئيسية المطابق لاسم هذا القسم، إن وُجد. وجوده يعني أن
  /// القسم يظهر في الرئيسية فقط ولا يُعرض كشريحة في صفحة الأدوية.
  String? _directoryLabelOf(Map<String, dynamic> cat) {
    final name = (cat['name_ar']?.toString() ?? '').trim();
    if (name.isEmpty) return null;
    for (final d in _doctorCats) {
      if (d.label.trim() == name) return d.label;
    }
    return null;
  }

  /// اسم الصيدلية المخزَّن كما هو — بلا لقب عام مكانه.
  String _shopName(String shopId) {
    for (final s in _shops) {
      if (s['id']?.toString().trim() != shopId) continue;
      final name = s['name']?.toString().trim() ?? '';
      return name.isEmpty ? shopId : name;
    }
    return shopId;
  }

  /// سطر الملكية على بطاقة القسم: عام، أو رفّ داخلي لصيدليته، أو قسمه الرئيسي.
  /// التفرقة الثالثة ضرورية: الرأس وحده يستقبل منتجات الصيدلية غير المصنَّفة.
  String _ownerLabel(Map<String, dynamic> cat) {
    final owner = _catShopId(cat);
    if (owner == null) return 'قسم عام · لكل الصيدليات';
    final id = cat['id']?.toString().trim() ?? '';
    for (final s in _shops) {
      if (s['id']?.toString().trim() == owner &&
          (s['category_id']?.toString().trim() ?? '') == id) {
        return 'الرئيسي لـ«${_shopName(owner)}» · يستقبل غير المصنَّف';
      }
    }
    return 'رفّ داخل «${_shopName(owner)}»';
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

  Future<void> _addCategory() async {
    final nameCtrl = TextEditingController();
    String? newImageUrl;
    // ★ حقيبة الصور المرفوعة في هذا النموذج — تُمسح إن أُلغي أو فشل الإدراج.
    final uploads = AdminUploads();
    // القسم يُربط بصيدلية واحدة فقط (null = قسم عام لكل الصيدليات).
    // ★ لا نختار صيدليةً تلقائياً: الربط الصامت بأحدث صيدلية (ترتيب
    //   `created_at.desc`) كان يمنع اختيار هذا القسم لمنتجات غيره.
    String? selectedShopId;
    // ★ قسم في الرئيسية (دليل الأقسام) بدل صفحة الأدوية: يُنشأ القسم
    //   في دليل الرئيسية بنفس الاسم، فيظهر هناك ويُخفى من صفحة الأدوية.
    var showOnHome = false;

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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'إضافة قسم جديد',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                AdminImageUploader(
                  folder: 'categories',
                  height: 130,
                  uploads: uploads,
                  icon: Icons.image_rounded,
                  placeholder: 'صورة القسم (تُرفع للسيرفر وتظهر للجميع)',
                  onChanged: (url) => newImageUrl = url,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  textAlign: TextAlign.right,
                  maxLength: 30,
                  decoration: InputDecoration(
                    labelText: 'اسم القسم',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // ربط القسم بصيدلية واحدة فقط.
                DropdownButtonFormField<String?>(
                  initialValue: selectedShopId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'القسم خاص بصيدلية',
                    helperText: 'اختر صيدلية واحدة، أو عام لكل الصيدليات',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('عام لكل الصيدليات'),
                    ),
                    for (final s in _shops)
                      DropdownMenuItem<String?>(
                        value: s['id']?.toString(),
                        child: Text(
                          s['name']?.toString() ?? 'صيدلية',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setSheetState(() => selectedShopId = v),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: showOnHome,
                  activeThumbColor: AppColors.primary,
                  onChanged: (v) => setSheetState(() => showOnHome = v),
                  title: Text(
                    'يظهر في الرئيسية (دليل الأقسام)',
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    'ينشئ قسم دليل بالاسم نفسه — لا يظهر في صفحة الأدوية',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(
                            'أدخل اسم القسم',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: AppColors.danger,
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
                    'إضافة القسم',
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
      ),
    );
    if (picked != true) {
      uploads.discard();
      return;
    }
    final name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (!mounted) return;

    // ★ قسم الرئيسية: يُنشأ في دليل الأقسام بنفس الاسم أولاً، فلا يظهر
    //   كشريحة في صفحة الأدوية بل تحت شريحة القسم في الرئيسية.
    if (showOnHome) {
      final cats = await DoctorDirectoryService.instance.fetchCategories(
        force: true,
      );
      if (!mounted) return;
      if (!cats.any((c) => c.label.trim() == name)) {
        final added = await DoctorDirectoryService.instance.addCategory(name);
        if (!mounted) return;
        if (!added) {
          uploads.discard();
          _showMessage(
            SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر إنشاء قسم الرئيسية'
                : SupabaseService.instance.lastAdminError,
            false,
          );
          return;
        }
      }
      final exists = _categories.any(
        (c) => (c['name_ar']?.toString().trim() ?? '') == name,
      );
      if (exists) {
        uploads.discard();
        _showMessage('قسم «$name» موجود ويظهر الآن في الرئيسية', true);
        _load();
        return;
      }
    }

    final ok = await SupabaseService.instance.addCategory(
      name: name,
      imagePath: newImageUrl,
      imageUrl: newImageUrl,
      shopId: selectedShopId,
    );
    if (!mounted) return;
    // ★ الصورة تبقى فقط إذا بقي لها صف في القاعدة.
    if (ok) {
      uploads.keep();
    } else {
      uploads.discard();
    }
    _showMessage(
      ok
          ? (showOnHome
                ? 'تمت إضافة «$name» — يظهر في الرئيسية فقط'
                : 'تمت إضافة القسم')
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر إضافة القسم'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _load();
  }

  Future<void> _deleteCategory(Map<String, dynamic> cat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف القسم',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل تريد حذف "${cat['name_ar']}"؟',
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
    final ok = await SupabaseService.instance.deleteCategory(
      cat['id'].toString(),
    );
    if (!mounted) return;
    _showMessage(
      ok
          ? 'تم حذف القسم'
          : (SupabaseService.instance.lastDeleteError.isEmpty
                ? 'تعذر حذف القسم'
                : SupabaseService.instance.lastDeleteError),
      ok,
    );
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'الأقسام',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCategory,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'قسم جديد',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _categories.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 140),
                        const Icon(
                          Icons.category_outlined,
                          size: 64,
                          color: AppColors.textHint,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            'لا توجد أقسام بعد',
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
                      itemCount: _categories.length,
                      itemBuilder: (_, i) {
                        final cat = _categories[i];
                        final image =
                            cat['image_path']?.toString() ??
                            cat['image_url']?.toString() ??
                            '';
                        return Card(
                          elevation: 1.5,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
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
                                            Icons.grid_view_rounded,
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
                                        cat['name_ar']?.toString() ??
                                            cat['name_en']?.toString() ??
                                            'قسم',
                                        style: GoogleFonts.cairo(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      // ★ لمن هذا القسم: صيدليته الخاص أم عام.
                                      //   بلا هذا السطر يتكاثر «الحلويات» عند
                                      //   أربعة صيدليات ولا يعرف الأدمن أيّها له.
                                      Padding(
                                        padding: const EdgeInsets.only(top: 3),
                                        child: Text(
                                          _ownerLabel(cat),
                                          style: GoogleFonts.cairo(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color:
                                                (_catShopId(cat) ?? '').isEmpty
                                                ? AppColors.textHint
                                                : AppColors.primary,
                                          ),
                                        ),
                                      ),
                                      if (_directoryLabelOf(cat) != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: Text(
                                            'قسم الرئيسية '
                                            '«${_directoryLabelOf(cat)}» · '
                                            'لا يظهر في صفحة الأدوية',
                                            style: GoogleFonts.cairo(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800,
                                              color: AppColors.primary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    color: AppColors.danger,
                                  ),
                                  onPressed: () => _deleteCategory(cat),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
