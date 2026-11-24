import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/auth_fields.dart';
import '../core/utils/password_reset.dart';
import '../services/auth_service.dart';
import '../services/notification_center.dart';
import '../services/push_service.dart';
import '../services/supabase_service.dart';
import '../services/system_notification.dart';
import '../widgets/auth_shell.dart';
import '../widgets/whatsapp_code_field.dart';

import 'register_screen.dart';
import 'whatsapp_login_screen.dart';

/// شاشة تسجيل الدخول.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    this.onLoginSuccess,
    this.showBackButton = false,
  });

  final VoidCallback? onLoginSuccess;
  final bool showBackButton;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController(text: '');
  // ★ كان `text: '123456'` — كلمة مرور مكتوبة في الكود. أي أن أي نسخة
  //   من التطبيق كانت تعرضها جاهزة في الحقل. صارت الحقل فارغاً.
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPhone();
  }

  /// استرجاع آخر رقم هاتف دخل به المستخدم حتى لا يكتبه من جديد.
  ///
  /// ★ كلمة المرور **لم تعد** تُحفظ على الجهاز. كانت تُخزَّن في
  ///   SharedPreferences تحت `last_pass_<phone>` بنص صريح — أي أن أي
  ///   تطبيق يقرأ ذاكرة الجهاز (أو نسخة احتياطية منها) يحصل على
  ///   كلمة مرور الزبون كاملة. لا نحفظها إطلاقاً الآن.
  Future<void> _loadSavedPhone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('last_phone');
      if (saved != null && saved.isNotEmpty) {
        _phoneController.text = saved;
      }
    } catch (_) {}

    // تنظيف أي نسخ قديمة محفوظة من إصدارات سابقة (لا نستطيع المسح
    // إلا بعد معرفة الرقم، فنمسح عند أول قراءة بنسخة جديدة).
    try {
      final prefs = await SharedPreferences.getInstance();
      final phone = _phoneController.text.trim();
      if (phone.isNotEmpty) await prefs.remove('last_pass_$phone');
    } catch (_) {}
  }

  Future<void> _savePhone(String phone) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_phone', phone);
    } catch (_) {}
  }

  /// ★ لم تعد هناك دالة حفظ كلمة المرور — ولا تُحفظ في أي مكان.
  ///   النسيان أأمن بكثير من الحفظ المكشوف على القرص.
  void _purgeStoredPassword(String phone) {
    try {
      SharedPreferences.getInstance().then(
        (prefs) => prefs.remove('last_pass_$phone'),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isLoading = true);
    if (!mounted) return;

    final phone = _phoneController.text.trim();
    final password = _passwordController.text;

    String? name;
    var isAdmin = false;
    var isDriver = false;
    var isShopOwner = false;

    // ★★ باب خلفي كان هنا:
    //   if (phone == AuthService.adminPhone && password == AuthService.adminPassword)
    //      { isAdmin = true; }
    // كان تحققاً **محلياً تماماً**: لا يمرّ على القاعدة ولا على RLS ولا
    // حدّ محاولات، ورقم الأدمن وكلمة مروره مثبتان في الكود — أي أن من
    // يفكّ الـAPK يصير أدمن. وكلمة المرور الآن تُتحقَّق في القاعدة على
    // bcrypt عبر `verify_login`، وهي ترجع الدور من الخادم لا من مقارنة
    // محلية، فلا يمكن انتحال أي صلاحية من داخل التطبيق.
    final result = await SupabaseService.instance.verifyLogin(phone, password);
    if (!mounted) return;

    if (result == null || result['ok'] != true) {
      setState(() => _isLoading = false);
      final serverMsg = (result?['message'] ?? 'تعذّر الاتصال بالخادم')
          .toString();
      _showLoginFailure(phone, serverMsg);
      return;
    }

    isAdmin = result['is_admin'] == true;
    isDriver = result['is_driver'] == true;
    // ★ `verify_login` يُرجع `is_shop_owner` أصلاً، ولم يكن يُقرأ.
    //   النتيجة: صاحب الصيدلية يبدأ بـ`false` فيدخل على الواجهة العامة
    //   ثم يُقفز إلى واجهته بعد الاستطلاع — وظهر ذلك كتأخير دخول.
    isShopOwner = result['is_shop_owner'] == true;
    name = result['name']?.toString();

    await AuthService.instance.login(
      phone: phone,
      name: name,
      isAdmin: isAdmin,
      isDriver: isDriver,
      isShopOwner: isShopOwner,
      // التوكن الموقّع من verify_login (بعد SQL_HARDEN_STAGE2).
      //   بدونه كل طلبات الطلبات/الإشعارات ترتدّ 403 بعد المرحلة 2.
      sessionToken: result['session_token']?.toString(),
    );
    _savePhone(phone);
    // ★ كلمة المرور تُمسح فوراً بعد نجاح التحقق: لا تبقى في الحقل
    //   ولا في ذاكرة الجهاز. (نستدعيها بعد AuthService لأن الدخول
    //   قد يفشل ويبقى المستخدم في الشاشة.)
    _passwordController.clear();
    _purgeStoredPassword(phone);

    // صلاحيات الإشعارات + حفظ توكن الجهاز: بعد كل دخول.
    // (يضمن أن كل حساب — جديداً كان أو قديماً — له إشعارات وشعار ورمز جهاز.)
    if (!isAdmin) {
      unawaited(SupabaseService.instance.grantNotificationAccess(phone));
    }
    unawaited(PushService.instance.ensureTokenSaved());
    NotificationCenter.instance.onAccountChanged();

    // إذن إشعارات النظام (أندرويد 13+): بدونه لا صوت خارج التطبيق إطلاقاً.
    if (!SystemNotification.instance.granted) {
      unawaited(SystemNotification.instance.init());
    }
    if (!mounted) return;

    // ★★ العودة إلى المسار الأول (home) لا دفع شاشة هنا.
    //   `home` هو `app.dart` وهو **المرجع الوحيد** الذي يختار
    //   الشاشة حسب الدور. لو دفعنا MainShell هنا لبقيت فوق home
    //   دائماً، فلا أثر لتبديل الدور بعد الدخول: الأدمن يحوّل
    //   الحساب إلى صاحب صيدلية، والدورية تُحدّث `home` تحت هذا
    //   المسار المدفوع ولا يظهر شيء للمستخدم.
    if (widget.onLoginSuccess != null) {
      Navigator.of(context).pop();
      widget.onLoginSuccess!();
    } else {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _continueAsGuest() {
    if (widget.onLoginSuccess != null) {
      Navigator.of(context).pop();
      widget.onLoginSuccess!();
    } else {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _goToRegister() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const RegisterScreen()));
  }

  void _goToWhatsappLogin() {
    // ★★ لا نمرّر `widget.onLoginSuccess` كما هو: شاشة واتساب تُغلق
    //   **نفسها فقط** ثم تستدعي الردّ، فتبقى شاشة الدخول هذه فوق
    //   كل شيء فيبدو أن الدخول الناجح أعاد فتح واجهة الدخول من
    //   جديد. الردّ الملفوف هنا يغلق شاشة الدخول أولاً (بالمسار
    //   نفسه الذي تسلكه نجاح الدخول بكلمة المرور أعلاه) ثم يُكمل
    //   استمرار المسار الأصلي (فتح السلة / التبديل للتبويب).
    final parentSuccess = widget.onLoginSuccess;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WhatsappLoginScreen(
          onLoginSuccess: parentSuccess == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  parentSuccess();
                },
        ),
      ),
    );
  }

  /// ★ بعد فشل الدخول نسأل القاعدة: هل الرقم مسجّل أصلاً؟
  ///
  /// الرسالة الواحدة التي تعيدها `verify_login` صحيحة أمنياً لكنها
  /// على الهاتف بلا فائدة: من لا يملك حساباً يقرأ «بيانات غير
  /// صحيحة» فيظنّ أن كلمة سره خطأ، فيعيد إدخال كلمات إلى ما لا
  /// ينتهي — والسبب الحقيقي أنه لا حساب له أصلاً.
  ///
  /// التمييز هنا بعد **الفشل** فقط: فمن يجرّب أرقاماً لا يربح من
  /// ذلك شيئاً، والمستخدم وحده هو من يحتاج أن يعرف طريقه التالي.
  Future<void> _showLoginFailure(String phone, String serverMsg) async {
    final status = await SupabaseService.instance.accountStatus(phone);
    if (!mounted) return;

    var msg = serverMsg;
    String? actionLabel;
    VoidCallback? onAction;

    if (status == null) {
      // القاعدة لم تجب (الملف غير مُنفَّذ أو انقطاع) ⇒ لا نخترع سبباً.
      msg = serverMsg;
    } else if (status['exists'] != true) {
      msg = 'لا يوجد حساب بهذا الرقم — أنشئ حساباً جديداً';
      actionLabel = 'إنشاء حساب';
      onAction = () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const RegisterScreen()));
      };
    } else if (status['has_password'] != true) {
      msg = 'هذا الحساب يُدخَل بكود واتساب — لا كلمة مرور له';
    } else if (status['is_active'] == false) {
      msg = 'هذا الحساب موقوف — راجع الإدارة';
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 5),
          action: onAction == null
              ? null
              : SnackBarAction(
                  label: actionLabel!,
                  textColor: Colors.white,
                  onPressed: onAction,
                ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScreenScaffold(
      card: Form(
        key: _formKey,
        child: _LoginCard(
          phoneController: _phoneController,
          passwordController: _passwordController,
          obscurePassword: _obscurePassword,
          onTogglePassword: () =>
              setState(() => _obscurePassword = !_obscurePassword),
          onSubmit: _login,
          onGuest: _continueAsGuest,
          onWhatsapp: _goToWhatsappLogin,
          isLoading: _isLoading,
        ),
      ),
      footer: AuthFooterWave(
        icon: Icons.person_add_alt_rounded,
        label: 'ليس لديك حساب؟ أنشئ حساباً جديداً',
        onPressed: _goToRegister,
      ),
    );
  }
}

