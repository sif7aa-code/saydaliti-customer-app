import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/auth_fields.dart';

/// حقول وصفحات الدخول — تصميم 2026-11-25 (مطابق للمرجع):
/// خلفية فاتحة خضراء، بطاقة بيضاء، حقول مملوءة خفيفة بحدود ناعمة،
/// وأزرار كرويّة بتدرّج أخضر.

/// حشوة الحقول وحدودها — مصدر واحد لكل شاشات الدخول.
const Color authFieldFill = Color(0xFFF2F9F2);
const Color authFieldBorder = Color(0xFFD9EDD9);
const Color authPillFill = Color(0xFFDDF3DD);

/// تسمية الحقل فوقه — يمين، أخضر داكن، ثقيلة.
class AuthFieldLabel extends StatelessWidget {
  const AuthFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 6),
      child: Text(
        text,
        textAlign: TextAlign.start,
        style: GoogleFonts.cairo(
          color: AppColors.textPrimary,
          fontSize: 13.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

InputDecoration authFieldDecoration({
  String? hint,
  Widget? prefixIcon,
  Widget? suffixIcon,
}) {
  return InputDecoration(
    hintText: hint,
    hintStyle: GoogleFonts.cairo(
      color: AppColors.textHint,
      fontWeight: FontWeight.w600,
      fontSize: 13,
    ),
    counterText: '',
    filled: true,
    fillColor: authFieldFill,
    isDense: true,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    prefixIconConstraints: const BoxConstraints(minWidth: 52, minHeight: 46),
    suffixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 46),
    contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
    enabledBorder: _border(authFieldBorder),
    focusedBorder: _border(AppColors.primary, width: 1.6),
    errorBorder: _border(AppColors.danger),
    focusedErrorBorder: _border(AppColors.danger, width: 1.6),
    disabledBorder: _border(authFieldBorder),
  );
}

OutlineInputBorder _border(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: color, width: width),
  );
}

/// دائرة أيقونة فاتحة داخل الحقل (يمين الحقل في العربية).
class AuthIconWell extends StatelessWidget {
  const AuthIconWell(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      margin: const EdgeInsetsDirectional.only(start: 8, end: 4),
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFFE4F5E4),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 19, color: AppColors.primary),
    );
  }
}

/// حقل الاسم — أيقونة شخص في دائرة يميناً، والنص في الوسط.
class AuthNameField extends StatelessWidget {
  const AuthNameField({
    super.key,
    required this.controller,
    this.hint = 'الاسم الكامل كما في الإثبات',
    this.validator,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hint;
  final FormFieldValidator<String>? validator;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      textAlign: TextAlign.center,
      style: GoogleFonts.cairo(
        fontWeight: FontWeight.w700,
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      decoration: authFieldDecoration(
        hint: hint,
        prefixIcon: const AuthIconWell(Icons.person_rounded),
      ),
      validator: validator,
    );
  }
}

/// حقل الهاتف — بادئة +964 في كبسولة يميناً، وأيقونة سماعة يساراً.
class AuthPhoneField extends StatelessWidget {
  const AuthPhoneField({
    super.key,
    required this.controller,
    this.onChanged,
    this.validator,
    this.requireMobilePrefix = false,
    this.enabled = true,
    this.hint = '07x xxxx xxxx',
  });

  final TextEditingController controller;
  final VoidCallback? onChanged;
  final FormFieldValidator<String>? validator;
  final bool requireMobilePrefix;
  final bool enabled;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      onChanged: (_) => onChanged?.call(),
      keyboardType: TextInputType.phone,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
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
      decoration: authFieldDecoration(
        hint: hint,
        prefixIcon: Container(
          margin: const EdgeInsetsDirectional.only(start: 8, end: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: authPillFill,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '+964',
            style: GoogleFonts.cairo(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
        ),
        suffixIcon: const Icon(
          Icons.phone_rounded,
          color: AppColors.primary,
          size: 20,
        ),
      ),
      validator:
          validator ??
          (v) => AuthFields.phoneError(
            v ?? '',
            requireMobilePrefix: requireMobilePrefix,
          ),
    );
  }
}

/// حقل كلمة المرور — قفل يميناً، وعين يساراً.
class AuthPasswordField extends StatelessWidget {
  const AuthPasswordField({
    super.key,
    required this.controller,
    required this.obscure,
    required this.onToggle,
    this.validator,
  });

  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggle;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      textAlign: TextAlign.center,
      style: GoogleFonts.cairo(
        fontWeight: FontWeight.w700,
        fontSize: 14,
        color: AppColors.textPrimary,
      ),
      decoration: authFieldDecoration(
        hint: 'كلمة المرور',
        prefixIcon: const Icon(
          Icons.lock_rounded,
          color: AppColors.primary,
          size: 21,
        ),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(
            obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            color: AppColors.primary,
            size: 21,
          ),
        ),
      ),
      validator: validator,
    );
  }
}

