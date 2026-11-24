import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_colors.dart';
import '../screens/cart_screen.dart';
import '../screens/login_screen.dart';
import '../services/auth_service.dart';
import '../services/cart_service.dart';
import '../services/notification_center.dart';
import '../services/notification_history.dart';
import '../services/supabase_service.dart';
import 'notification_tile.dart';

/// الرأس العلوي: دائرة السلة ثم أيقونة التنبيهات الحقيقية.
class LocationHeader extends StatelessWidget {
  const LocationHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [HeaderCartButton(), SizedBox(width: 8), NotificationsBell()],
    );
  }
}

/// زرّ الجرس + عدّاد غير المقروء + قائمة الإشعارات الحقيقية.
///
/// يُعاد استعماله في رأس شاشة الدليل كما في التصميم المرجعي: جرس أبيض
/// الشكل على الشريط الأخضر (بلا دائرة خلفية).
class NotificationsBell extends StatefulWidget {
  const NotificationsBell({
    super.key,
    this.size = 36,
    this.background = Colors.white,
    this.iconColor = AppColors.textPrimary,
    this.icon = Icons.notifications_none_rounded,
  });

  final double size;
  final Color background;
  final Color iconColor;
  final IconData icon;

  @override
  State<NotificationsBell> createState() => _NotificationsBellState();
}

class _NotificationsBellState extends State<NotificationsBell> {
  int _unread = 0;
  bool _hasUnread = false;
  bool _loadingNotifications = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // لا يتم تحديد الموقع تلقائياً عند فتح التطبيق،
    // بل فقط عند تأكيد الطلب في شاشة السلة.
    // مراقبة الإشعارات يتم مركزياً عبر NotificationCenter.
    _refreshUnread();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// قراءة عدد الإشعارات غير المقروءة + إظهار الجديد فوراً.
  Future<void> _refreshUnread() async {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) return;
    // العدّاد مشتق من نفس الاستطلاع المركزي، فلا نضاعف الطلبات على
    // السيرفر (كل طلب REST يُسجَّل في سجلات Supabase).
    if (!NotificationCenter.instance.hasBrand) {
      final count = await SupabaseService.instance.unreadNotificationsCount(
        phone,
      );
      if (!mounted) return;
      setState(() {
        _unread = count;
        _hasUnread = count > 0;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _hasUnread = NotificationCenter.instance.hasUndelivered;
    });
  }