class _LoginCard extends StatefulWidget {
  const _LoginCard({
    required this.phoneController,
    required this.passwordController,
    required this.obscurePassword,
    required this.onTogglePassword,
    required this.onSubmit,
    required this.onGuest,
    required this.onWhatsapp,
    required this.isLoading,
  });

  final TextEditingController phoneController;
  final TextEditingController passwordController;
  final bool obscurePassword;
  final VoidCallback onTogglePassword;
  final VoidCallback onSubmit;
  final VoidCallback onGuest;
  final VoidCallback onWhatsapp;
  final bool isLoading;

  @override
  State<_LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends State<_LoginCard> {
  // حالة شريط «استعادة كلمة المرور» — تعيش هنا لأن الشريط يحتاج
  //setState الخاص فيه بدون إعادة بناء شاشة الدخول كلها.
  final _resetPhoneCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _resetCodeKey = GlobalKey<WhatsappCodeFieldState>();
  StateSetter? _resetSheet;
  bool _resetCodeVerified = false;
  bool _resetBusy = false;

  @override
  void dispose() {
    _resetPhoneCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phoneController = widget.phoneController;
    final passwordController = widget.passwordController;
    final obscurePassword = widget.obscurePassword;
    final isLoading = widget.isLoading;
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
            'تسجيل الدخول',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'أهلاً بعودتك، سجل دخولك لمتابعة خدماتك',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          // ★ فاصل أيقونة نبضة القلب تحت العنوان — كما في التصميم.
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
          // ★ الحقول بتسمية فوقها ورماديّ مملوء داخل حدٍّ دائري.
          Text(
            'رقم الهاتف',
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          TextFormField(
            controller: phoneController,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            decoration: InputDecoration(
              hintText: '07XXXXXXXXX',
              counterText: '',
              filled: true,
              fillColor: AppColors.background,
              prefixIcon: const Icon(
                Icons.phone_rounded,
                color: AppColors.primary,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                  color: AppColors.primary,
                  width: 1.6,
                ),
              ),
            ),
            validator: (v) => AuthFields.phoneError(v ?? ''),
          ),
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
          TextFormField(
            controller: passwordController,
            obscureText: obscurePassword,
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.background,
              prefixIcon: const Icon(
                Icons.lock_rounded,
                color: AppColors.primary,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  color: AppColors.textHint,
                ),
                onPressed: widget.onTogglePassword,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(
                  color: AppColors.primary,
                  width: 1.6,
                ),
              ),
            ),
            // ★ إجبارية بلا فراغ وحده: كان `v.isEmpty` وحده يقبل
            //   «مسافة» فيُطلق رحلة شبكة كاملة بلا كلمة حقيقية.
            //   لا حدّ طول هنا: كلمة حسابٍ قديم قصيرة يجب أن يدخل بها،
            //   والصحة قرار القاعدة لا القرار المحلي.
            validator: (v) => AuthFields.loginPasswordError(v ?? ''),
          ),
          const SizedBox(height: 14),
          // ★ زر الدخول كرويّ تماماً مع سهم إلى اليمين — كما في التصميم.
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: isLoading ? null : widget.onSubmit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: const StadiumBorder(),
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'تسجيل الدخول',
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
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(child: Divider(color: AppColors.divider)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'أو',
                  style: GoogleFonts.cairo(
                    color: AppColors.textHint,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Expanded(child: Divider(color: AppColors.divider)),
            ],
          ),
          const SizedBox(height: 12),
          // ★ زر واتساب: أبيض بحدٍّ أخضر ونص أخضر — كما في التصميم.
          SizedBox(
            height: 50,
            child: OutlinedButton.icon(
              onPressed: widget.onWhatsapp,
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1DA851),
                side: const BorderSide(color: Color(0xFF1DA851), width: 1.5),
                shape: const StadiumBorder(),
              ),
              icon: const Icon(
                Icons.chat_bubble_rounded,
                size: 20,
                color: Color(0xFF1DA851),
              ),
              label: Text(
                'الدخول بكود واتساب',
                style: GoogleFonts.cairo(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: widget.onGuest,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(
              Icons.arrow_circle_left_rounded,
              size: 20,
              color: AppColors.primary,
            ),
            label: Text(
              'الاستمرار كضيف',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () => _showFluidSnack(context),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: AppColors.textHint,
                ),
                const SizedBox(width: 5),
                Text(
                  'نسيت كلمة المرور؟',
                  style: GoogleFonts.cairo(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.textHint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showFluidSnack(BuildContext context) {
    _showResetPasswordSheet(context);
  }

  /// استعادة كلمة المرور: يثبت ملكية الرقم بكود واتساب، ثم تُكتب كلمة
  /// مرور جديدة مكان القديمة في جدول `users` من داخل القاعدة.
  void _showResetPasswordSheet(BuildContext context) {
    // تنظيف أي محاولة سابقة قبل فتح الشريط من جديد.
    _resetPhoneCtrl.clear();
    _newPasswordCtrl.clear();
    _confirmCtrl.clear();
    setState(() {
      _resetCodeVerified = false;
      _resetBusy = false;
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          _resetSheet = setSheet;
          final resetPhoneCtrl = _resetPhoneCtrl;
          final newPasswordCtrl = _newPasswordCtrl;
          final confirmCtrl = _confirmCtrl;
          final codeKey = _resetCodeKey;
          final codeVerified = _resetCodeVerified;
          final busy = _resetBusy;

          return SingleChildScrollView(
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
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'استعادة كلمة المرور',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'نرسل كود على واتساب لتأكيد رقمك، ثم تضع كلمة مرور جديدة.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: resetPhoneCtrl,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                  onChanged: (_) => setSheet(() {}),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                  decoration: InputDecoration(
                    labelText: 'رقم الهاتف',
                    counterText: '',
                    prefixIcon: const Icon(Icons.phone_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                WhatsappCodeField(
                  key: codeKey,
                  phone: resetPhoneCtrl.text.trim(),
                  enabled: !busy,
                  onVerifiedChanged: (v) =>
                      setSheet(() => _resetCodeVerified = v),
                ),
                if (codeVerified) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: newPasswordCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'كلمة المرور الجديدة',
                      prefixIcon: const Icon(Icons.lock_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'تأكيد كلمة المرور',
                      prefixIcon: const Icon(Icons.lock_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: busy ? null : () => _handleReset(ctx),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          codeVerified
                              ? 'حفظ كلمة المرور الجديدة'
                              : 'تأكيد الكود',
                          style: GoogleFonts.cairo(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// خطوتان منفصلتان: تأكيد الكود، ثم استبدال كلمة المرور القديمة.
  /// كان الكود القديم يحبس الحفظ جوّا `if (!codeVerified)` فما ينحفظ شي.
  Future<void> _handleReset(BuildContext sheetContext) async {
    final resetPhoneCtrl = _resetPhoneCtrl;
    final newPasswordCtrl = _newPasswordCtrl;
    final confirmCtrl = _confirmCtrl;
    final codeKey = _resetCodeKey;
    final sheet = _resetSheet;
    if (sheet == null) return;

    void setSheet(VoidCallback fn) {
      // ★ الورقة قد تُغلق أثناء الانتظار على الشبكة —
      //   نداء setState على builder مُلقى يرمي ويقتل الدالة. نبتلعه.
      try {
        sheet(() => fn());
      } catch (_) {}
    }

    void toast(String m, {bool danger = false}) {
      // ★ نفس حماية بقية الشاشات: عنصر مُهمَل يرمي من
      //   ScaffoldMessenger.of، والرمي يقطع تدفق إعادة التعيين.
      if (!sheetContext.mounted) return;
      try {
        ScaffoldMessenger.of(sheetContext)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                m,
                style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: danger ? AppColors.danger : AppColors.primary,
            ),
          );
      } catch (_) {}
    }

    // ★ نفس حجة الرقم التي تستعملها شاشة الدخول: فارغ ⇒ «أدخل رقم
    //   الهاتف»، وناقص ⇒ «١١ رقماً». لم تعد رسالة واحدة تغطي الحالتين.
    final phone = AuthFields.digits(resetPhoneCtrl.text);
    final phoneProblem = AuthFields.phoneError(resetPhoneCtrl.text);
    if (phoneProblem != null) {
      toast(phoneProblem, danger: true);
      return;
    }

    // الخطوة الأولى: تأكيد ملكية الرقم بالكود.
    if (!_resetCodeVerified) {
      final ok = await codeKey.currentState?.verify() ?? false;
      if (!ok) return;
      setSheet(() => _resetCodeVerified = true);
      return;
    }

    // الخطوة الثانية: كتابة كلمة المرور الجديدة مكان القديمة.
    // ★ الحدود كلها هنا من `PasswordReset` — نفس ما تشترطه القاعدة، فلا
    //   يضيع انتظار الشبكة على طلب مرفوض سلفاً، وتُقال الحجة بالعربية.
    final problem = PasswordReset.validate(
      newPasswordCtrl.text,
      confirmCtrl.text,
      phone: phone,
    );
    if (problem != null) {
      toast(problem, danger: true);
      return;
    }

    // ★ التوكن هو من يرخّص الكتابة في القاعدة. بدونه ترفض الدالة، فحذف
    //   شرط `if (!_resetCodeVerified)` من الـAPK لا يفيد صاحبه بشيء.
    final resetToken = codeKey.currentState?.verifiedToken ?? '';
    if (resetToken.isEmpty) {
      setSheet(() => _resetBusy = false);
      toast('انتهت صلاحية التأكيد، أعد إرسال الكود', danger: true);
      return;
    }

    setSheet(() => _resetBusy = true);
    final res = await SupabaseService.instance.resetPassword(
      phone: phone,
      newPassword: newPasswordCtrl.text,
      resetToken: resetToken,
    );
    if (!sheetContext.mounted) return;
    setSheet(() => _resetBusy = false);

    if (res['ok'] == true) {
      toast(PasswordReset.successLine(res, phone: phone));
      Navigator.of(sheetContext).pop();
    } else {
      // ★ لم يعد «تعذّر الحفظ» وحدها: الرمز من القاعدة يحمل السبب،
      //   فيعرف الزبون هل الكود انتهى، أم الحساب غير مسجّل، أم الكلمة قصيرة.
      toast(PasswordReset.failureLine(res), danger: true);
    }
  }
}
