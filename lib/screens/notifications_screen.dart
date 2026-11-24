import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/notification_center.dart';
import '../services/notification_history.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/notification_tile.dart';
import 'secretary_appointments_screen.dart';

/// ★ شاشة الإشعارات الكاملة — تبويب في واجهتي صاحب الصيدلية والطبيب.
///
///   المصدر نفسه الذي يقرأه جرس الرأس: `get_my_notifications` على
///   الخادم + السجل المحلي على الجهاز، فالإشعار الذي تراه هنا هو نفسه
///   الذي في الورقة. الضغط على الإشعار يحذفه من مصدره (الخادم يتحقّق
///   أن الصف لهذا الرقم) ويفتح رابطه إن وُجد.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with TabRefreshTarget<NotificationsScreen> {
  /// نفس المعرّف في واجهتي صاحب الصيدلية والطبيب: واحدة فقط تعمل الآن.
  @override
  String get tabId => 'role_notifications';

  @override
  Future<void> Function() onTabRefresh() => _load;

  List<Map<String, dynamic>> _items = const [];
  String _brand = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _items = const [];
      });
      return;
    }
    final local = await NotificationHistory.instance.all();
    final pending = await SupabaseService.instance.fetchNotifications(phone);
    final brand = NotificationCenter.instance.hasBrand
        ? (image: NotificationCenter.instance.brandImage, title: '')
        : await SupabaseService.instance.fetchNotificationBrand(phone);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _brand = (brand.image ?? '').trim();
      _items = [
        // ★ إشعار المكتمل/المرفوض يختفي بعد ٢٤ ساعة من الشاشة أيضاً.
        ...pending
            .where(
              (n) => !NotificationHistory.isExpiredDone(
                type: n['type']?.toString(),
                at: n['created_at']?.toString(),
              ),
            )
            .map(
              (n) => <String, dynamic>{
                'id': n['id']?.toString() ?? '',
                'title': n['title']?.toString() ?? 'إشعار',
                'body': n['body']?.toString() ?? '',
                'is_global': n['is_global'] == true,
                'created_at': n['created_at'],
                'link_url': n['link_url']?.toString() ?? '',
                'sound': n['sound']?.toString() ?? '',
                'local': false,
              },
            ),
        ...local.map(
          (n) => <String, dynamic>{
            'id': n['id']?.toString() ?? '',
            'title': n['title']?.toString() ?? 'إشعار',
            'body': n['body']?.toString() ?? '',
            'is_global': false,
            'created_at': n['at'],
            'logo': n['logo'],
            'local': true,
          },
        ),
      ];
    });
  }

  Future<void> _open(Map<String, dynamic> n, int index) async {
    final phone = AuthService.instance.phone ?? '';
    final isLocal = n['local'] == true;
    final id = n['id']?.toString() ?? '';
    final link = n['link_url']?.toString().trim() ?? '';

    // الصف المحلي يُحذف من سجل الجهاز فقط؛ صف السيرفر حُذف أصلاً عند
    // التسليم. المطابقة بالوقت لا بالرقم: القائمة المدمجة لا رقم فيها
    // يطابق سجل الجهاز.
    if (isLocal) {
      final at = n['created_at']?.toString() ?? '';
      if (at.isNotEmpty) {
        await NotificationHistory.instance.removeOne(at);
      }
    } else if (id.isNotEmpty && phone.isNotEmpty) {
      await SupabaseService.instance.deleteNotification(id, phone);
    }
    if (!mounted) return;
    setState(() {
      final list = List<Map<String, dynamic>>.from(_items);
      list.removeAt(index);
      _items = list;
    });

    if (link.isEmpty) return;
    // ★ `appointments` علامة داخلية تفتح شاشة الموافقات، لا رابطاً خارجياً.
    if (link == 'appointments') {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const SecretaryAppointmentsScreen(),
        ),
      );
      return;
    }
    final uri = Uri.tryParse(link.startsWith('http') ? link : 'https://$link');
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _empty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        const Icon(
          Icons.notifications_none_rounded,
          size: 56,
          color: AppColors.textHint,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'لا توجد إشعارات حالياً',
            style: GoogleFonts.cairo(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('الإشعارات'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        // ★ بلا زرّ في `actions`: أزرار actions في RTL تهبط على الحافة
        //   اليسرى حيث يطفو زر الخروج في واجهة صاحب الصيدلية. التحديث
        //   بالسحب أو بنقرة التبويب.
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? _empty()
            : ListView.separated(
                controller: tabScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(14),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final n = _items[index];
                  final own = _brand;
                  final logo = own.isNotEmpty
                      ? own
                      : (n['logo']?.toString().trim() ?? '');
                  final sound = n['sound']?.toString().trim() ?? '';
                  return NotificationItemTile(
                    title: n['title']?.toString() ?? 'إشعار',
                    subtitle: n['body']?.toString() ?? '',
                    time: timeAgoLabel(n['created_at']?.toString()),
                    isRead: true,
                    imageUrl: logo,
                    soundLabel: sound.isEmpty ? null : sound,
                    badge: n['is_global'] == true ? 'شعار' : null,
                    onTap: () => _open(n, index),
                  );
                },
              ),
      ),
    );
  }
}