  /// قائمة الإشعارات الحقيقية من قاعدة البيانات، والنقر عليها
  /// يعلّمها كمقروءة ويحدّث شارة غير المقروء.
  Future<void> _showNotifications(BuildContext context) async {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'سجّل الدخول لعرض إشعاراتك',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _loadingNotifications = true);
    // السجل على الجهاز (بلا تخزين على السيرفر) + أي صف لم يُستهلك بعد.
    final local = await NotificationHistory.instance.all();
    final pending = await SupabaseService.instance.fetchNotifications(phone);
    final notifications = [
      // ★ لا نعرض إشعار طلب مكتمل/مرفوض مرّ عليه ٢٤ ساعة حتى لو لم
      //   يصل تنظيف الخادم بعد — الحذف نفسه في السجل المحلي والقاعدة.
      ...pending
          .where(
            (n) => !NotificationHistory.isExpiredDone(
              type: n['type']?.toString(),
              at: n['created_at']?.toString(),
            ),
          )
          .map(
            (n) => <String, dynamic>{
              // ★ `id` لازم: بدونه كان الحذف يستدعي `user_phone = eq.‏''`
              //   فلا يُحذف الإشعار إطلاقاً.
              'id': n['id']?.toString() ?? '',
              'title': n['title']?.toString() ?? 'إشعار',
              'body': n['body']?.toString() ?? '',
              'type': n['type'],
              'logo': NotificationCenter.instance.brandImage,
              'is_global': n['is_global'] == true,
              'created_at': n['created_at'],
              'local': false,
            },
          ),
      ...local.map(
        (n) => <String, dynamic>{
          'id': n['id']?.toString() ?? '',
          'title': n['title']?.toString() ?? 'إشعار',
          'body': n['body']?.toString() ?? '',
          'type': n['type'],
          'logo': n['logo'],
          'is_global': false,
          'created_at': n['at'],
          'local': true,
        },
      ),
    ];
    // شعار الحساب: كل إشعار من إشعارات هذا الحساب يحمل شعاره الخاص.
    final brand = NotificationCenter.instance.hasBrand
        ? (image: NotificationCenter.instance.brandImage, title: '')
        : await SupabaseService.instance.fetchNotificationBrand(phone);
    if (!context.mounted) return;
    setState(() => _loadingNotifications = false);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final unread = notifications
              .where((n) => n['is_read'] != true)
              .length;
          return Container(
            padding: const EdgeInsets.all(20),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'التنبيهات والإشعارات',
                      style: GoogleFonts.cairo(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (unread > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.danger,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$unread جديد',
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                if (notifications.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.notifications_none_rounded,
                          size: 48,
                          color: AppColors.textHint,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'لا توجد إشعارات حالياً',
                          style: GoogleFonts.cairo(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const BouncingScrollPhysics(),
                      itemCount: notifications.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final n = notifications[index];
                        final isLocal = n['local'] == true;
                        final id = n['id']?.toString() ?? '';
                        final link = n['link_url']?.toString().trim() ?? '';
                        final isGlobal = n['is_global'] == true;
                        final sound = n['sound']?.toString().trim() ?? '';
                        final own = brand.image ?? '';
                        final logo = own.isNotEmpty
                            ? own
                            : (n['logo']?.toString().trim() ?? '');
                        return NotificationItemTile(
                          title: n['title']?.toString() ?? 'إشعار',
                          subtitle: n['body']?.toString() ?? '',
                          time: timeAgoLabel(n['created_at']?.toString()),
                          isRead: true,
                          imageUrl: logo,
                          soundLabel: sound.isEmpty ? null : sound,
                          onTap: () async {
                            // الصف المحلي يُحذف من سجل الجهاز فقط؛
                            // صف السيرفر حُذف أصلاً عند التسليم.
                            if (isLocal) {
                              // ★ المطابقة بالوقت لا بالرقم: القائمة
                              //   المدمجة (سيرفر + محلي) لا رقم فيها
                              //   يطابق سجل الجهاز.
                              final at = n['created_at']?.toString() ?? '';
                              if (at.isNotEmpty) {
                                await NotificationHistory.instance.removeOne(
                                  at,
                                );
                              }
                            } else if (id.isNotEmpty) {
                              // الخادم يتحقّق أن الصف لهذا الرقم.
                              await SupabaseService.instance.deleteNotification(
                                id,
                                phone,
                              );
                            }
                            if (!ctx.mounted) return;
                            setSheetState(() {
                              notifications.removeAt(index);
                            });
                            _refreshUnread();
                            if (link.isNotEmpty) {
                              final uri = Uri.tryParse(
                                link.startsWith('http')
                                    ? link
                                    : 'https://$link',
                              );
                              if (uri != null) {
                                await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                              }
                            }
                          },
                          badge: isGlobal ? 'شعار' : null,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 4),
              ],
            ),
          );
        },
      ),
    );
    if (mounted) _refreshUnread();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showNotifications(context),
      borderRadius: BorderRadius.circular(widget.size),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.background,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _loadingNotifications ? Icons.hourglass_top_rounded : widget.icon,
              size: widget.size * 0.56,
              color: widget.iconColor,
            ),
          ),
          if (_hasUnread)
            Positioned(
              left: 2,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                constraints: const BoxConstraints(minWidth: 18),
                child: Text(
                  _unread > 99 ? '+99' : '$_unread',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ★ سلة الرأس: كانت تبويباً في الشريط السفلي ونُقلت إلى جانب الجرس،
///   بنفس مقاس الدائرة (36) لئلا يختلف شكل الرأس. تدفع شاشة السلة صفحةً
///   بزر رجوع، والزائر يمرّ ببوابة الدخول أولاً كما كان التبويب يفعل.
///
/// ★ عامة (2026-11-20): تبويب «الأدوية» يستعملها في رأسه — إعادة تصميم
///   الرئيسية أخرجت `LocationHeader` من الاستخدام فبقيت السلة بلا زرٍّ
///   في شاشات المنتجات (من يضيف دواءً لا يجد باباً لسلته).
///   الألوان قابلة للضبط ليظهر الزرّ على خلفية فاتحة أو خضراء.
class HeaderCartButton extends StatelessWidget {
  const HeaderCartButton({
    super.key,
    this.size = 36,
    this.background = Colors.white,
    this.iconColor = AppColors.textPrimary,
  });

  final double size;
  final Color background;
  final Color iconColor;

  /// يفتح السلة، بعد بوابة الدخول إن لم يكن هناك جلسة.
  ///
  /// `LoginScreen` تُزيح نفسها **قبل** أن تنادي `onLoginSuccess`
  /// (`login_screen.dart:178`)، فالفتح من داخل النداء لا يضع السلة خلف
  /// شاشة الدخول.
  static void open(BuildContext context) {
    final nav = Navigator.of(context);
    void pushCart() =>
        nav.push(MaterialPageRoute(builder: (_) => const CartScreen()));

    if (!AuthService.instance.isLoggedIn) {
      nav.push(
        MaterialPageRoute(
          builder: (_) =>
              LoginScreen(showBackButton: true, onLoginSuccess: pushCart),
        ),
      );
      return;
    }
    pushCart();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CartService.instance,
      builder: (context, _) {
        final count = CartService.instance.totalItemCount;
        return InkWell(
          onTap: () => open(context),
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: background,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.shopping_cart_outlined,
                  size: size * 0.56,
                  color: iconColor,
                ),
              ),
              if (count > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    constraints: const BoxConstraints(minWidth: 18),
                    child: Text(
                      count > 99 ? '+99' : '$count',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 9,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
