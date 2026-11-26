import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/auth_fields.dart';
import '../services/auth_service.dart';
import '../services/city_store.dart';
import '../services/supabase_service.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/auth_inputs.dart';
import '../widgets/auth_shell.dart';
import '../widgets/whatsapp_code_field.dart';
import '../widgets/working_hours_picker.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _specialtyController = TextEditingController();
  final _bioController = TextEditingController();
  final _hoursController = TextEditingController();
  final _shopNameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _codeKey = GlobalKey<WhatsappCodeFieldState>();
  final _uploads = AdminUploads();
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _codeVerified = false;

  /// '' = زبون عادي، أو doctor / nurse / pharmacist.
  String _profession = '';
  String _city = CityStore.instance.chosen ?? CityStore.cities.first;
  String? _photoUrl;
  String? _proofUrl;
  bool _uploadingPhoto = false;
  bool _uploadingProof = false;
  String? _uploadFailure;

  /// أُنشئ الحساب فعلاً في القاعدة: إعادة المحاولة ترسل الطلب وحده
  /// ولا تُعيد التسجيل (الرقم صار مسجّلاً).
  bool _accountReady = false;

  bool get _isProvider => _profession.isNotEmpty;

  String get _professionLabel => switch (_profession) {
    'doctor' => 'طبيب',
    'nurse' => 'ممرض',
    'pharmacist' => 'صيدلاني',
    _ => '',
  };

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _specialtyController.dispose();
    _bioController.dispose();
    _hoursController.dispose();
    _shopNameController.dispose();
    // ★ خروج من الشاشة بلا إرسال ناجح: امسح ما رُفع في السحابة
    //   (keep() عند نجاح الإرسال يمنع المسح).
    _uploads.discard();
    super.dispose();
  }

  void _toast(String msg, {bool danger = false}) {
    if (!mounted) return;
    // ★ عنصر مُهمَل يمرّ من فحص mounted ثم يرمي من ScaffoldMessenger.of
    //   — والرمي هنا كان يقتل _submit ويترك زر الإنشاء دائراً للأبد.
    try {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              msg,
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: danger ? AppColors.danger : AppColors.primary,
          ),
        );
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (_isLoading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // لا يُنشأ حساب بدون تأكيد ملكية الرقم بكود واتساب.
    if (!_codeVerified) {
      final ok = await _codeKey.currentState?.verify() ?? false;
      if (!ok) {
        _toast('أرسل الكود وأدخله لتأكيد رقمك', danger: true);
        return;
      }
    }

    // ★ حقول الفئة المهنية تُفحص هنا: الصور تُرفع فوراً والروابط تصل
    //   عبر onChanged، فالفحص قبل أي طلب شبكة.
    if (_isProvider) {
      if ((_photoUrl ?? '').isEmpty) {
        _toast('ارفع صورة شخصية واضحة', danger: true);
        return;
      }
      if ((_proofUrl ?? '').isEmpty) {
        _toast('ارفع مرفق الإثبات — إجباري', danger: true);
        return;
      }
      if (_hoursController.text.trim().isEmpty) {
        _toast('اكتب أوقات العمل', danger: true);
        return;
      }
      if (_profession == 'doctor' &&
          (_specialtyController.text.trim().isEmpty ||
              _bioController.text.trim().isEmpty)) {
        _toast('اكتب التخصص ونبذة عن الاختصاص', danger: true);
        return;
      }
      if (_profession == 'pharmacist' &&
          _shopNameController.text.trim().isEmpty) {
        _toast('اكتب اسم الصيدلية', danger: true);
        return;
      }
    }

    setState(() => _isLoading = true);
    // ★ نجاح الإنشاء يخرج من الشاشة؛ finally لا يعيد الحالة بعده.
    var navigated = false;

    try {
      if (!_accountReady) {
        // إنشاء حساب حقيقي في قاعدة البيانات: يمنع الحسابات الوهمية.
        final result = await SupabaseService.instance.registerUser(
          name: _nameController.text.trim(),
          phone: _phoneController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
        if (!result.created) {
          _toast(result.error ?? 'تعذر إنشاء الحساب', danger: true);
          return;
        }
        await AuthService.instance.login(
          name: result.name ?? _nameController.text.trim(),
          phone: _phoneController.text.trim(),
          // ★ التوكن من `register_user`: بدونه يخرج المستخدم من حسابه
          //   الجديد عند أول طلب (401 على كل دالة تعتمد app.current_phone()).
          sessionToken: result.token,
        );
        _accountReady = true;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_phone', _phoneController.text.trim());
        } catch (_) {}
      }
      if (!mounted) return;

      // ★ حساب مهني: يُرسل طلب الانضمام بعد إنشاء الحساب مباشرة،
      //   ولا يدخل الواجهة الرسمية إلا بعد موافقة الأدمن.
      if (_isProvider) {
        final applied = await SupabaseService.instance.providerApply(
          category: _profession,
          fullName: _nameController.text.trim(),
          specialty: _specialtyController.text.trim(),
          bio: _bioController.text.trim(),
          workingHours: _hoursController.text.trim(),
          city: _profession == 'doctor' ? _city : '',
          shopName: _shopNameController.text.trim(),
          photoUrl: _photoUrl ?? '',
          proofUrl: _proofUrl ?? '',
        );
        if (!mounted) return;
        if (applied['ok'] != true) {
          // الحساب أُنشئ فعلاً؛ نبقى في الشاشة ليضغط «إنشاء الحساب»
          // مجدداً فتُعاد محاولة إرسال الطلب وحده بلا تسجيل مكرّر.
          _toast(
            (applied['error'] ?? 'تعذّر إرسال طلب الانضمام').toString(),
            danger: true,
          );
          return;
        }
        _uploads.keep();
        await _showApplicationSent();
        if (!mounted) return;
        navigated = true;
        Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }

      // ★★ `home` في app.dart هو من يختار الشاشة حسب الدور.
      navigated = true;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      // ★ أي استثناء أثناء الطيران لا يجوز أن يترك الزر دائراً للأبد،
      //   ولا أن يضيع ردّ نجاحٍ وصل فعلاً من القاعدة.
      if (mounted && !navigated) {
        _toast('حدث خطأ غير متوقع، حاول مجدداً', danger: true);
      }
    } finally {
      if (mounted && !navigated && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _showApplicationSent() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تم إرسال طلبك',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'وصل طلب انضمامك بصفة «$_professionLabel» إلى الإدارة مع الإثبات. '
          'بعد الموافقة يظهر حسابك رسمياً في التطبيق وتُفتح لك واجهة '
          '«$_professionLabel» تلقائياً.',
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

  @override
  Widget build(BuildContext context) {
    return AuthScreenScaffold(
      card: Form(
        key: _formKey,
        child: _RegisterCard(
          nameController: _nameController,
          phoneController: _phoneController,
          passwordController: _passwordController,
          codeKey: _codeKey,
          codeVerified: _codeVerified,
          onCodeVerifiedChanged: (v) {
            // ★ النداء قد يصل من microtask مؤجَّل بعد
            //   إغلاق الشاشة — setState على state مُلقى
            //   يرمي. الفحص يحمي.
            if (mounted) setState(() => _codeVerified = v);
          },
          obscurePassword: _obscurePassword,
          onTogglePassword: () => setState(
            () => _obscurePassword = !_obscurePassword,
          ),
          // ★ حقل الكود يقرأ الرقم من `phoneController`
          //   وقت البناء لا وقت النقر: بلا إعادة بناء
          //   عند الكتابة يبقى عنده الرقم القديم (أو
          //   فراغاً)، فيُرسل الكود لغير رقم أو يُرفض
          //   بحجة «أدخل رقم الهاتف» بعد أن كتبه.
          onPhoneChanged: () => setState(() {}),
          onSubmit: _submit,
          isLoading: _isLoading,
          profession: _profession,
          onProfessionChanged: (v) => setState(() => _profession = v),
          specialtyController: _specialtyController,
          bioController: _bioController,
          hoursController: _hoursController,
          shopNameController: _shopNameController,
          city: _city,
          onCityChanged: (v) => setState(() => _city = v),
          uploads: _uploads,
          photoUrl: _photoUrl,
          proofUrl: _proofUrl,
          uploadFailure: _uploadFailure,
          uploadingFiles: _uploadingPhoto || _uploadingProof,
          onPhotoBusy: (b) => setState(() => _uploadingPhoto = b),
          onProofBusy: (b) => setState(() => _uploadingProof = b),
          onPhotoChanged: (url) => setState(() {
            _photoUrl = url;
            if (url != null) _uploadFailure = null;
          }),
          onProofChanged: (url) => setState(() {
            _proofUrl = url;
            if (url != null) _uploadFailure = null;
          }),
          onUploadFailed: (m) => setState(() => _uploadFailure = m),
        ),
      ),
      footer: AuthFooterWave(
        label: 'لديك حساب بالفعل؟ سجّل الدخول',
        onPressed: () => Navigator.pop(context),
      ),
    );
  }
}

class _RegisterCard extends StatelessWidget {
  const _RegisterCard({
    required this.nameController,
    required this.phoneController,
    required this.passwordController,
    required this.codeKey,
    required this.codeVerified,
    required this.onCodeVerifiedChanged,
    required this.obscurePassword,
    required this.onTogglePassword,
    required this.onPhoneChanged,
    required this.onSubmit,
    required this.isLoading,
    required this.profession,
    required this.onProfessionChanged,
    required this.specialtyController,
    required this.bioController,
    required this.hoursController,
    required this.shopNameController,
    required this.city,
    required this.onCityChanged,
    required this.uploads,
    required this.photoUrl,
    required this.proofUrl,
    required this.uploadFailure,
    required this.uploadingFiles,
    required this.onPhotoBusy,
    required this.onProofBusy,
    required this.onPhotoChanged,
    required this.onProofChanged,
    required this.onUploadFailed,
  });

  final TextEditingController nameController;
  final TextEditingController phoneController;
  final TextEditingController passwordController;
  final GlobalKey<WhatsappCodeFieldState> codeKey;
  final bool codeVerified;
  final ValueChanged<bool> onCodeVerifiedChanged;
  final bool obscurePassword;
  final VoidCallback onTogglePassword;
  final VoidCallback onPhoneChanged;
  final VoidCallback onSubmit;
  final bool isLoading;
  final String profession;
  final ValueChanged<String> onProfessionChanged;
  final TextEditingController specialtyController;
  final TextEditingController bioController;
  final TextEditingController hoursController;
  final TextEditingController shopNameController;
  final String city;
  final ValueChanged<String> onCityChanged;
  final AdminUploads uploads;
  final String? photoUrl;
  final String? proofUrl;
  final String? uploadFailure;
  final bool uploadingFiles;
  final ValueChanged<bool> onPhotoBusy;
  final ValueChanged<bool> onProofBusy;
  final ValueChanged<String?> onPhotoChanged;
  final ValueChanged<String?> onProofChanged;
  final ValueChanged<String> onUploadFailed;

  bool get _professional => profession.isNotEmpty;

  InputDecoration _pdeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.cairo(
      color: AppColors.textHint,
      fontWeight: FontWeight.w600,
      fontSize: 12.5,
    ),
    counterText: '',
    filled: true,
    fillColor: authFieldFill,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: authFieldBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
  );

  @override
  Widget build(BuildContext context) {
    return AuthCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthCardHeading(
            icon: Icons.person_add_alt_1_rounded,
            title: 'إنشاء حساب جديد',
            subtitle: 'انضم إلى أطباء ذي قار الآن',
          ),
          const SizedBox(height: 14),
          const AuthFieldLabel('الاسم'),
          AuthNameField(
            controller: nameController,
            hint: 'الاسم الكامل كما في الإثبات',
            validator: (v) => AuthFields.nameError(v ?? ''),
          ),
          const SizedBox(height: 12),
          const AuthFieldLabel('رقم الهاتف'),
          AuthPhoneField(
            controller: phoneController,
            onChanged: onPhoneChanged,
            requireMobilePrefix: true,
          ),
          const SizedBox(height: 12),
          const AuthFieldLabel('كلمة المرور'),
          AuthPasswordField(
            controller: passwordController,
            obscure: obscurePassword,
            onToggle: onTogglePassword,
            validator: (v) => AuthFields.passwordError(v ?? ''),
          ),
          const SizedBox(height: 14),
          const AuthFieldLabel('نوع الحساب'),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: AuthProfessionChip(
                  label: 'زبون',
                  icon: Icons.apartment_rounded,
                  selected: profession.isEmpty,
                  onTap: () => onProfessionChanged(''),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: AuthProfessionChip(
                  label: 'طبيب',
                  icon: Icons.medical_services_rounded,
                  selected: profession == 'doctor',
                  onTap: () => onProfessionChanged('doctor'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: AuthProfessionChip(
                  label: 'ممرض',
                  icon: Icons.health_and_safety_rounded,
                  selected: profession == 'nurse',
                  onTap: () => onProfessionChanged('nurse'),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: AuthProfessionChip(
                  label: 'صيدلاني',
                  icon: Icons.medication_rounded,
                  selected: profession == 'pharmacist',
                  onTap: () => onProfessionChanged('pharmacist'),
                ),
              ),
            ],
          ),
          if (_professional) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primaryLight.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.verified_user_rounded,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'بيانات مزاولة المهنة — تُراجعها الإدارة قبل الظهور',
                          style: GoogleFonts.cairo(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'الصورة الشخصية (إجبارية)',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  AdminImageUploader(
                    folder: 'applications',
                    height: 110,
                    uploads: uploads,
                    initialUrl: photoUrl,
                    icon: Icons.person_rounded,
                    placeholder: 'اختر صورة شخصية واضحة',
                    onBusyChanged: onPhotoBusy,
                    onChanged: onPhotoChanged,
                    onFailed: onUploadFailed,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'مرفق الإثبات (إجباري) — هوية/شهادة/إجازة مزاولة',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  AdminImageUploader(
                    folder: 'applications',
                    height: 110,
                    uploads: uploads,
                    initialUrl: proofUrl,
                    icon: Icons.badge_rounded,
                    uploadedLabel: 'مرفوعة',
                    placeholder: 'ارفع صورة الإثبات',
                    onBusyChanged: onProofBusy,
                    onChanged: onProofChanged,
                    onFailed: onUploadFailed,
                  ),
                  if (uploadFailure != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '$uploadFailure\nأعد الرفع أو امسح الملف قبل المتابعة.',
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (profession == 'doctor') ...[
                    Text(
                      'التخصص (إجباري)',
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    TextFormField(
                      controller: specialtyController,
                      textAlign: TextAlign.right,
                      maxLength: 60,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                      decoration: _pdeco('مثال: الطب الباطني / جراحة العظام'),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'اكتب تخصصك'
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'نبذة عن الاختصاص (إجبارية)',
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    TextFormField(
                      controller: bioController,
                      textAlign: TextAlign.right,
                      maxLength: 800,
                      minLines: 3,
                      maxLines: 4,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: AppColors.textPrimary,
                      ),
                      decoration: _pdeco(
                        'سنوات الخبرة، الشهادات، مجالات العمل',
                      ),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'اكتب نبذة عن اختصاصك'
                          : null,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: CityStore.cities.contains(city)
                          ? city
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
                        if (v != null) onCityChanged(v);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (profession == 'pharmacist') ...[
                    Text(
                      'اسم الصيدلية (إجباري)',
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    TextFormField(
                      controller: shopNameController,
                      textAlign: TextAlign.right,
                      maxLength: 60,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                      decoration: _pdeco('الاسم كما سيظهر في التطبيق'),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'اكتب اسم الصيدلية'
                          : null,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    'أوقات العمل (إجبارية)',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  TextFormField(
                    controller: hoursController,
                    textAlign: TextAlign.right,
                    maxLength: 200,
                    minLines: 2,
                    maxLines: 3,
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: AppColors.textPrimary,
                    ),
                    decoration: _pdeco('أيام وساعات العمل'),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'اكتب أوقات العمل' : null,
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () async {
                        final picked = await showWorkingHoursPicker(
                          context,
                          initialText: hoursController.text,
                          title: 'أيام وساعات العمل',
                        );
                        if (picked == null) return;
                        hoursController.text = picked.text;
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
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          const AuthNoticeBanner(
            text:
                'بيانات مزاولة المهنة — تراجعها الإدارة قبل الظهور\n'
                '(الصورة الشخصية إجبارية)',
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                codeVerified
                    ? Icons.verified_rounded
                    : Icons.mark_email_unread_rounded,
                color: codeVerified ? AppColors.success : AppColors.textHint,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                'تأكيد الرقم بكود واتساب',
                style: GoogleFonts.cairo(
                  color: codeVerified ? AppColors.success : AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'لا يُنشأ الحساب قبل تأكيد الرمز — يحميك من الحسابات الوهمية',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          WhatsappCodeField(
            key: codeKey,
            phone: phoneController.text,
            enabled: !isLoading,
            onVerifiedChanged: onCodeVerifiedChanged,
          ),
          const SizedBox(height: 16),
          AuthSubmitButton(
            label: uploadingFiles
                ? 'انتظر اكتمال رفع المرفقات'
                : 'إنشاء الحساب',
            busy: isLoading,
            onPressed: (isLoading || uploadingFiles) ? null : onSubmit,
          ),
        ],
      ),
    );
  }
}
