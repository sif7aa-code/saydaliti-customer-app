import 'package:flutter/material.dart';

import '../services/real_data_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/role_logout_button.dart';
import 'notifications_screen.dart';
import 'pharmacy_review_screen.dart';
import 'shop_owner_products_screen.dart';
import 'wallet_screen.dart';

/// ★ واجهة صاحب الصيدلية — عمله فقط، وزر خروج.
///
/// بعد تحويل الأدمن أي حساب إلى «صاحب صيدلية»، يختفي كل شريط التنقّل
/// العام (الرئيسية، الصيدليات، الخدمات، حسابي) ويحلّ محلّه هذا الشريط:
/// منتجاته، محفظته، وإشعاراته — لا زرّ لا يخصّ عمله.
///
/// «خروج» في أعلى الشاشة — لا في الشريط، حتى يبقى الشريط أزرار عمله.
class ShopOwnerShell extends StatefulWidget {
  const ShopOwnerShell({super.key});

  @override
  State<ShopOwnerShell> createState() => _ShopOwnerShellState();
}

class _ShopOwnerShellState extends State<ShopOwnerShell> {
  int _index = 0;

  /// الشاشات تُبنى مرة واحدة — نفس قرار `MainShell`، حتى لا
  /// يُعاد بناء الشاشة (وإعادة جلب بياناتها) عند كل نقرة.
  List<Widget>? _screens;

  /// ★ `[onChanged]` يجعل القائمة غير `const`: هي دالة تُمسّ كاش
  ///   الكتالوج، فلا يمكن أن تكون قيمة ثابتة.
  List<Widget> get _screensCache => _screens ??= [
        // ★★ أول تبويب: طلبات الوصفة بانتظار الموافقة. الطلب لا يصل
        //   المندوبين قبلها، فصاحب الصيدلية يجب أن يراها فوراً عند
        //   فتح التطبيق لا بعد بحث في تبويب رابع (طلب الأدمن 2026-11-20).
        const PharmacyReviewScreen(),
        ShopOwnerProductsScreen(
          onChanged: () => RealDataService.instance.refreshProducts(),
        ),
        const ShopWalletScreen(),
        const NotificationsScreen(),
      ];

  static const List<BottomNavItem> _items = [
    BottomNavItem(
      label: 'الطلبات',
      icon: Icons.receipt_long_outlined,
      activeIcon: Icons.receipt_long_rounded,
    ),
    BottomNavItem(
      label: 'منتجاتي',
      icon: Icons.inventory_2_outlined,
      activeIcon: Icons.inventory_2_rounded,
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

  void _go(int i) {
    // ★ بلا خروج مبكر: النقرة على الزرّ الذي أنت فيه تعيد تحديث شاشتك
    //   وتصعد لأول عنصر — مثل بقية القائمة السفلية.
    if (i != _index) setState(() => _index = i);
    final id = _tabIds[i];
    if (id.isNotEmpty) TabRefresh.fire(id);
  }

  /// ★ معرّفات التبويبات — نفس ترتيب [_items].
  static const List<String> _tabIds = [
    'owner_prescriptions',
    'owner_products',
    'owner_wallet',
    'role_notifications',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ★ حدود عزل لكل تبويب — نفس MainShell.
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
          // ★ زرّ خروج في **أعلى** الشاشة يساراً، لا في الشريط السفلي.
          //
          // ★ تحذير مقيس على الجهاز: هذه الطبقة تلتصق بالحافة اليسرى،
          //   وأزرار `actions` في RTL تهبط على **الحافة نفسها** فتقع
          //   تحت الطبقة ويبتلع اللمس (حدث فعلاً: «تحديث» في المنتجات
          //   والمحفظة كان يفتح نافذة الخروج). لذلك زر التحديث في تلك
          //   الشاشات وُضع `leading` — الجهة اليمنى، بعيداً هنا.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 6,
            left: 10,
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
