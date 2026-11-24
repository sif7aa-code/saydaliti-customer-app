import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/exit_confirm.dart';
import '../services/auth_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/bottom_nav_bar.dart';
import 'account_screen.dart';
import 'doctors_home_screen.dart';
import 'favorite_doctors_screen.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'shops_screen.dart';

/// الهيكل الرئيسي للتطبيق: يضم الشاشات والشريط السفلي.
class MainShell extends StatefulWidget {
  const MainShell({super.key, this.isGuest = false});

  final bool isGuest;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  // الشاشات تُبنى **مرة واحدة** وتبقى حيّة طوال عمر الهيكل.
  //
  // كان لكل تبويب عدّاد `ValueKey` يزيد عند كل نقرة، فتُتلف الحالة
  // وتُبنى من جديد ⇒ `initState` ⇒ إعادة جلب الكتالوج وإعادة بناء
  // الصفحة كاملة وإعادة إطلاق كل طلبات الصور، عند **كل** تنقّل.
  List<Widget>? _screens;

  List<Widget> get _screensCache => _screens ??= [
    // ★ 2026-11-19 (تصميم طبيب): الرئيسية صارت **دليل الأطباء**، والأدوية
    //   والصيدليات تبويبان خاصان. تبويب «حجز طبيب» أُخرج من الشريط
    //   السفلي، والحجز يبقى من بروفايل الطبيب كما هو.
    //   شريحة «الأدوية» في نهاية شرائح الدليل تفتح تبويب الأدوية.
    //   «المفضلة» تبويب مستقل يعرض كل من أُضيف إلى مفضلة الدليل.
    DoctorsHomeScreen(onOpenTab: _goToTab),
    const FavoriteDoctorsScreen(),
    HomeScreen(),
    ShopsScreen(),
    AccountScreen(isGuest: widget.isGuest),
  ];

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isGuest != widget.isGuest) _screens = null;
  }

  /// ★ معرّفات التبويبات — نفس ترتيب [_navItems]، وتقرأها الشاشات عبر
  ///   `TabRefreshTarget`. النقرة على أيّ زرّ تصعد بشاشته لأول عنصر
  ///   وتعمل لها تحديثاً حقيقياً مع رنّة النجاح.
  static const List<String> _tabIds = [
    'home',
    'favs',
    'meds',
    'shops',
    'account',
  ];

  void _goToTab(int index) {
    // ★ بلا خروج مبكر عند التبويب المحدّد: النقرة على الزرّ الذي أنت
    //   فيه هي «أعد التحديث واصعد للأعلى» — كما في فيسبوك وإنستغرام —
    //   وكان الخروج المبكر يمنع أي عمل.
    if (index != _currentIndex) setState(() => _currentIndex = index);
    // التبويب الآن مسؤول عن جلب بياناته بنفسه، فلا حاجة لنبضة
    // `revalidate` الخلفية المقيّدة بـ ٩٠ ثانية فوق ذلك.
    TabRefresh.fire(_tabIds[index]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ExitConfirm.guard(context);
      },
      child: Scaffold(
        // ★ إطار المرجع: خلفية خضراء متدرّجة بزخارف، والتبويبات داخل
        //   ورقتها الخاصة، وشريط التنقل بطاقة عائمة فوق الخلفية.
        backgroundColor: AppColors.primary,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _ShellBackdrop(),
            Column(
              children: [
                Expanded(
                  // حدود عزل لكل تبويب: أي إعادة رسم في تبويب لا تُفسد
                  // رسم التبويبات الأخرى، وهو ما يجعل `IndexedStack` رخيصاً.
                  child: IndexedStack(
                    index: _currentIndex,
                    children: [
                      for (final s in _screensCache)
                        RepaintBoundary(
                          child: KeyedSubtree(
                            key: ValueKey<Object>(s),
                            child: s,
                          ),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: BottomNavBar(
                    items: _navItems,
                    currentIndex: _currentIndex,
                    onTap: (index) => _onNavTap(index),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// ★ الشريط: الرئيسية = دليل الأطباء، ثم المفضلة، ثم الأدوية (الرئيسية
  ///   القديمة) والصيدليات وحسابي. «حجز طبيب» أُخرج من الشريط وبقي من
  ///   بروفايل الطبيب. تبويب «خدمات» أُخرج سابقاً: طلب المندوب صار بطاقة
  ///   داخل تبويب الأدوية.
  static const List<BottomNavItem> _navItems = [
    BottomNavItem(
      label: 'الرئيسية',
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
    ),
    BottomNavItem(
      label: 'المفضلة',
      icon: Icons.favorite_border_rounded,
      activeIcon: Icons.favorite_rounded,
    ),
    BottomNavItem(
      label: 'الأدوية',
      icon: Icons.medication_outlined,
      activeIcon: Icons.medication_rounded,
    ),
    BottomNavItem(
      label: 'صيدليات',
      icon: Icons.local_pharmacy_outlined,
      activeIcon: Icons.local_pharmacy_rounded,
    ),
    BottomNavItem(
      label: 'حسابي',
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
    ),
  ];

  void _onNavTap(int index) {
    // ★ حالة الدخول تُقرأ **الآن** من `AuthService` لا من `widget.isGuest`.
    //   الخاصية تُبنى مع آخر `build` للهيكل، فقد تسبقها نقرة عن تغيّر
    //   الحالة (دخول ناجح للتو، أو خروج من «حسابي») فتُبقي المستخدم
    //   في صفحة زائر وهو مسجّل دخوله — والفحص المباشر هو مصدر الحقيقة
    //   نفسه الذي تقرأه بقية الشاشات.
    final loggedIn = AuthService.instance.isLoggedIn;

    // ★ «حسابي» (4) لا يفتح للزائر: شاشة الدخول أولاً ثم ينقله الهيكل
    //   إلى الزرّ الذي ضغطه.
    if (index == 4 && !loggedIn) {
      _openLoginForTab(index);
      return;
    }

    _goToTab(index);
  }

  /// ★ يفتح شاشة تسجيل الدخول من شريط التنقّل، وبعد نجاح الدخول ينقل
  ///   التبويب إلى الزرّ الذي ضغطه المستخدم (`4` لحسابي).
  ///   الشاشة تُزيح نفسها بـ`pop` عند وجود `onLoginSuccess`، فيعود إلى
  ///   الهيكل نفسه — بلا إعادة تشغيل ولا فقدان لفهرس التبويبات.
  void _openLoginForTab(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          showBackButton: true,
          onLoginSuccess: () => _goToTab(index),
        ),
      ),
    );
  }
}

/// خلفية الإطار: تدرّج أخضر مع خطوط منحنية شفافة كما في المرجع.
class _ShellBackdrop extends StatelessWidget {
  const _ShellBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(gradient: AppColors.shellBackdrop),
      child: CustomPaint(painter: _SwooshPainter()),
    );
  }
}

class _SwooshPainter extends CustomPainter {
  const _SwooshPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.03
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.055);
    for (var i = 0; i < 3; i++) {
      final lift = i * h * 0.055;
      final path = Path()
        ..moveTo(-w * 0.15, h * 0.42 + lift)
        ..cubicTo(
          w * 0.28,
          h * 0.20 + lift,
          w * 0.72,
          h * 0.92 + lift,
          w * 1.15,
          h * 0.48 + lift,
        );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
