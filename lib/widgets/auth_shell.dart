import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/privacy_policy.dart';
import '../core/theme/app_colors.dart';

/// غلاف صفحات الدخول الثلاث الموحّد — تصميم 2026-11-25 (مطابق للمرجع):
/// رأس أخضر بصورة ذي قار والسماعة والشعار، ثم بطاقة بيضاء على خلفية
/// فاتحة، ثم موجة سفلى بزر الانتقال بين الشاشتين وروابط السياسة.
class AuthScreenScaffold extends StatelessWidget {
  const AuthScreenScaffold({
    super.key,
    required this.card,
    required this.footer,
  });

  /// بطاقة الحقول (تصل عرضها 420 كحد أقصى وتتوسّط).
  final Widget card;

  /// موجة الأسفل بعناصرها الخاصة بكل شاشة.
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    // ★ لوحة المفاتيح المفتوحة تأكل نصف شاشة الهاتف: نُخفي موجة الرأس
    //   وموجة الأسفل مؤقتاً فتصير المساحة الوسطى كلها للحقول، وتبقى
    //   ظاهرة كاملة وواضحة بلا تصغير ولا تقليص.
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Scaffold(
      backgroundColor: const Color(0xFFF4FAF6),
      // ★ بلا SafeArea حول الكل: صورة الرأس تمتد حتى حافة الشاشة
      //   العلوية (خلف شريط الحالة) وموجة الأسفل تلتصق بقاع الشاشة.
      body: Stack(
        children: [
          Column(
            children: [
              if (!keyboardOpen) const AuthHeaderWave(),
              // ★ المنطقة الوسطى تسحب عمودياً (أسفل وأعلى): على
              //   الشاشات الطويلة تتوسّط البطاقة، وعلى القصيرة
              //   ينزل المستخدم ويطلع فيرى كل الحقول والأزرار
              //   بحجمها الكامل بلا قصّ.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(15, 4, 15, 18),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 22,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: card,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!keyboardOpen)
                // موجة الأسفل تحترم شريط التنقل السفلي فقط (إيماءة
                // النظام) وتبقى ملتصقة بقاع الشاشة.
                SafeArea(top: false, child: footer),
            ],
          ),
          // زر الإغلاق يُرسم فوق الرأس مباشرة تحت شريط الحالة.
          if (Navigator.canPop(context))
            Positioned(
              top: MediaQuery.paddingOf(context).top + 6,
              right: 16,
              child: IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
        ],
      ),
    );
  }
}

/// رأس الصفحة: صورة ذي قار والسماعة بخلفية خضراء، وهالة داكنة،
/// ثم الشعار واسم التطبيق والوصف — وقاعه قوس محدّب للأسفل.
/// ★ الحركة هنا محلية بالكامل (AnimationController واحد): شريط ضوء
///   أخضر يعبر الشعار، ولمعان سلس يمرّ على الاسم — بلا شبكة ولا سيرفر.
class AuthHeaderWave extends StatefulWidget {
  const AuthHeaderWave({super.key});

  @override
  State<AuthHeaderWave> createState() => _AuthHeaderWaveState();
}

class _AuthHeaderWaveState extends State<AuthHeaderWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 212,
      child: ClipPath(
        clipper: _AuthHeaderClipper(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/auth_header.jpg',
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: AppColors.primaryDeep),
            ),
            // هالة داكنة خلف الشعار والاسم تمنح النص تبايناً واضحاً.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.1),
                  radius: 0.95,
                  colors: [Color(0x8A004A00), Color(0x00004A00)],
                  stops: [0.0, 1.0],
                ),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(painter: _HeaderArcGlowPainter()),
            ),
            SafeArea(
              bottom: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LogoBadge(sweep: _sweep),
                    const SizedBox(height: 7),
                    AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, child) {
                        // الاسم يطفو صعوداً وهبوطاً بهدوء، ولمعان يمشي
                        // عليه يميناً ← يساراً — حركة سلسة متصلة.
                        final dy =
                            math.sin(2 * math.pi * _sweep.value) * 1.6;
                        final c = _sweep.value * 1.7 - 0.35;
                        double at(double v) => v.clamp(0.0, 1.0);
                        return Transform.translate(
                          offset: Offset(0, dy),
                          child: ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (rect) => LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: const [
                                Color(0xFFFFFFFF),
                                Color(0xFF93F0A4),
                                Color(0xFFFFFFFF),
                              ],
                              stops: [
                                at(c - 0.28),
                                at(c),
                                at(c + 0.28),
                              ],
                            ).createShader(rect),
                            child: child,
                          ),
                        );
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'أطباء ذي قار',
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontSize: 21.5,
                              fontWeight: FontWeight.w900,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '— بخدمتكم دائمًا وأبدًا —',
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// الشعار داخل إطار أبيض، وشريط ضوء أخضر يعبره ذهاباً كل 3 ثوانٍ.
class _LogoBadge extends StatelessWidget {
  const _LogoBadge({required this.sweep});

