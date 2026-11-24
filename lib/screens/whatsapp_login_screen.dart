import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/notification_center.dart';
import '../services/push_service.dart';
import '../services/supabase_service.dart';
import '../services/system_notification.dart';
import '../core/utils/account_name.dart';
import '../core/utils/auth_fields.dart';
import '../widgets/auth_shell.dart';
import '../widgets/whatsapp_code_field.dart';

/// شاشة تسجيل الدخول بكود واتساب: يُرسل الكود، ثم يُكتب أو يُلصق ويُتحقق منه.
class WhatsappLoginScreen extends StatefulWidget {
  const WhatsappLoginScreen({super.key, this.onLoginSuccess});

  final VoidCallback? onLoginSuccess;

  @override
  State<WhatsappLoginScreen> createState() => _WhatsappLoginScreenState();
}

class _WhatsappLoginScreenState extends State<WhatsappLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  // ★ حقل اسم الحساب الجديد: حقل في الحالة لا متغيّر محلي، لأن إغلاق
  //   الحوار يبدأ حركة اختفاء تستمر بعده — إتلاف المتحكم فوراً يجعل
  //   تلك الحركة تقرأ متحكماً مُتلفاً فترمي.
  final _newNameController = TextEditingController();
  final _codeKey = GlobalKey<WhatsappCodeFieldState>();
  bool _isLoggingIn = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _newNameController.dispose();
    super.dispose();
  }

  /// استرجاع آخر رقم دخل به المستخدم حتى لا يكتبه من جديد.
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('last_phone');
      if (saved == null || saved.isEmpty) return;
      if (!mounted) return;
      setState(() => _phoneController.text = saved);
    } catch (_) {}
  }

  void _toast(String msg, {bool danger = false}) {
    if (!mounted) return;
    // ★ نفس حماية حقل الكود: عنصر مُهمَل يمرّ من فحص mounted ثم يرمي
    //   من ScaffoldMessenger.of — والرمي هنا يقتل _login ويترك زر
    //   الدخول دائرةً بلا نهاية.
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

  /// ★★ الاسم الإجباري للحساب الجديد — مرة واحدة عند الإنشاء.
  ///
  ///   أول كود صحيح لرقم غير موجود يُنشئ صفّه في القاعدة، و`login_wa_phone`
  ///   يكتب فيه اللقب «حساب» لأن توكن واتساب لا يحمل اسماً. اللقب ليس
  ///   اسماً: يظهر في الطلبات والإشعارات ولوحة الأدمن كأن صاحبه مجهول.
  ///   الحساب القديم لا يُسأل مهما كان اسمه — السؤال هنا للمولود الآن.
  ///
  ///   لا إلغاء ولا «تخطّي» ولا نقر خارج الحوار: الاسم شرط إتمام الدخول.
  ///   والفشل في الحفظ يُبقي الحوار مفتوحاً مع سبب ظاهر، لا يُدخل المستخدم
  ///   باسم لم يُخزَّن.
  ///
  ///   يعيد الاسم المحفوظ، أو null إن أُغلق الحوار بغير حفظ.
  Future<String?> _askNewAccountName(String phone) async {
    final formKey = GlobalKey<FormState>();
    var saving = false;
    String? saveError;
    _newNameController.clear();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setDlgState) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              'اكتب اسمك',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'حسابك جديد. اكتب اسمك الحقيقي، فهو الذي يظهر في طلباتك وإشعاراتك.',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _newNameController,
                    autofocus: true,
                    textAlign: TextAlign.right,
                    textInputAction: TextInputAction.done,
                    maxLength: AuthFields.nameMaxLength,
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'اسمك أو اسم صيدليتك',
                      hintStyle: GoogleFonts.cairo(
                        color: AppColors.textHint,
                        fontWeight: FontWeight.w600,
                      ),
                      counterText: '',
                      prefixIcon: const Icon(
                        Icons.badge_rounded,
                        color: AppColors.textHint,
                        size: 20,
                      ),
                      filled: true,
                      fillColor: AppColors.surfaceTint.withValues(alpha: 0.6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: AppColors.primary,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                    ),
                    validator: (v) => AuthFields.nameError(v ?? ''),
                  ),
                  if (saveError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      saveError!,
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        final name = _newNameController.text.trim();
                        setDlgState(() {
                          saving = true;
                          saveError = null;
                        });
                        // ★ نفس مسار الصورة في صفحة حسابي: PATCH على صفّ
                        //   المستخدم بتوكن الجلسة الذي ضبطناه قبل الحوار.
                        final saved = await SupabaseService.instance
                            .updateUser(phone, {'name': name});
                        if (!saved) {
                          if (ctx.mounted) {
                            setDlgState(() {
                              saving = false;
                              saveError =
                                  'تعذّر حفظ الاسم — تحقق من الاتصال وأعد المحاولة';
                            });
                          }
                          return;
                        }
                        // ★ الحفظ في القاعدة فقط: الاسم يعود من هنا إلى
                        //   AuthService.login فيُكتب محلياً مع بقية
                        //   بيانات الجلسة كتابة واحدة.
                        if (ctx.mounted) Navigator.of(ctx).pop(name);
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        'حفظ ومتابعة',
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w900,
                          color: AppColors.primary,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _login() async {
    if (_isLoggingIn) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isLoggingIn = true);

    final phone = _phoneController.text.trim();
    // ★ نجاح الدخول يخرج من الشاشة؛ بعده ممنوع أي setState — علِمنا
    //   بهذا العلم كي لا يعيده finally على عنصر في طريقه للإلقاء.
    var navigated = false;

    try {
      // ★★ بوابة الحظر: مَن حذف حسابه بنفسه لا يرجع بنفس الرقم قبل
      //   انقضاء المدة. والفحص **قبل** التحقق من الكود لا بعده: كود
      //   واتساب يُستهلك في الخادم عند أول تحقق ناجح، فلا يُعقل أن
      //   يحرقه محاولة مرفوضة سلفاً.
      //  خطأ الشبكة أو ملف SQL لم يُشغَّل ⇒ `blocked=false` ⇒ الدخول
      //   يمرّ كالمعتاد؛ الباب لا يُقفل على الناس لأن الخادم لم يرد.
      final block = await SupabaseService.instance.accountDeletionState(phone);
      if (block['blocked'] == true || block['blocked']?.toString() == 'true') {
        final msg = (block['message'] ?? '').toString().trim();
        _toast(
          msg.isEmpty
              ? 'تم حذف هذا الحساب نهائياً — التسجيل بحساب جديد متاح بعد ٣ ساعات'
              : msg,
          danger: true,
        );
        return;
      }

      // يتحقق من الكود أولاً. إن كان صحيحاً مسبقاً يفوّت الطلب ويرجع فوراً.
      // ★ كود مؤكَّد مسبقاً ⇒ لا إعادة تحقق: إعادة التحقق تستهلك الكود
      //   على السيرفر (استخدام واحد) فيفشل الدخول رغم صحّته.
      final codeState = _codeKey.currentState;
      final ok = codeState == null
          ? false
          : (codeState.isVerified && codeState.verifiedToken != null
                ? true
                : await codeState.verify());
      if (!ok) return;

      // ★★ كان findUser() وحده: استعلام مباشر لجدول users بـanon، ولا
      //   يُعيد توكناً. بعد تشديد RLS يُمنع ذلك قبل الدخول، وحتى بعده
      //   لا تُقرأ إلا أعمدة صفّ واحد.
      //
      //   loginWithToken() تعيد صفّ المستخدم + **توكن جلسة قاعدة البيانات**
      //   (phone + الأدوار، موقّع HMAC). بدونه لا تستطيع سياسات RLS معرفة
      //   من المتصل، فيسقط كل طلب محمي. توكن خادم واتساب لا يصلح هنا:
      //   هو {phone, exp} بلا أدوار.
      //  ★ التوكن الذي أعاده خادم الرموز (تحقّق من الرمز الرقمي)
      //    يُسلَّم لطبقة الخدمة، وهي تتحقق من توقيعه في القاعدة
      //    وتفحص الحساب في Supabase قبل إصدار الجلسة.
      final auth = await SupabaseService.instance.loginWithToken(
        phone,
        token: _codeKey.currentState?.verifiedToken,
      );
      final user = auth.user;
      if (!mounted) return;
      if (user == null) {
        //  أظهر السبب الحقيقي الذي أعادته القاعدة بدل جملة عامة
        //  تُخفي السبب وتجعل كل عطل يبدو كأن الميزة معطّلة عمداً.
        final why = SupabaseService.instance.lastDeleteError.trim();
        _toast(
          why.isEmpty ? 'تعذّر تسجيل الدخول - حاول مرة أخرى' : why,
          danger: true,
        );
        return;
      }
      if (user['is_active'] == false) {
        _toast('هذا الحساب موقوف، راجع الإدارة', danger: true);
        return;
      }
      if (auth.sessionToken == null) {
        _toast('تعذّر فتح جلسة آمنة، أعد المحاولة', danger: true);
        return;
      }

      final isAdmin = user['is_admin'] == true;
      final isDriver = user['is_driver'] == true;
      // ★ نفس الغياب في شاشة الدخول العادية: الدور يصل ولا يُقرأ.
      final isShopOwner = user['is_shop_owner'] == true;

      // ★★ الاسم الحقيقي قبل إعلان الدخول.
      //   الحساب المولود الآن اسمه في القاعدة «حساب» — توكن واتساب لا
      //   يحمل اسماً — واللقب ليس اسماً: يظهر في الطلبات والإشعارات
      //   ولوحة الأدمن كأن صاحبه مجهول. يُسأل مرة واحدة عند الإنشاء،
      //   والحساب القديم لا يُسأل مهما كان اسمه.
      //
      //   يُحفظ قبل AuthService.login لسببين: توكن الجلسة صار بيدينا من
      //   login_wa_phone فيكفي ضبطه للكتابة على صفّنا، وlogin يطلق
      //   refreshFromServer بلا انتظار — فلو سبقت قراءتها حفظَنا لأعادت
      //   الاسم إلى «حساب» فوق ما كتبه المستخدم للتو. وهو قبل الإشعارات
      //   أيضاً: grantNotificationAccess يختم عنوان الإشعار باسم الحساب.
      var accountName = user['name']?.toString();
      final prefs = await SharedPreferences.getInstance();
      try {
        await prefs.setString('last_phone', phone);
      } catch (_) {}
      final pendingName = prefs.getString('pending_name_phone') == phone;
      if (AccountName.isGeneric(accountName)) {
        if (auth.created || pendingName) {
          // ★ علم محلي يسدّ الثغرة الوحيدة: من أُغلق التطبيق وهو داخل
          //   الحوار يعود فيُسأل من جديد، لأن created تصير false في
          //   الدخول التالي والحساب ما زال بلا اسم.
          await prefs.setString('pending_name_phone', phone);
          SupabaseService.instance.setSessionToken(auth.sessionToken);
          if (!mounted) return;
          final saved = await _askNewAccountName(phone);
          if (!mounted) return;
          if (saved != null) {
            accountName = saved;
            await prefs.remove('pending_name_phone');
          }
        }
      } else if (pendingName) {
        await prefs.remove('pending_name_phone');
      }

      await AuthService.instance.login(
        phone: phone,
        name: accountName,
        isAdmin: isAdmin,
        isDriver: isDriver,
        isShopOwner: isShopOwner,
        sessionToken: auth.sessionToken,
      );

      if (!isAdmin) {
        unawaited(SupabaseService.instance.grantNotificationAccess(phone));
      }
      unawaited(PushService.instance.ensureTokenSaved());
      NotificationCenter.instance.onAccountChanged();

      if (!SystemNotification.instance.granted) {
        unawaited(SystemNotification.instance.init());
      }

      // ★ أول دخول بكود واتساب يُنشئ الحساب في القاعدة (إثبات ملكية
      //   الرقم = إنشاء حساب). نُعلن ذلك قبل الانتقال: الانتقال
      //   الفوري يخفي أن الحساب وُلد الآن، فيظنّ المستخدم أنه كان
      //   موجوداً أو أنه دخل حساب شخص آخر.
      _toast(auth.created ? 'تم إنشاء حسابك — أهلاً بك' : 'تم تسجيل الدخول');
      if (!mounted) return;

      // ★★ العودة إلى `home` (المرجع الوحيد لاختيار الشاشة حسب الدور).
      navigated = true;
      if (widget.onLoginSuccess != null) {
        Navigator.of(context).pop();
        widget.onLoginSuccess!();
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      // ★ أي استثناء أثناء الطيران (تعذّر اتصال، عنصر مُهمَل عند قلب
      //   النافذة…) لا يجوز أن يترك زر الدخول دائراً بلا نهاية.
      if (mounted && !navigated) {
        _toast('حدث خطأ غير متوقع، حاول مجدداً', danger: true);
      }
    } finally {
      if (mounted && !navigated && _isLoggingIn) {
        setState(() => _isLoggingIn = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final codeBusy = _codeKey.currentState?.isBusy ?? false;
    final busy = _isLoggingIn || codeBusy;
    return AuthScreenScaffold(
      card: Form(
        key: _formKey,
        child: Container(
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
                'الدخول بكود واتساب',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  color: AppColors.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'نرسل كود على واتساب — انسخه والصقه هنا',
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
              // ★ الحقول بتسمية فوقها ورماديّ مملوء داخل حدٍّ دائري —
              //   نفس حقول شاشة الدخول بكلمة المرور.
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
                controller: _phoneController,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                enabled: !busy,
                onChanged: (_) => setState(() {}),
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
              const SizedBox(height: 14),
              WhatsappCodeField(
                key: _codeKey,
                phone: _phoneController.text,
                enabled: !_isLoggingIn,
              ),
              const SizedBox(height: 16),
              // ★ زر الدخول كرويّ تماماً — كما في التصميم.
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: busy ? null : _login,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: const StadiumBorder(),
                  ),
                  child: _isLoggingIn
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
                              'دخول بكود واتساب',
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
        ),
      ),
      footer: AuthFooterWave(
        icon: Icons.lock_rounded,
        label: 'الدخول بكلمة المرور',
        onPressed: () => Navigator.of(context).pop(),
      ),
    );
  }
}
