import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/privacy_policy.dart';
import '../core/theme/app_colors.dart';

/// غلاف صفحات الدخول الثلاث الموحّد (تصميم 2026-11-18):
/// موجة تركوازية علوية بالشعار، وموجة سفلية بزر الانتقال بين
/// شاشات الدخول وروابط السياسة، وبينهما منطقة وسطى تسحب عمودياً
/// وتتوسّط فيها البطاقة.
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
      backgroundColor: AppColors.background,
      // ★ بلا SafeArea حول الكل: موجة الرأس تمتد حتى حافة الشاشة
      //   العلوية (خلف شريط الحالة) وموجة الأسفل تلتصق بقاع الشاشة،
      //   فيكبر القسم الأوسط المخصص للحقول إلى أقصى حد.
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
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 24,
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
          // زر الإغلاق يُرسم فوق الموجة مباشرة تحت شريط الحالة.
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

/// موجة الرأس التركوازية: شعار دائري أبيض، «صيدليتي» وتحتها
/// الوصف، وعلامات «+» باهتة على اليسار — كلها داخل موجة منحنية
/// أسفلها تمتد خلف شريط الحالة حتى حافة الشاشة العلوية.
class AuthHeaderWave extends StatelessWidget {
  const AuthHeaderWave({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 215,
      child: ClipPath(
        clipper: _AuthHeaderWaveClipper(),
        child: DecoratedBox(
          decoration: const BoxDecoration(gradient: AppColors.brandGradient),
          child: Stack(
            children: [
              // علامات «+» طبية باهتة على يسار الرأس.
              Positioned(
                left: 24,
                top: 54,
                child: Icon(
                  Icons.add,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.22),
                ),
              ),
              Positioned(
                left: 56,
                top: 104,
                child: Icon(
                  Icons.add,
                  size: 12,
                  color: Colors.white.withValues(alpha: 0.18),
                ),
              ),
              Positioned(
                left: 16,
                top: 130,
                child: Icon(
                  Icons.add,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
              ),
              // هالة دائرية ناعمة على اليمين مكان رفوف الصيدلية.
              Positioned(
                right: -46,
                top: -40,
                child: Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              Positioned(
                right: 10,
                bottom: 30,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),
              // ★ المحتوى الداخلي (الشعار والعنوان) ينزل تحت شريط
              //   الحالة تلقائياً، بينما الموجة نفسها تمتد خلفه
              //   حتى حافة الشاشة العلوية.
              SafeArea(
                bottom: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 78,
                        height: 78,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Image.asset(
                          'assets/images/app_icon.png',
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.local_pharmacy_rounded,
                            color: AppColors.primary,
                            size: 38,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'اطباء ذي قار',
                        style: GoogleFonts.cairo(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'وصلها لك مع اطباء ذي قار',
                        style: GoogleFonts.cairo(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthHeaderWaveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final p = Path()..lineTo(0, size.height - 46);
    p.quadraticBezierTo(
      size.width * 0.30,
      size.height - 6,
      size.width * 0.55,
      size.height - 26,
    );
    p.quadraticBezierTo(
      size.width * 0.80,
      size.height - 46,
      size.width,
      size.height - 14,
    );
    p.lineTo(size.width, 0);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// موجة الأسفل التركوازية: نبضة قلب بيضاء، زر الانتقال إلى شاشة
/// دخول أخرى، وروابط السياسة وعن التطبيق.
class AuthFooterWave extends StatelessWidget {
  const AuthFooterWave({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _AuthFooterWaveClipper(),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primary, AppColors.primaryDeep],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 30, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Icon(
                  Icons.monitor_heart_rounded,
                  color: Colors.white.withValues(alpha: 0.85),
                  size: 22,
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton.icon(
                  onPressed: onPressed,
                  icon: Icon(icon, color: Colors.white, size: 18),
                  label: Text(
                    label,
                    style: GoogleFonts.cairo(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const Center(child: PrivacyPolicyLinksRow(onDark: true)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthFooterWaveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final p = Path()..moveTo(0, 28);
    p.quadraticBezierTo(size.width * 0.5, 0, size.width, 20);
    p.lineTo(size.width, size.height);
    p.lineTo(0, size.height);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