  final Animation<double> sweep;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 86,
      height: 86,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/app_icon.png',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const Icon(
                Icons.local_hospital_rounded,
                color: AppColors.primary,
                size: 40,
              ),
            ),
            IgnorePointer(
              child: AnimatedBuilder(
                animation: sweep,
                builder: (context, _) {
                  final t = sweep.value;
                  return ClipRect(
                    child: Transform.translate(
                      offset: Offset(-70 + 190 * t, 0),
                      child: Transform.rotate(
                        angle: -0.5,
                        child: Center(
                          child: Container(
                            width: 26,
                            height: 150,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0x30C9F7CF),
                                  Color(0xF2C8FAD0),
                                  Color(0x30C9F7CF),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthHeaderClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final p = Path()
      ..lineTo(0, size.height - 24)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height + 6,
        size.width,
        size.height - 24,
      )
      ..lineTo(size.width, 0)
      ..close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// خط فاتح رفيع يتبع قوس الرأس — كما في المرجع.
class _HeaderArcGlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height - 24)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height + 6,
        size.width,
        size.height - 24,
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFFBDE8AE).withValues(alpha: 0.55);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// موجة الأسفل: شريط فاتح فوق أخضر متدرّج، وظلّ صامت لمدينة ذي قار،
/// وزر الانتقال إلى الشاشة الأخرى، وروابط السياسة وعن التطبيق.
class AuthFooterWave extends StatelessWidget {
  const AuthFooterWave({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final main = ClipPath(
      clipper: _AuthFooterClipper(),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0E8C14), Color(0xFF06660A)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _SkylinePainter()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: InkWell(
                      onTap: onPressed,
                      borderRadius: BorderRadius.circular(30),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 20,
                                color: Color(0xFF0B7D11),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              label,
                              style: GoogleFonts.cairo(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Center(child: PrivacyPolicyLinksRow(onDark: true)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // ★ الشريط الفاتح يظهر كموجة ثانية أعلى الموجة الرئيسية.
    return Stack(
      children: [
        Positioned.fill(
          top: 11,
          child: ClipPath(
            clipper: _AuthFooterClipper(),
            child: const ColoredBox(color: Color(0xFF2FA83A)),
          ),
        ),
        main,
      ],
    );
  }
}

class _AuthFooterClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final p = Path()..moveTo(0, 26);
    p.quadraticBezierTo(size.width * 0.5, -4, size.width, 22);
    p.lineTo(size.width, size.height);
    p.lineTo(0, size.height);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// ظلّ مدينة ذي قار الصامت أسفل الموجة — نصف شفاف فلا يشوّش النص.
class _SkylinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF043F08).withValues(alpha: 0.5);
    final base = size.height + 2;
    // مبانٍ متدرّجة الارتفاع على طول القاع.
    var x = -6.0;
    var i = 0;
    const widths = [26.0, 18.0, 32.0, 14.0, 24.0, 20.0, 30.0, 16.0, 28.0];
    const heights = [16.0, 26.0, 12.0, 22.0, 34.0, 14.0, 24.0, 30.0, 18.0];
    while (x < size.width) {
      final w = widths[i % widths.length];
      final h = heights[i % heights.length];
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, base - h, w, h),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        paint,
      );
      x += w + 10;
      i++;
    }
    // نخيل بسيطة: ساق وقمّة مثلثة.
    for (final px in [size.width * 0.08, size.width * 0.86]) {
      canvas.drawRect(Rect.fromLTWH(px - 1.2, base - 30, 2.4, 30), paint);
      final frond = Path()
        ..moveTo(px - 9, base - 30)
        ..quadraticBezierTo(px, base - 40, px + 9, base - 30)
        ..quadraticBezierTo(px, base - 34, px - 9, base - 30)
        ..close();
      canvas.drawPath(frond, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
