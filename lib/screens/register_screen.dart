import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/auth_fields.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../widgets/auth_shell.dart';
import '../widgets/whatsapp_code_field.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _codeKey = GlobalKey<WhatsappCodeFieldState>();
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _codeVerified = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
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

    setState(() => _isLoading = true);
    // ★ نجاح الإنشاء يخرج من الشاشة؛ finally لا يعيد الحالة بعده.
    var navigated = false;

    try {
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
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_phone', _phoneController.text.trim());
      } catch (_) {}
      if (!mounted) return;
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
        ),
      ),
      footer: AuthFooterWave(
        icon: Icons.login_rounded,
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

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.10),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'إنشاء حساب جديد',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'انضم إلى اطباء ذي قار الآن',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          // ★ فاصل أيقونة نبضة القلب تحت العنوان — كما في شاشة الدخول.
          Row(
            children: [
              const Expanded(child: Divider(color: AppColors.divider)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(
                  Icons.monitor_heart_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
              ),
              const Expanded(child: Divider(color: AppColors.divider)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'الاسم',
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          _NameField(controller: nameController),
          const SizedBox(height: 12),
          Text(
            'رقم الهاتف',
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          _PhoneField(controller: phoneController, onChanged: onPhoneChanged),
          const SizedBox(height: 12),
          Text(
            'كلمة المرور',
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          _PasswordField(
            controller: passwordController,
            obscure: obscurePassword,
            onToggle: onTogglePassword,
          ),
          const SizedBox(height: 14),
          const Divider(color: AppColors.divider),
          const SizedBox(height: 10),
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
          // ★ زر الإنشاء كرويّ تماماً — كما في شاشة الدخول.
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: isLoading ? null : onSubmit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: const StadiumBorder(),
              ),
              child: isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'إنشاء الحساب',
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.east_rounded, size: 20),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NameField extends StatelessWidget {
  const _NameField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      textAlign: TextAlign.right,
      style: GoogleFonts.cairo(
        fontWeight: FontWeight.w700,
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: 'اسم الصيدلية أو اسمك',
        hintStyle: GoogleFonts.cairo(
          color: AppColors.textHint,
          fontWeight: FontWeight.w600,
        ),
        prefixIcon: const Icon(
          Icons.storefront_rounded,
          color: AppColors.primary,
          size: 20,
        ),
        filled: true,
        fillColor: AppColors.background,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      validator: (value) => AuthFields.nameError(value ?? ''),
    );
  }
}

class _PhoneField extends StatelessWidget {
  const _PhoneField({required this.controller, this.onChanged});

  final TextEditingController controller;

  /// يُبلّغ الأب بكل تغيير حتى يُعاد بناء حقل الكود بالرقم الحالي.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      onChanged: (_) => onChanged?.call(),
      keyboardType: TextInputType.phone,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      maxLength: 11,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(11),
      ],
      style: GoogleFonts.cairo(
        fontWeight: FontWeight.w700,
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: '07x xxxx xxxx',
        hintStyle: GoogleFonts.cairo(
          color: AppColors.textHint,
          fontWeight: FontWeight.w600,
        ),
        prefixIcon: Container(
          width: 58,
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '+964',
              style: GoogleFonts.cairo(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ),
        suffixIcon: const Icon(
          Icons.phone_android_rounded,
          color: AppColors.textHint,
          size: 20,
        ),
        counterText: '',
        filled: true,
        fillColor: AppColors.background,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      // ★ إجباري بالكامل: أحد عشر رقماً تبدأ بـ07 — لا رقم ناقص ولا
      //   رقم أرضي يُدفع إلى الشبكة ثم يرتدّ. التسجيل وحده يشترط
      //   البادئة؛ الدخول لا يشترطها حتى لا يُقفل حساب قديم.
      validator: (value) =>
          AuthFields.phoneError(value ?? '', requireMobilePrefix: true),
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.obscure,
    required this.onToggle,
  });

  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      style: GoogleFonts.cairo(
        fontWeight: FontWeight.w700,
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: 'كلمة المرور',
        hintStyle: GoogleFonts.cairo(
          color: AppColors.textHint,
          fontWeight: FontWeight.w600,
        ),
        prefixIcon: const Icon(
          Icons.lock_outline_rounded,
          color: AppColors.primary,
          size: 20,
        ),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(
            obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            color: AppColors.textHint,
          ),
        ),
        filled: true,
        fillColor: AppColors.background,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      // ★ إجبارية وبحدّ الاستعادة نفسه (٦ محارف): كانت أربعة هنا
      //   وستة في «نسيت كلمة المرور»، فحساب بكلمة من أربعة يُقبل
      //   يوم الإنشاء ثم تُرفض نفس الكلمة يوم استعادته.
      validator: (value) => AuthFields.passwordError(value ?? ''),
    );
  }
}
