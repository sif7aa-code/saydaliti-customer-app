import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../services/admin_panel_gate.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

/// ★ تطبيق لوحة التحكم المنفصل «صيدليتي أدمن» (2026-10-11).
///
/// **لماذا يوجد؟** حماية اللوحة من السرقة: نسخة الزبائن المنتشرة على
/// Google Play لم يعد فيها أي سطر من اللوحة — لا شاشات ولا بوابة — فانتقال
/// اللوحة إلى `applicationId` مستقل (`com.saydaliti.adminpanel`) يعني أن من
/// يفتح APK الزبون لن يجد ما يفتحه أصلاً.
///
/// **ما لم يتغيّر**: نفس القاعدة ونفس البيانات ونفس سلسلة الدخول حرفياً —
/// تسجيل دخول (واتساب/كلمة مرور) ⇒ فحص دور الأدمن ⇒ تذكرة فتح اللوحة.
/// لم تُضَف بوابة جديدة ولا إذن جديد ولا أمر SQL جديد.
///
/// **ما حُذف من هذا التطبيق عمداً**: الإشعارات وFCM وخدمة المراقبة
/// الخلفية وشاشات الزبون. اللوحة أداة عمل تُفتح وتُغلق، ولا تحتاج أن تبقى
/// العملية حيّة في الخلفية.
class AdminPanelApp extends StatelessWidget {
  const AdminPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'اطباء ذي قار أدمن',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _AdminRoot(),
    );
  }
}

/// جذر التوجيه: الدخول أولاً، ثم الدور، ثم بوابة التذكرة.
///
/// ★ التوجيه هنا **لا يدفع** شاشات فوق `home` إلا اللوحة نفسها: العودة
///   إلى المسار الأول بعد الدخول (كما في تطبيق الزبون) حتى تُحدَّث الواجهة
///   تلقائياً لو سُحب دور الأدمن من الخادم أثناء الجلسة.
class _AdminRoot extends StatefulWidget {
  const _AdminRoot();

  @override
  State<_AdminRoot> createState() => _AdminRootState();
}

class _AdminRootState extends State<_AdminRoot> {
  /// الحساب الذي أُشغِّلت له بوابة التذكرة في هذا الفتح — مرة واحدة لكل
  /// حساب، فلا يُطلب مفتاح اللوحة عند كل إعادة بناء للشاشة.
  String? _gateFor;

  bool _running = false;

  /// ★ بوابة التذكرة: تُشغَّل تلقائياً مرة واحدة فقط بعد أن يتأكد أن
  ///   هذا الحساب أدمن. إن كانت التذكرة محفوظة على الجهاز تُفتح اللوحة
  ///   بلا سؤال (مع فحص صامت واحد في القاعدة لهذا الفتح)، وإن لم تكن
  ///   توجد نافذة كتابة المفتاح — وهي التي تُكتب بعدها مرة واحدة.
  Future<void> _openGate() async {
    if (!mounted || _running) return;
    setState(() => _running = true);
    await AdminPanelGate.open(context);
    if (!mounted) return;
    setState(() => _running = false);
  }

  Future<void> _logout() async {
    await AuthService.instance.logout();
    if (!mounted) return;
    // التذكرة تُمسح مع الخروج (`AdminPasswordSession.clear` داخل
    // `logout`)، والشاشة ترجع لتسجيل الدخول لأن `home` يراقب الحالة.
    setState(() {
      _gateFor = null;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    if (!auth.isLoggedIn) return const LoginScreen();

    if (auth.accountRemoved) {
      return _AdminNotice(
        icon: Icons.person_off_rounded,
        color: AppColors.danger,
        title: 'الحساب غير متاح',
        message: 'حذف هذا الحساب أو عُطّل من النظام، فلا يمكن فتح اللوحة.\n'
            'سجّل الدخول بحساب آخر أو راجع الإدارة.',
        onLogout: _logout,
      );
    }

    if (!auth.isAdmin) {
      return _AdminNotice(
        icon: Icons.admin_panel_settings_rounded,
        color: AppColors.warning,
        title: 'هذا الحساب ليس مدير نظام',
        message:
            'هذا التطبيق للوحة تحكم الأدمن فقط. سجّل الدخول بالحساب الذي له '
            'صلاحية الأدمن، أو استخدم تطبيق «اطباء ذي قار» للزبائن.',
        onLogout: _logout,
      );
    }

    final phone = auth.phone ?? '';
    if (_gateFor != phone) {
      _gateFor = phone;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openGate());
    }

    return _AdminEntry(
      name: auth.name ?? 'مدير النظام',
      phone: phone,
      busy: _running,
      onOpen: _openGate,
      onLogout: _logout,
    );
  }
}

/// شاشة ما بين الدخول واللوحة: زر الفتح + هوية الحساب.
///
/// ★ زر الفتح يبقى ظاهراً بعد إغلاق اللوحة بالرجوع للخلف — فلا حاجة
///   لإعادة تسجيل الدخول، والتذكرة لا تُطلب مرة أخرى في نفس الفتح.
class _AdminEntry extends StatelessWidget {
  const _AdminEntry({
    required this.name,
    required this.phone,
    required this.busy,
    required this.onOpen,
    required this.onLogout,
  });

  final String name;
  final String phone;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'اطباء ذي قار أدمن',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: const BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                      child: const Icon(
                        Icons.shield_rounded,
                        color: AppColors.primary,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            phone,
                            style: GoogleFonts.cairo(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'مدير النظام',
                            style: GoogleFonts.cairo(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: busy ? null : onOpen,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: busy
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'جارٍ التحقق…',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        'فتح لوحة التحكم',
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
              ),
              const SizedBox(height: 10),
              Text(
                'التذكرة تُكتب مرة واحدة لكل فتح التطبيق، ولا تُسأل بعدها '
                'حتى لو قفلت الهاتف.',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 11.5,
                  color: AppColors.textHint,
                  height: 1.6,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: onLogout,
                child: Text(
                  'تسجيل الخروج',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    color: AppColors.danger,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// رسالة عند دور غير متاح — أوضح من شاشة فارغة، ومعها خروج لفتح الباب.
class _AdminNotice extends StatelessWidget {
  const _AdminNotice({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.onLogout,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, size: 54, color: color),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.8,
                ),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: onLogout,
                style: FilledButton.styleFrom(
                  backgroundColor: color,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(
                  'تسجيل الخروج',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
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
