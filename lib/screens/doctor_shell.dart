import 'package:flutter/material.dart';

import '../services/tab_refresh.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/role_logout_button.dart';
import 'doctor_availability_screen.dart';
import 'doctor_wallet_screen.dart';
import 'notifications_screen.dart';
import 'secretary_appointments_screen.dart';

/// ★ واجهة الطبيب/سكرتير العيادة — عمله فقط، بلا أي زرّ آخر.
///
/// الحساب الذي يُحوَّل إلى طبيب من لوحة الأدمن يرى هذه الواجهة بدل
/// الواجهة العامة (الرئيسية، الصيدليات، الخدمات…): حجوزات عيادته
/// ليوافق عليها، وأوقات الحجز التي يضبطها للزبائن، ومحفظتها بعد خصم
/// ثابت 500 دينار لكل حجز، وإشعاراته.
class DoctorShell extends StatefulWidget {
  const DoctorShell({super.key});

  @override
  State<DoctorShell> createState() => _DoctorShellState();
}

class _DoctorShellState extends State<DoctorShell> {
  int _index = 0;

  /// الشاشات تُبنى مرة واحدة — نفس قرار `MainShell` و`ShopOwnerShell`،
  /// حتى لا يُعاد جلب البيانات عند كل نقرة.
  List<Widget>? _screens;

  List<Widget> get _screensCache => _screens ??= const [
        SecretaryAppointmentsScreen(),
        DoctorAvailabilityScreen(),
        DoctorWalletScreen(),
        NotificationsScreen(),
      ];

  static const List<BottomNavItem> _items = [
    BottomNavItem(
      label: 'الحجوزات',
      icon: Icons.fact_check_outlined,
      activeIcon: Icons.fact_check_rounded,
    ),
    BottomNavItem(
      label: 'حجز الزبائن',
      icon: Icons.toggle_off_outlined,
      activeIcon: Icons.toggle_on_rounded,
    ),
    BottomNavItem(
      label: 'محفظتي',
      icon: Icons.account_balance_wallet_outlined,
      activeIcon: Icons.account_balance_wallet_rounded,
    ),
    BottomNavItem(
      label: 'الإشعارات',
      icon: Icons.notifications_none_rounded,
      activeIcon: Icons.notifications_active_rounded,
    ),
  ];

  static const List<String> _tabIds = [
    'clinic_appointments',
    'clinic_hours',
    'clinic_wallet',
    'role_notifications',
  ];

  void _go(int i) {
    // النقرة على التبويب نفسه تعيد التحديث وتصعد لأول عنصر.
    if (i != _index) setState(() => _index = i);
    final id = _tabIds[i];
    if (id.isNotEmpty) TabRefresh.fire(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _index,
            children: [
              for (final s in _screensCache)
                RepaintBoundary(
                  child: KeyedSubtree(key: ValueKey<Object>(s), child: s),
                ),
            ],
          ),
          // ★ الجهة اليمنى: أزرار تحديث الشاشات في AppBar تقع يساراً
          //   في RTL، وهذه الطبقة لا تبتلعها.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 6,
            right: 10,
            child: const RoleLogoutButton(),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavBar(
        items: _items,
        currentIndex: _index,
        onTap: _go,
      ),
    );
  }
}
