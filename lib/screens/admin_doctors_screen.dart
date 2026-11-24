import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/city_store.dart';
import '../services/doctor_directory_service.dart';
import '../services/supabase_service.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/working_hours_picker.dart';
import 'admin_doctor_categories_screen.dart';

/// إدارة أطباء الدليل: إضافة طبيب/مجمع/مختبر بصورته وتخصصه، تعديل، حذف.
/// ★ أي حفظ هنا يظهر في الرئيسية فوراً: `DoctorDirectoryService.refreshNow`
///   يمسح الكاش ويجلب من الشبكة ثم يُنبّه الشاشات المفتوحة.
class AdminDoctorsScreen extends StatefulWidget {
  const AdminDoctorsScreen({super.key});

  @override
  State<AdminDoctorsScreen> createState() => _AdminDoctorsScreenState();
}

class _AdminDoctorsScreenState extends State<AdminDoctorsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _doctors = const [];

  /// أقسام الدليل كما في القاعدة — تشمل ما يضيفه الأدمن من شاشة الأقسام.
  List<DoctorCategory> _cats =
      DoctorDirectoryService.instance.initialCategories;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await SupabaseService.instance.fetchDoctors();
    final cats = await DoctorDirectoryService.instance.fetchCategories(
      force: true,
    );
    if (!mounted) return;
    setState(() {
      _doctors = rows;
      _cats = cats;
      _loading = false;
    });
  }

  /// شاشة أقسام الدليل: تُضاف الشرائح وتُحذف، وتظهر للناس فوراً.
  Future<void> _openCategories() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AdminDoctorCategoriesScreen()),
    );
    if (!mounted) return;
    final cats = await DoctorDirectoryService.instance.fetchCategories();
    if (!mounted) return;
    setState(() => _cats = cats);
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

  String _errorOr(String fallback) {
    final e = SupabaseService.instance.lastAdminError.trim();
    return e.isEmpty ? fallback : e;
  }

  String _categoryLabel(String value) {
    for (final c in _cats) {
      if (c.key == value) return c.label;
    }
    return value.isEmpty ? 'الأطباء' : value;
  }

  Future<void> _add() => _edit();

  Future<void> _edit({Map<String, dynamic>? existing}) async {
    final isEdit = existing != null;
    String text(String key) => existing?[key]?.toString() ?? '';

    final nameCtrl = TextEditingController(text: text('name'));
    final titleCtrl = TextEditingController(text: text('title'));
    final specialtyCtrl = TextEditingController(text: text('specialty'));
    final areaCtrl = TextEditingController(text: text('area'));
    final phoneCtrl = TextEditingController(text: text('phone'));
    final secretaryCtrl = TextEditingController(text: text('secretary_phone'));
    final infoCtrl = TextEditingController(text: text('info'));
    final bioCtrl = TextEditingController(text: text('bio'));
    final hoursCtrl = TextEditingController(text: text('working_hours'));
    final notesCtrl = TextEditingController(text: text('notes'));
    final addressCtrl = TextEditingController(text: text('clinic_address'));
    final facebookCtrl = TextEditingController(text: text('facebook_url'));

    var category = text('category');
    if (!_cats.any((c) => c.key == category)) category = _cats.first.key;
    var city = text('city');
    if (!CityStore.cities.contains(city)) city = CityStore.cities.first;
    // ★ الطبيب الجديد مميّز افتراضياً: يدخل شريط الرأس المتحرك فوراً
    //   ويظهر للناس — والأدمن يستطيع إطفاءه.
    var featured = existing == null || existing['is_featured'] == true;
    var verified = existing?['is_verified'] == true;
    // صور الدليل المرجعي داخل الحزمة (`asset:`) لا تُعرض في الرافع.
    final initialImage = text('image_path');
    String? imagePath = initialImage.startsWith('asset:') ? '' : initialImage;
    var imageChanged = false;
    var uploadingImage = false;
    // ★ غلاف البروفايل — يضعه الأدمن وحده من هنا (طلب 2026-11-20).
    //   يبقى فارغاً حتى أول تعديل، فلا نكتب عموداً بلا حاجة.
    String coverPath = text('cover_url');
    var coverChanged = false;
    var uploadingCover = false;
    String? uploadFailure;
    final uploads = AdminUploads();

    if (!mounted) return;

    final picked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          InputDecoration deco(String label) => InputDecoration(
            labelText: label,
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          );
          return Padding(
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
                    isEdit ? 'تعديل بيانات الطبيب' : 'إضافة طبيب جديد',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  AdminImageUploader(
                    folder: 'doctors',
                    height: 130,
                    uploads: uploads,
                    initialUrl: imagePath,
                    icon: Icons.person_rounded,
                    placeholder: 'اختار صورة الطبيب من المعرض (تُرفع للسيرفر)',
                    onBusyChanged: (busy) =>
                        setSheetState(() => uploadingImage = busy),
                    onChanged: (url) {
                      imagePath = url ?? '';
                      imageChanged = true;
                      setSheetState(() {
                        if (url != null) uploadFailure = null;
                      });
                    },
                    onFailed: (msg) => setSheetState(() => uploadFailure = msg),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'غلاف البروفايل — اختياري، يظهر أعلى ملف الطبيب',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ★ الغلاف يُقصّ ليمتلئ بحجم ثابت احترافي (150 في
                  //   البروفايل)؛ هنا معاينة أفقية بنفس نسبته التقريبية.
                  //   زر X يحذفه — الأدمن وحده يملك هذا الحقل.
                  AdminImageUploader(
                    folder: 'doctors',
                    height: 96,
                    uploads: uploads,
                    initialUrl: coverPath.isEmpty ? null : coverPath,
                    icon: Icons.panorama_rounded,
                    placeholder: 'اختر صورة الغلاف من المعرض',
                    onBusyChanged: (busy) =>
                        setSheetState(() => uploadingCover = busy),
                    onChanged: (url) {
                      coverPath = url ?? '';
                      coverChanged = true;
                      setSheetState(() {
                        if (url != null) uploadFailure = null;
                      });
                    },
                    onFailed: (msg) =>
                        setSheetState(() => uploadFailure = msg),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 60,
                    decoration: deco('اسم الطبيب (إجباري)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: titleCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 90,
                    decoration: deco('اللقب / البورد (اختياري)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: specialtyCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 60,
                    decoration: deco('التخصص (اختياري)'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: city,
                    isExpanded: true,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      labelText: 'المدينة (فلتر الدليل)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    items: [
                      for (final c in CityStore.cities)
                        DropdownMenuItem(
                          value: c,
                          child: Text(
                            c,
                            style: GoogleFonts.cairo(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setSheetState(() => city = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: areaCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 40,
                    decoration: deco('المنطقة / الحي (اختياري)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: phoneCtrl,
                    textAlign: TextAlign.right,
                    keyboardType: TextInputType.phone,
                    maxLength: 20,
                    decoration: deco('رقم الهاتف (اختياري)'),
                  ),
                  const SizedBox(height: 8),
                  // ★ سكرتير العيادة: من يسجّل دخوله بهذا الرقم يصله
                  //   إشعار كل حجز جديد ويوافق أو يرفض، والكشفية تُقيَّد
                  //   في محفظة الطبيب عند الموافقة فقط. اتركه فارغاً
                  //   فيصل الحجز للمندوبين مباشرة (بلا موافقة).
                  TextField(
                    controller: secretaryCtrl,
                    textAlign: TextAlign.right,
                    keyboardType: TextInputType.phone,
                    maxLength: 20,
                    decoration: deco(
                      'رقم هاتف سكرتير العيادة (موافقات الحجوزات)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: infoCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 100,
                    decoration: deco('سطر تعريفي إضافي (اختياري)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: addressCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 120,
                    decoration: deco('عنوان العيادة (يظهر في البروفايل)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: bioCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 800,
                    minLines: 3,
                    maxLines: 5,
                    decoration: deco('نبذة مهنية (تظهر في البروفايل)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: hoursCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 200,
                    minLines: 2,
                    maxLines: 4,
                    decoration: deco('وقت الدوام الرسمي (أيام/ساعات العمل)'),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () async {
                        final picked = await showWorkingHoursPicker(
                          ctx,
                          initialText: hoursCtrl.text,
                          title: 'أيام وساعات دوام الطبيب',
                        );
                        if (picked == null || !ctx.mounted) return;
                        hoursCtrl.text = picked.text;
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.calendar_month_rounded, size: 18),
                      label: Text(
                        'تحديد الأيام والساعة',
                        style: GoogleFonts.cairo(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: notesCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 300,
                    minLines: 2,
                    maxLines: 4,
                    decoration: deco('ملاحظات (أجهزة متوفرة، تعليمات...)'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: facebookCtrl,
                    textAlign: TextAlign.right,
                    maxLength: 200,
                    keyboardType: TextInputType.url,
                    decoration: deco(
                      'رابط التواصل — فيسبوك/إنستغرام/تيك توك/يوتيوب/تيليگرام/فايبر/واتساب/Google Play (اختياري — الأيقونة تتبع الرابط)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    isExpanded: true,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      labelText: 'الفئة',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    items: [
                      for (final c in _cats)
                        DropdownMenuItem(
                          value: c.key,
                          child: Text(
                            c.label,
                            style: GoogleFonts.cairo(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setSheetState(() => category = v);
                    },
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    value: featured,
                    activeThumbColor: AppColors.primary,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'مميّز — يظهر في الشريط العلوي',
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onChanged: (v) => setSheetState(() => featured = v),
                  ),
                  SwitchListTile(
                    value: verified,
                    activeThumbColor: AppColors.primary,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'موثّق — شارة زرقاء بجانب الاسم',
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onChanged: (v) => setSheetState(() => verified = v),
                  ),
                  if (uploadFailure != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '$uploadFailure\nأعد رفع الصورة أو امسحها قبل الحفظ.',
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        color: AppColors.danger,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  FilledButton(
                    // ★ لا حفظ قبل اكتمال رفع الصورة (وإلا حُفظ بلا صورة)
                    //   ولا بعد فشل الرفع حتى يعيد المحاولة أو يمسحها.
                    onPressed:
                        uploadingImage ||
                            uploadingCover ||
                            uploadFailure != null
                        ? null
                        : () {
                            if (nameCtrl.text.trim().isEmpty) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'أدخل اسم الطبيب',
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
                      uploadingImage || uploadingCover
                          ? 'انتظر اكتمال رفع الصورة...'
                          : isEdit
                          ? 'حفظ التعديل'
                          : 'إضافة الطبيب',
                      style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (picked != true) {
      uploads.discard();
      nameCtrl.dispose();
      titleCtrl.dispose();
      specialtyCtrl.dispose();
      areaCtrl.dispose();
      phoneCtrl.dispose();
      secretaryCtrl.dispose();
      infoCtrl.dispose();
      bioCtrl.dispose();
      hoursCtrl.dispose();
      notesCtrl.dispose();
      addressCtrl.dispose();
      facebookCtrl.dispose();
      return;
    }

    final ok = isEdit
        ? await SupabaseService.instance.updateDoctor(text('id'), {
            'name': nameCtrl.text.trim(),
            'title': titleCtrl.text.trim(),
            'specialty': specialtyCtrl.text.trim(),
            'area': areaCtrl.text.trim(),
            'city': city,
            'phone': phoneCtrl.text.trim(),
            'info': infoCtrl.text.trim(),
            'category': category,
            'is_featured': featured,
            'is_verified': verified,
            if (imageChanged) 'image_path': imagePath ?? '',
            'bio': bioCtrl.text.trim(),
            'working_hours': hoursCtrl.text.trim(),
            'notes': notesCtrl.text.trim(),
            'clinic_address': addressCtrl.text.trim(),
            'facebook_url': facebookCtrl.text.trim(),
            'secretary_phone': secretaryCtrl.text.trim(),
            if (coverChanged) 'cover_url': coverPath.trim(),
          })
        : await SupabaseService.instance.addDoctor(
            name: nameCtrl.text.trim(),
            title: titleCtrl.text.trim(),
            specialty: specialtyCtrl.text.trim(),
            area: areaCtrl.text.trim(),
            city: city,
            phone: phoneCtrl.text.trim(),
            info: infoCtrl.text.trim(),
            category: category,
            imagePath: imagePath ?? '',
            isFeatured: featured,
            isVerified: verified,
            bio: bioCtrl.text.trim(),
            workingHours: hoursCtrl.text.trim(),
            notes: notesCtrl.text.trim(),
            clinicAddress: addressCtrl.text.trim(),
            facebookUrl: facebookCtrl.text.trim(),
            secretaryPhone: secretaryCtrl.text.trim(),
            coverUrl: coverPath.trim(),
          );

    // ★ يُلتقطان قبل التخلّص من الحقول: الاسم الجديد يُكتب أيضاً في
    //   حساب المستخدم (`users.name`) إن كان للطبيب رقم حساب، فيتغيّر
    //   في «حسابي» كما تغيّر في الدليل.
    final savedName = nameCtrl.text.trim();
    final savedPhone = phoneCtrl.text.trim();

    nameCtrl.dispose();
    titleCtrl.dispose();
    specialtyCtrl.dispose();
    areaCtrl.dispose();
    phoneCtrl.dispose();
    secretaryCtrl.dispose();
    infoCtrl.dispose();
    bioCtrl.dispose();
    hoursCtrl.dispose();
    notesCtrl.dispose();
    addressCtrl.dispose();
    facebookCtrl.dispose();

    if (!mounted) return;
    if (ok) {
      uploads.keep();
    } else {
      uploads.discard();
    }
    _snack(
      ok
          ? (isEdit ? 'تم حفظ التعديل' : 'تمت إضافة الطبيب')
          : _errorOr(isEdit ? 'تعذر حفظ التعديل' : 'تعذر إضافة الطبيب'),
      ok,
    );
    if (ok) {
      // ★ ملف الدليل والملف الشخصي اسم واحد: تعديل الاسم هنا يظهر
      //   في «حسابي» خلال دورة مزامنة الحساب، بلا إعادة دخول.
      if (isEdit && savedPhone.isNotEmpty) {
        await SupabaseService.instance.updateUser(savedPhone, {
          'name': savedName,
        });
      }
      await DoctorDirectoryService.instance.refreshNow();
      if (!mounted) return;
      _load();
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف من الدليل',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل تريد حذف "${row['name']}" من دليل الأطباء؟',
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
    final ok = await SupabaseService.instance.deleteDoctor(
      row['id']?.toString() ?? '',
    );
    if (!mounted) return;
    _snack(ok ? 'تم الحذف من الدليل' : _errorOr('تعذر حذف الطبيب'), ok);
    if (ok) {
      await DoctorDirectoryService.instance.refreshNow();
      if (!mounted) return;
      _load();
    }
  }

  Widget _avatar(Map<String, dynamic> row) {
    final path = row['image_path']?.toString() ?? '';
    final isBundled = path.startsWith('asset:');
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 54,
        height: 54,
        child: path.isEmpty
            ? const _AvatarFallback()
            : isBundled
            ? Image.asset(
                path.substring(6),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _AvatarFallback(),
              )
            : AppImage(
                path,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _AvatarFallback(),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'إدارة الأطباء',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'أقسام الدليل',
            icon: const Icon(Icons.category_outlined),
            onPressed: _openCategories,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(
          'إضافة طبيب',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _doctors.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 140),
                        const Icon(
                          Icons.medical_services_outlined,
                          size: 64,
                          color: AppColors.textHint,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            'لا يوجد أطباء بعد',
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
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                      itemCount: _doctors.length,
                      itemBuilder: (_, i) {
                        final row = _doctors[i];
                        final name = row['name']?.toString() ?? 'طبيب';
                        final specialty = row['specialty']?.toString() ?? '';
                        final area = row['area']?.toString() ?? '';
                        final city = row['city']?.toString() ?? '';
                        final featured = row['is_featured'] == true;
                        final verified = row['is_verified'] == true;
                        return Card(
                          elevation: 1.5,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _avatar(row),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: GoogleFonts.cairo(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w800,
                                                color: AppColors.textPrimary,
                                              ),
                                            ),
                                          ),
                                          if (verified) ...[
                                            const SizedBox(width: 4),
                                            const Icon(
                                              Icons.verified_rounded,
                                              size: 15,
                                              color: Color(0xFF1D9BF0),
                                            ),
                                          ],
                                        ],
                                      ),
                                      if (specialty.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          specialty,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.cairo(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 5),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          _Tag(
                                            _categoryLabel(
                                              row['category']?.toString() ?? '',
                                            ),
                                          ),
                                          if (featured)
                                            const _Tag(
                                              'مميّز',
                                              color: AppColors.primary,
                                            ),
                                          if (city.isNotEmpty)
                                            _Tag(
                                              city,
                                              color: AppColors.primaryDark,
                                            ),
                                          if (area.isNotEmpty) _Tag(area),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'تعديل',
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                    color: AppColors.primary,
                                  ),
                                  onPressed: () => _edit(existing: row),
                                ),
                                IconButton(
                                  tooltip: 'حذف',
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                    color: AppColors.danger,
                                  ),
                                  onPressed: () => _delete(row),
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

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primaryLight,
      child: const Icon(
        Icons.person_rounded,
        color: AppColors.primary,
        size: 28,
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: GoogleFonts.cairo(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: c,
        ),
      ),
    );
  }
}
