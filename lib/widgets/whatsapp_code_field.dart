import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/auth_fields.dart';
import '../core/utils/contact_tools.dart';
import '../services/whatsapp_login_service.dart';

/// حقل كود التحقق — يُستخدم في ثلاثة أماكن:
/// تسجيل الدخول، وإنشاء الحساب، وإعادة تعيين كلمة المرور.
///
/// الحقل يقبل الكتابة اليدوية واللصق من رسالة واتساب مباشرة، ويزيل
/// أي فراغات أو شرطات قبل الإرسال.
class WhatsappCodeField extends StatefulWidget {
  const WhatsappCodeField({
    super.key,
    required this.phone,
    this.enabled = true,
    this.showSendButton = true,
    this.onVerifiedChanged,
  });

  /// رقم الهاتف كما يكتبه المستخدم (محلي 07xxxxxxxxx).
  final String phone;

  /// تعطيل الحقل (مثلاً أثناء إرسال بيانات الحساب).
  final bool enabled;

  /// إظهار زر «إرسال الكود» فوق الحقل.
  final bool showSendButton;

  /// يُستدعى عند تغيّر حالة التحقق، ويستخدمه نموذج التسجيل
  /// لمنع الإرسال قبل تأكيد الرمز.
  final ValueChanged<bool>? onVerifiedChanged;

  @override
  State<WhatsappCodeField> createState() => WhatsappCodeFieldState();
}

class WhatsappCodeFieldState extends State<WhatsappCodeField> {
  static const String _kPendingPhone = 'wa_pending_phone';
  static const String _kResendAt = 'wa_resend_at';
  static const String _kCodeLengthKey = 'wa_code_length';

  final _codeController = TextEditingController();

  bool _sending = false;
  bool _verifying = false;
  bool _codeSent = false;
  bool _verified = false;
  int _codeLength = WhatsappLoginService.codeLength;
  int _secondsLeft = 0;
  Timer? _timer;

  /// هل الكود تم التحقق منه بنجاح.
  bool get isVerified => _verified;

  /// توكن الإصدار من الخادم بعد التحقق — إثبات ملكية الرقم.
  /// يُحفظ في الذاكرة فقط، ولا يُستعمل إلا بعد التحقق.
  /// ما عدا التحقق محلي `bool` لا قيمة له أمنياً.
  String? _verifiedToken;
  String? get verifiedToken => _verifiedToken;

  /// هل هناك عملية جارية (إرسال أو تحقق).
  bool get isBusy => _sending || _verifying;

  @override
  void initState() {
    super.initState();
    _restorePending();
  }

