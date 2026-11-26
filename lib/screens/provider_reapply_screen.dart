import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/city_store.dart';
import '../services/supabase_service.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/provider_application_notice.dart';
import '../widgets/working_hours_picker.dart';

/// إعادة إرسال طلب الانضمام بعد الرفض: نفس حقول الطلب الأولى مُعبّأة
/// من الطلب السابق، والتعديل مسموح قبل الإرسال. الإرسال يُنشئ طلباً
/// جديداً بحالة «قيد المراجعة» (الطلب المرفوض يبقى في السجل).
class ProviderReapplyScreen extends StatefulWidget {
  const ProviderReapplyScreen({super.key});

  @override
  State<ProviderReapplyScreen> createState() => _ProviderReapplyScreenState();
}

class _ProviderReapplyScreenState extends State<ProviderReapplyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _specialtyController = TextEditingController();
  final _bioController = TextEditingController();
  final _hoursController = TextEditingController();
  final _shopNameController = TextEditingController();
  final _uploads = AdminUploads();

  bool _loading = true;
  bool _saving = false;
  bool _photoBusy = false;
  bool _proofBusy = false;
  String _failure = '';
  String _category = 'doctor';
  String _city = CityStore.instance.chosen ?? CityStore.cities.first;
  String? _photoUrl;
  String? _proofUrl;
  String _lastReason = '';

  String get _phone => AuthService.instance.phone ?? '';

  String get _categoryLabel => switch (_category) {
    'doctor' => 'طبيب',
    'nurse' => 'ممرض',
    'pharmacist' => 'صيدلاني',
    _ => '',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _specialtyController.dispose();
    _bioController.dispose();
    _hoursController.dispose();
    _shopNameController.dispose();
    _uploads.discard();
    super.dispose();
  }

  static String _text(Object? v) => (v ?? '').toString().trim();

  Future<void> _load() async {
    final app = await SupabaseService.instance.myProviderApplication();
    if (!mounted) return;
    if (app == null) {
      setState(() {
        _loading = false;
        _failure = 'لا يوجد طلب انضمام سابق لهذا الحساب';
      });
      return;
    }
    final category = _text(app['category']);
    setState(() {
      _category = category.isEmpty ? 'doctor' : category;
      _nameController.text = _text(app['full_name']);
      _specialtyController.text = _text(app['specialty']);
      _bioController.text = _text(app['bio']);
      _hoursController.text = _text(app['working_hours']);
      _shopNameController.text = _text(app['shop_name']);
      final city = _text(app['city']);
      if (CityStore.cities.contains(city)) _city = city;
      _photoUrl = _text(app['photo_url']).isEmpty ? null : _text(app['photo_url']);
      _proofUrl = _text(app['proof_url']).isEmpty ? null : _text(app['proof_url']);
      _lastReason = _text(app['admin_note']);
      _loading = false;
    });
  }

  void _toast(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, textAlign: TextAlign.center),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
        ),
      );
  }

  Future<void> _submit() async {
    if (_saving || _photoBusy || _proofBusy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if ((_photoUrl ?? '').isEmpty) {
      _toast('ارفع صورة شخصية واضحة');
      return;
    }
    if ((_proofUrl ?? '').isEmpty) {
      _toast('ارفع مرفق الإثبات — إجباري');
      return;
    }
    if (_hoursController.text.trim().isEmpty) {
      _toast('اكتب أوقات العمل');
      return;
    }

    setState(() => _saving = true);
    final res = await SupabaseService.instance.providerApply(
      category: _category,
      fullName: _nameController.text.trim(),
      specialty: _specialtyController.text.trim(),
      bio: _bioController.text.trim(),
      workingHours: _hoursController.text.trim(),
      city: _category == 'doctor' ? _city : '',
      shopName: _shopNameController.text.trim(),
      photoUrl: _photoUrl ?? '',
      proofUrl: _proofUrl ?? '',
    );
    if (!mounted) return;
    if (res['ok'] != true) {
      setState(() => _saving = false);
      _toast((res['error'] ?? 'تعذّر إرسال الطلب').toString());
      return;
    }

    _uploads.keep();
    ProviderApplicationNotice.notifyChanged();
    await _showSent();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _showSent() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تم إرسال طلبك مجدداً',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'وصل طلب الانضمام بصفة «$_categoryLabel» إلى الإدارة مع التعديلات. '
          'ستظهر حالتك هنا بعد المراجعة.',
          style: GoogleFonts.cairo(fontSize: 14, height: 1.7),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(
              'حسناً',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _deco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.cairo(
      color: AppColors.textHint,
      fontWeight: FontWeight.w600,
      fontSize: 12.5,
    ),
    counterText: '',
    filled: true,
    fillColor: Colors.white,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.divider),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      text,
      style: GoogleFonts.cairo(
        fontSize: 12.5,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(
          'إعادة إرسال الطلب',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failure.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _failure,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            )
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildSummaryCard(),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label('نوع الحساب'),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in const {
                              'doctor': 'طبيب',
                              'nurse': 'ممرض',
                              'pharmacist': 'صيدلاني',
                            }.entries)
                              ChoiceChip(
                                label: Text(
                                  entry.value,
                                  style: GoogleFonts.cairo(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                    color: _category == entry.key
                                        ? Colors.white
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                selected: _category == entry.key,
                                selectedColor: AppColors.primary,
                                backgroundColor: AppColors.primaryLight
                                    .withValues(alpha: 0.35),
                                onSelected: (_) =>
                                    setState(() => _category = entry.key),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _label('الاسم الكامل كما في الإثبات'),
                        TextFormField(
                          controller: _nameController,
                          textAlign: TextAlign.right,
                          maxLength: 120,
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                          decoration: _deco('الاسم الكامل'),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'اكتب الاسم'
                              : null,
                        ),
                        if (_category == 'doctor') ...[
                          const SizedBox(height: 8),
                          _label('التخصص'),
                          TextFormField(
                            controller: _specialtyController,
                            textAlign: TextAlign.right,
                            maxLength: 60,
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                            decoration: _deco(
                              'مثال: الطب الباطني / جراحة العظام',
                            ),
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? 'اكتب تخصصك'
                                : null,
                          ),
                          const SizedBox(height: 8),
                          _label('نبذة عن الاختصاص'),
                          TextFormField(
                            controller: _bioController,
                            textAlign: TextAlign.right,
                            maxLength: 800,
                            minLines: 3,
                            maxLines: 4,
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                            decoration: _deco(
                              'سنوات الخبرة، الشهادات، مجالات العمل',
                            ),
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? 'اكتب نبذة عن اختصاصك'
                                : null,
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: CityStore.cities.contains(_city)
                                ? _city
                                : CityStore.cities.first,
                            isExpanded: true,
                            style: GoogleFonts.cairo(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              labelText: 'المدينة',
                              filled: true,
                              fillColor: Colors.white,
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
                              if (v != null) setState(() => _city = v);
                            },
                          ),
                        ],
                        if (_category == 'pharmacist') ...[
                          const SizedBox(height: 8),
                          _label('اسم الصيدلية'),
                          TextFormField(
                            controller: _shopNameController,
                            textAlign: TextAlign.right,
                            maxLength: 60,
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                            decoration: _deco(
                              'الاسم كما سيظهر في التطبيق',
                            ),
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? 'اكتب اسم الصيدلية'
                                : null,
                          ),
                        ],
                        const SizedBox(height: 8),
                        _label('أوقات العمل'),
                        TextFormField(
                          controller: _hoursController,
                          textAlign: TextAlign.right,
                          maxLength: 200,
                          minLines: 2,
                          maxLines: 3,
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                          decoration: _deco('أيام وساعات العمل'),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'اكتب أوقات العمل'
                              : null,
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            onPressed: () async {
                              final picked = await showWorkingHoursPicker(
                                context,
                                initialText: _hoursController.text,
                                title: 'أيام وساعات العمل',
                              );
                              if (picked == null) return;
                              _hoursController.text = picked.text;
                            },
                            icon: const Icon(
                              Icons.calendar_month_rounded,
                              size: 18,
                            ),
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
                        _label('الصورة الشخصية (إجبارية)'),
                        AdminImageUploader(
                          folder: 'applications',
                          height: 110,
                          uploads: _uploads,
                          initialUrl: _photoUrl,
                          icon: Icons.person_rounded,
                          placeholder: 'اختر صورة شخصية واضحة',
                          onBusyChanged: (b) => setState(() => _photoBusy = b),
                          onChanged: (url) => setState(() => _photoUrl = url),
                          onFailed: (m) => _toast(m),
                        ),
                        const SizedBox(height: 10),
                        _label(
                          'مرفق الإثبات (إجباري) — هوية/شهادة/إجازة مزاولة',
                        ),
                        AdminImageUploader(
                          folder: 'applications',
                          height: 110,
                          uploads: _uploads,
                          initialUrl: _proofUrl,
                          icon: Icons.badge_rounded,
                          uploadedLabel: 'مرفوعة',
                          placeholder: 'ارفع صورة الإثبات',
                          onBusyChanged: (b) => setState(() => _proofBusy = b),
                          onChanged: (url) => setState(() => _proofUrl = url),
                          onFailed: (m) => _toast(m),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _saving ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.send_rounded, size: 18),
                          label: Text(
                            _saving ? 'جارٍ الإرسال…' : 'إرسال الطلب مجدداً',
                            style: GoogleFonts.cairo(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
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
  }

  Widget _buildSummaryCard() {
    final reason = _lastReason;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.dangerLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.danger.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.gpp_bad_rounded,
                color: AppColors.danger,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'طلبك السابق رُفض',
                  style: GoogleFonts.cairo(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.6,
                color: AppColors.textPrimary,
              ),
            ),
          ],
          if (_phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.phone_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  'رقم الهاتف المسجَّل في الطلب: $_phone',
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