/// كبسولة اختيار نوع الحساب: أيقونة ونص، والمختارة خضراء صلبة.
class AuthProfessionChip extends StatelessWidget {
  const AuthProfessionChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : AppColors.textPrimary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : const Color(0xFFF0FAF1),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: selected ? AppColors.primary : authFieldBorder,
          ),
        ),
        // ★ الأربعة في صفٍّ واحد كما في المرجع: كبسولة مضغوطة، ومحتواها
        //   يتقلّص قليلاً على الشاشات الضيقة بدل أن يُقتطع اسم «صيدلاني».
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? Colors.white : AppColors.primary,
              ),
              const SizedBox(width: 3),
              Text(
                label,
                maxLines: 1,
                style: GoogleFonts.cairo(
                  color: fg,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// زر الإرسال الكرويّ بتدرّج أخضر — الزر الرئيس لكل شاشات الدخول.
class AuthSubmitButton extends StatelessWidget {
  const AuthSubmitButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.person_add_alt_1_rounded,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0FA319), Color(0xFF087710)],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.22),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: busy ? null : onPressed,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 21,
                    height: 21,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 20, color: Colors.white),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: GoogleFonts.cairo(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// بطاقة الحقول البيضاء — نفس الحواف والحشوة في الشاشتين.
class AuthCard extends StatelessWidget {
  const AuthCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8F4E8)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.07),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// رأس البطاقة: أيقونة، عنوان، سطر توضيحي، وفاصل بنبضة قلب متحركة.
/// ★ النبض يعمل داخل الرسم نفسه (AnimationController محلي): لا طلب
///   شبكة ولا مؤقّت سيرفر — حركة بلا أي أثر خارج الجهاز.
class AuthCardHeading extends StatefulWidget {
  const AuthCardHeading({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  State<AuthCardHeading> createState() => _AuthCardHeadingState();
}

class _AuthCardHeadingState extends State<AuthCardHeading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..repeat();

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(widget.icon, size: 26, color: AppColors.primary),
        const SizedBox(height: 4),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            color: AppColors.textPrimary,
            fontSize: 20.5,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          widget.subtitle,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            color: AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: Divider(color: authFieldBorder, height: 1)),
            SizedBox(
              width: 46,
              height: 16,
              child: CustomPaint(painter: _EcgPainter(beat: _beat)),
            ),
            const Expanded(child: Divider(color: authFieldBorder, height: 1)),
          ],
        ),
      ],
    );
  }
}

/// خط النبض (ECG) بين فاصلَي العنوان — العلامة الخضراء تجري على المسار
/// ثم تستريح قليلاً، ثم تعود: نبضة متكرّرة كما في شاشة المراقبة.
class _EcgPainter extends CustomPainter {
  _EcgPainter({required this.beat}) : super(repaint: beat);

  final Animation<double> beat;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final mid = size.height / 2;
    // ★ الخط كله يتحرك: موجة متكرّرة تُزحف يساراً باستمرار كشاشة
    //   مراقبة، مع تنفّس خفيف في ارتفاع القمم — حركة محلية بحتة.
    final phase = beat.value;
    final amp = 1 + 0.3 * math.sin(2 * math.pi * phase);

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = AppColors.primary.withValues(alpha: 0.12);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = AppColors.primary.withValues(alpha: 0.9);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var k = -1; k <= 1; k++) {
      final s = k * w - w * phase;
      final path = Path()
        ..moveTo(s, mid)
        ..lineTo(s + w * 0.18, mid)
        ..lineTo(s + w * 0.30, mid - 5 * amp)
        ..lineTo(s + w * 0.40, mid + 6 * amp)
        ..lineTo(s + w * 0.50, mid - 8 * amp)
        ..lineTo(s + w * 0.60, mid + 4 * amp)
        ..lineTo(s + w * 0.70, mid)
        ..lineTo(s + w, mid);
      canvas.drawPath(path, glow);
      canvas.drawPath(path, line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EcgPainter oldDelegate) =>
      oldDelegate.beat != beat;
}

/// شريط تنبيه فاتح: علامة صح خضراء يميناً والنص بعدها — كما في المرجع.
class AuthNoticeBanner extends StatelessWidget {
  const AuthNoticeBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FBF1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDEFDD)),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.right,
              style: GoogleFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
