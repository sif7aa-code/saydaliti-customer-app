import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/doctor_directory_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ إدارة أقسام دليل الأطباء (شرائح أعلى الرئيسية): الأدمن يضيف قسماً
///   جديداً مثل «الأطباء والمجمعات الطبية والمختبرات» فيظهر كزرّ للناس
///   فوراً، ويستطيع حذف أي قسم أضافه (الأساسية الثلاثة محمية).
///
///   التخزين في جدول `doctor_categories` (SQL_DOCTOR_DIRECTORY_CATEGORIES.sql)
///   والكتابة محمية ببوابة الأدمن في القاعدة.
class AdminDoctorCategoriesScreen extends StatefulWidget {
  const AdminDoctorCategoriesScreen({super.key});

  @override
  State<AdminDoctorCategoriesScreen> createState() =>
      _AdminDoctorCategoriesScreenState();
}

class _AdminDoctorCategoriesScreenState
    extends State<AdminDoctorCategoriesScreen> {
  bool _loading = true;
  List<DoctorCategory> _cats = const [];
  Map<String, int> _counts = const {};

  /// حفظ ترتيب جارٍ — يعطّل الأسهم حتى لا يتزاحم طلبان في نفس اللحظة.
  bool _savingOrder = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final cats = await DoctorDirectoryService.instance.fetchCategories(
      force: true,
    );
    final rows = await SupabaseService.instance.fetchDoctors();
    final counts = <String, int>{};
    for (final r in rows) {
      final c = r['category']?.toString() ?? '';
      if (c.isEmpty) continue;
      counts[c] = (counts[c] ?? 0) + 1;
    }
    if (!mounted) return;
    setState(() {
      _cats = cats;
      _counts = counts;
      _loading = false;
    });
  }

  void _snack(String msg, bool ok) {
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

  bool _isBuiltin(String key) =>
      DoctorDirectoryService.builtinCategories.any((c) => c.key == key);

  /// رسالة داخل الورقة نفسها (لا تُخفى خلفها كما يفعل snackbar الشاشة).
  void _sheetMessage(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
        ),
      );
  }

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    if (!mounted) return;
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
                'إضافة قسم جديد',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'يظهر كزرّ أعلى الرئيسية فقط — لا في صفحة الأدوية — لكل '
                'المستخدمين فوراً. تنقل إليه الأطباء من إدارة الأطباء، '
                'والمنتجات والصيدليات من إدارة المنتجات وإدارة الصيدليات.',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                textAlign: TextAlign.right,
                maxLength: 30,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'اسم القسم',
                  hintText: 'مثال: مراكز العلاج الطبيعي',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    _sheetMessage(ctx, 'أدخل اسم القسم');
                    return;
                  }
                  if (_cats.any((c) => c.label.trim() == name)) {
                    _sheetMessage(ctx, 'هذا القسم موجود مسبقاً');
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
    );
    final name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (picked != true || name.isEmpty) return;
    final ok = await DoctorDirectoryService.instance.addCategory(name);
    if (!mounted) return;
    _snack(
      ok
          ? 'تمت إضافة «$name» — ظهر الآن في الرئيسية'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر إضافة القسم'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _load();
  }

  Future<void> _delete(DoctorCategory cat) async {
    if (_isBuiltin(cat.key)) {
      _snack('القسم الأساسي لا يُحذف', false);
      return;
    }
    final count = _counts[cat.key] ?? 0;
    // ★ 2026-11-20: لم يعد القسم الذي فيه عناصر محجوباً — يُنقل أطباؤه
    //   إلى «الأطباء» ثم يُحذف، فيبقى كل طبيب ظاهراً في الدليل.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف القسم',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          count > 0
              ? '«${cat.label}» فيه $count عنصراً — سيُنقلون إلى «الأطباء» '
                    'ثم يُحذف القسم ويختفي زرّه من الرئيسية.'
              : 'هل تريد حذف «${cat.label}»؟ سيختفي زرّه من الرئيسية.',
          style: GoogleFonts.cairo(fontSize: 14, height: 1.7),
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
    var movedAll = true;
    if (count > 0) {
      final rows = await SupabaseService.instance.fetchDoctors();
      for (final r in rows) {
        if ((r['category']?.toString() ?? '') != cat.key) continue;
        final moved = await SupabaseService.instance.updateDoctor(
          r['id'].toString(),
          {'category': 'doctors'},
        );
        if (!moved) movedAll = false;
      }
      if (!mounted) return;
      if (!movedAll) {
        _snack(
          SupabaseService.instance.lastAdminError.isEmpty
              ? 'تعذر نقل بعض العناصر — لم يُحذف القسم'
              : SupabaseService.instance.lastAdminError,
          false,
        );
        _load();
        return;
      }
      await DoctorDirectoryService.instance.refreshNow();
      if (!mounted) return;
    }
    final ok = await DoctorDirectoryService.instance.deleteCategory(cat.key);
    if (!mounted) return;
    _snack(
      ok
          ? 'تم حذف القسم'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر حذف القسم'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _load();
  }

  IconData _icon(String key) => switch (key) {
    'doctors' => Icons.person_outline_rounded,
    'complexes' => Icons.apartment_rounded,
    'labs' => Icons.biotech_outlined,
    _ => Icons.medical_services_outlined,
  };

  /// ★ ترتيب الشرائح: نغيّر القائمة محلياً (تظهر فوراً) ثم نكتب الترتيب
  ///   في القاعدة: كل قسم يأخذ `sort_order` = 10, 20, 30... فالرئيسية
  ///   تعرض الشرائح بنفس هذا الترتيب (استعلامها مرتّب بـsort_order).
  ///   فشل الحفظ يعيد تحميل الحقيقة من الخادم بدل عرض ترتيب وهمي.
  Future<void> _applyOrder(List<DoctorCategory> list, String success) async {
    setState(() {
      _cats = list;
      _savingOrder = true;
    });
    final ok = await DoctorDirectoryService.instance.reorderCategories(
      [for (final c in list) c.key],
    );
    if (!mounted) return;
    setState(() => _savingOrder = false);
    if (!ok) {
      _snack(
        SupabaseService.instance.lastAdminError.isEmpty
            ? 'تعذر حفظ الترتيب'
            : SupabaseService.instance.lastAdminError,
        false,
      );
      _load();
      return;
    }
    _snack(success, true);
  }

  /// حرّك القسم خطوة واحدة: -1 أعلى، +1 أسفل.
  Future<void> _move(int index, int delta) async {
    final to = index + delta;
    if (_savingOrder || to < 0 || to >= _cats.length) return;
    final list = [..._cats];
    final item = list.removeAt(index);
    list.insert(to, item);
    await _applyOrder(list, 'تم حفظ الترتيب');
  }

  /// تثبيت القسم في المقدمة: يصير أول شريحة، والقسم الجديد يبقى آخراً.
  Future<void> _pinFirst(int index) async {
    if (_savingOrder || index <= 0) return;
    final list = [..._cats];
    final item = list.removeAt(index);
    list.insert(0, item);
    await _applyOrder(list, 'ثُبّت «${item.label}» أولاً');
  }

  /// زر سهم صغير لتحريك القسم — معطّل في الطرفين.
  Widget _arrowButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 34),
      icon: Icon(
        icon,
        size: 22,
        color: onTap == null ? AppColors.textHint : AppColors.textSecondary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'أقسام الدليل',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
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
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                itemCount: _cats.length + 1,
                itemBuilder: (_, i) {
                  if (i == _cats.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        'قسم «الأطباء» أساسي ويظهر دائماً. سهمَا أعلى/أسفل '
                        'يحرّكان القسم، وزر الدبوس يثبته أولاً — الترتيب يُحفظ '
                        'في القاعدة فتظهر الشرائح للناس بنفسه. كل قسم تضيفه '
                        'يظهر كزرّ أعلى الرئيسية وحدها (لا في صفحة الأدوية)، '
                        'وصنّف تحته الأطباء من «إدارة الأطباء» → حقل الفئة، '
                        'والمنتجات من «المنتجات» → نقل، والصيدليات من '
                        '«الصيدليات» → قسم الصيدلية.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.cairo(
                          fontSize: 11.5,
                          height: 1.7,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textHint,
                        ),
                      ),
                    );
                  }
                  final cat = _cats[i];
                  final builtin = _isBuiltin(cat.key);
                  final count = _counts[cat.key] ?? 0;
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
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: AppColors.primaryLight,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              _icon(cat.key),
                              color: AppColors.primary,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  cat.label,
                                  style: GoogleFonts.cairo(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${builtin ? 'أساسي' : 'زرّ في الرئيسية'} · '
                                  '$count عنصراً · الترتيب ${i + 1}',
                                  style: GoogleFonts.cairo(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: builtin
                                        ? AppColors.textHint
                                        : AppColors.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _arrowButton(
                            icon: Icons.keyboard_arrow_up_rounded,
                            tooltip: 'أعلى',
                            onTap: (i == 0 || _savingOrder)
                                ? null
                                : () => _move(i, -1),
                          ),
                          _arrowButton(
                            icon: Icons.keyboard_arrow_down_rounded,
                            tooltip: 'أسفل',
                            onTap: (i == _cats.length - 1 || _savingOrder)
                                ? null
                                : () => _move(i, 1),
                          ),
                          IconButton(
                            tooltip: i == 0 ? 'مثبت أولاً' : 'تثبيت أولاً',
                            onPressed: (i == 0 || _savingOrder)
                                ? null
                                : () => _pinFirst(i),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 30,
                              height: 34,
                            ),
                            icon: Icon(
                              i == 0
                                  ? Icons.push_pin_rounded
                                  : Icons.push_pin_outlined,
                              size: 19,
                              color: i == 0
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                            ),
                          ),
                          if (!builtin)
                            IconButton(
                              tooltip: 'حذف',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 34,
                              ),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                color: AppColors.danger,
                              ),
                              onPressed: () => _delete(cat),
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