  @override
  void didUpdateWidget(covariant WhatsappCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // تغيّر الرقم: الكود القديم ما ينفع، نرجّع الحالة نظيفة.
    if (oldWidget.phone.trim() != widget.phone.trim()) {
      _timer?.cancel();
      _codeController.clear();
      setState(() {
        _codeSent = false;
        _verified = false;
        _secondsLeft = 0;
      });
      // ★ didUpdateWidget يُنفَّذ **أثناء بناء الأب**؛ النداء المتزامن
      //   يستدعي setState في الأب أثناء البناء ⇒
      //   «markNeedsBuild() called during build». نؤجّل النداء إلى ما
      //   بعد اكتمال بناء الإطار الحالي (microtask).
      final cb = widget.onVerifiedChanged;
      if (cb != null) scheduleMicrotask(() => cb(false));
      if (widget.phone.trim().isNotEmpty) _restorePending();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _toast(String msg, {bool danger = false}) {
    if (!mounted) return;
    // ★ `mounted` لا يكفي: عنصر «مُهمَل» (deactivated) أثناء قلب
    //   النافذة يمرّ من الفحص ثم يرمي
    //   «Looking up a deactivated widget's ancestor is unsafe» من
    //   ScaffoldMessenger.of — ورميُها هنا يقتل الدالة المنتظرة
    //   (verify/sendCode) ويترك الأزرار دائرةً بلا نهاية.
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
    } catch (_) {
      // الشاشة تُغلق فعلاً — لا رسالة تُعرض، ولا يجوز أن يُرمى خطأ.
    }
  }

  void _startTimer(int seconds) {
    _timer?.cancel();
    // لازم خارج setState: نداءها من جوّا setState يرمي خطأ متداخل.
    if (mounted) setState(() => _secondsLeft = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        _timer?.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  /// استرجاع آخر كود مُرسل حتى لا يضيع لو المستخدم أغلق الشاشة.
  Future<void> _restorePending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final phone = prefs.getString(_kPendingPhone);
      final resendAt = prefs.getInt(_kResendAt) ?? 0;
      if (phone == null || phone.isEmpty) return;
      if (phone.trim() != widget.phone.trim()) return;
      final remain = resendAt - DateTime.now().millisecondsSinceEpoch;
      if (remain <= 0) return;
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _codeLength =
            prefs.getInt(_kCodeLengthKey) ?? WhatsappLoginService.codeLength;
      });
      // خارج setState حتى لا نتعشع setState متداخل.
      _startTimer((remain / 1000).ceil());
    } catch (_) {}
  }

  Future<void> _rememberPending(String phone, int cooldown) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPendingPhone, phone);
      await prefs.setInt(
        _kResendAt,
        DateTime.now().millisecondsSinceEpoch + cooldown * 1000,
      );
      await prefs.setInt(_kCodeLengthKey, WhatsappLoginService.codeLength);
    } catch (_) {}
  }

  /// إرسال كود جديد للرقم. يرجع `true` إذا أُرسل فعلياً.
  Future<bool> sendCode() async {
    final phone = widget.phone.trim();
    // ★ الحقل إجباري **بكامله** قبل أي رحلة شبكة: كان الفحص `isEmpty`
    //   وحده فيُرسل الطلب رقمٌ ناقص بخمسة أرقام، فيُستهلك الحدّ على
    //   السيرفر ويظهر للزبون خطأ لا يفسّر سببه.
    final phoneProblem = AuthFields.phoneError(phone);
    if (phoneProblem != null) {
      _toast(phoneProblem, danger: true);
      return false;
    }
    if (_sending) return false;
    setState(() => _sending = true);
    // ★ نفس حماية verify(): finally يضمن تصفير _sending مهما حدث.
    try {
      final result = await WhatsappLoginService.instance.sendCode(
        ContactTools.normalize(phone),
      );
      if (!mounted) return false;

      if (result.ok) {
        // الكود الجديد يلغي التحقق السابق، واللازم ننبّه نموذج التسجيل.
        if (_verified) {
          setState(() => _verified = false);
          widget.onVerifiedChanged?.call(false);
        }
        _codeController.clear();
        final cooldown = result.retryAfter > 0 ? result.retryAfter : 60;
        setState(() => _codeSent = true);
        _startTimer(cooldown);
        // ★ ترتيب مقصود: نُعلن النجاح **قبل** الكتابة على القرص.
        //   `_rememberPending` ثلاث عمليات `await` إلى SharedPreferences
        //   كانت في الطريق بين وصول ردّ السيرفر (≈٣٥٠ مللي) وظهور
        //   رسالة النجاح — فيبدو الزر «بطيئاً» لمجرد كتابة محلية.
        //   الكتابة لا تعتمد على شيئ ظاهر، فبقيت بعد الإعلان.
        _toast('تم إرسال الكود إلى واتساب $phone');
        unawaited(_rememberPending(phone, cooldown));
        return true;
      }

      if (result.retryAfter > 0) {
        if (!mounted) return false;
        setState(() => _codeSent = true);
        _startTimer(result.retryAfter);
      }
      _toast(WhatsappLoginService.describe(result.error), danger: true);
      return false;
    } finally {
      if (mounted && _sending) setState(() => _sending = false);
    }
  }

  /// يتحقق من الكود المكتوب أو الملصوق. يرجع `true` إذا صحيح.
  Future<bool> verify() async {
    // ★ كود مؤكَّد سابقاً ⇒ نجاح فوري **بلا إعادة تحقق**. إعادة التحقق
    //   تستهلك الكود على السيرفر (استخدام واحد)، فيفشل الدخول بكودٍ
    //   صحيح لمجرّد أن المستخدم أكّده ثم ضغط «دخول».
    if (_verified && _verifiedToken != null) return true;
    if (_verifying) return _verified;
    final code = _codeController.text.trim();
    // ★ فارغ وناقص صارا رسالتين لا واحدة: من لم يكتب شيئاً يسمع
    //   «أدخل كود التحقق»، ومن كتب ثلاثة يسمع كم نقصه.
    final codeProblem = AuthFields.codeError(code, codeLength: _codeLength);
    if (codeProblem != null) {
      _toast(codeProblem, danger: true);
      return false;
    }
    final phoneProblem = AuthFields.phoneError(widget.phone.trim());
    if (phoneProblem != null) {
      _toast(phoneProblem, danger: true);
      return false;
    }

    setState(() => _verifying = true);
    // ★ finally يضمن تصفير _verifying مهما رمى الطريق (toast على عنصر
    //   مُهمَل، شاشة أُغلقت أثناء الطيران) — عَرقُه `true` للأبد
    //   يعطّل التحقق وزر الدخول معه.
    try {
      final result = await WhatsappLoginService.instance.verifyCode(
        ContactTools.normalize(widget.phone),
        code,
      );
      if (!mounted) return false;

      if (result.ok) {
        if (!_verified) setState(() => _verified = true);
        // ★ The server's session token doubles as the PROOF that this
        //   phone was verified. Password reset needs it - without it the
        //   only gate is a local `bool`, which anyone can delete from the
        //   APK. Kept in memory only, never written to disk.
        _verifiedToken = result.token;
        widget.onVerifiedChanged?.call(true);
        _toast('تم تأكيد الرقم');
        return true;
      }

      _verifiedToken = null;
      if (_verified) setState(() => _verified = false);
      widget.onVerifiedChanged?.call(false);
      _toast(
        WhatsappLoginService.describe(
          result.error,
          attemptsLeft: result.attemptsLeft,
        ),
        danger: true,
      );

      // الكود انتهى أو استُهلك — خلّ المستخدم يطلب واحداً جديداً.
      if (result.error == 'expired' ||
          result.error == 'no_code' ||
          result.error == 'too_many_attempts') {
        _timer?.cancel();
        if (!mounted) return false;
        setState(() {
          _codeSent = false;
          _secondsLeft = 0;
        });
      }
      return false;
    } finally {
      if (mounted && _verifying) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showSendButton) ...[
          FilledButton.icon(
            onPressed: widget.enabled && !_sending && !_verifying
                ? (_secondsLeft > 0 ? null : sendCode)
                : null,
            icon: _sending
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
              // العدّاد على الزر نفسه: ما ينفع تضغطه وتاخذ خطأ «طلبات كثيرة».
              _secondsLeft > 0
                  ? 'أعد الإرسال بعد $_secondsLeft ثانية'
                  : (_codeSent ? 'إعادة إرسال الكود' : 'إرسال كود التحقق'),
              style: GoogleFonts.cairo(
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              disabledBackgroundColor: AppColors.textHint,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextFormField(
          controller: _codeController,
          enabled: widget.enabled && !_verifying,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          maxLength: _codeLength,
          autocorrect: false,
          enableSuggestions: false,
          // يقبل اللصق من رسالة واتساب، ويقبل الكتابة اليدوية.
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(_codeLength),
          ],
          style: GoogleFonts.cairo(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: 10,
            color: _verified ? AppColors.success : AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: 'كود التحقق',
            hintText: List.filled(_codeLength, '0').join(),
            counterText: '',
            prefixIcon: Icon(
              _verified ? Icons.verified_rounded : Icons.lock_rounded,
              color: _verified ? AppColors.success : null,
            ),
            suffixIcon: _verified
                ? const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.success,
                  )
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: _verified ? AppColors.success : AppColors.divider,
                width: 1.4,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: _verified ? AppColors.success : AppColors.primary,
                width: 1.7,
              ),
            ),
          ),
          onFieldSubmitted: (_) => widget.enabled ? verify() : null,
        ),
        if (_verified) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.verified_user_rounded,
                color: AppColors.success,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                'تم تأكيد الرقم',
                style: GoogleFonts.cairo(
                  color: AppColors.success,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ] else if (_codeSent && _secondsLeft > 0) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              'وصلتك رسالة على واتساب — انسخ الكود والصقه هنا',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
