import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/account_name.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// لوحة الأجهزة: تُظهر أي مستخدم لديه توكن إشعارات (يستقبل إشعارات
/// Firebase حتى والتطبيق مغلق) وأي مستخدم لا يوجد لديه توكن بعد.
///
/// التوكن لا يُنشأ إلا على جهاز ثُبّت فيه التطبيق وفُتح مرة واحدة
/// ومنح إذن الإشعارات — لذلك هذه الشاشة هي مرجع معرفة الأرقام الناقصة.
class AdminDevicesScreen extends StatefulWidget {
  const AdminDevicesScreen({super.key});

  @override
  State<AdminDevicesScreen> createState() => _AdminDevicesScreenState();
}

class _AdminDevicesScreenState extends State<AdminDevicesScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _users = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final users = await SupabaseService.instance.fetchUsers();
    if (!mounted) return;
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  int get _withToken =>
      _users.where((u) => (u['fcm_token']?.toString() ?? '').isNotEmpty).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('الأجهزة والإشعارات'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(14),
                children: [
                  _summary(),
                  const SizedBox(height: 14),
                  for (final u in _users) _row(u),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _summary() {
    final missing = _users.length - _withToken;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.devices_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                '$_withToken من ${_users.length} جهاز مُفعّل',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: _users.isEmpty ? 0 : _withToken / _users.length,
              minHeight: 8,
              backgroundColor: AppColors.divider,
              color: missing == 0 ? AppColors.success : AppColors.warning,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'الرقم بدون توكن لن تصلك إشعارات خارجية. الحل: ثبّت التطبيق على '
            'ذلك الجهاز، افتحه مرة واحدة، واسمح بإذن الإشعارات.',
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.verified_user_rounded,
                  size: 16,
                  color: AppColors.success,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'التوكن يُحفظ ويُحدَّث تلقائياً عند كل فتح للتطبيق، '
                    'ولا يُمسح أبداً عند تبديل الحساب على نفس الجهاز.',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> u) {
    final token = u['fcm_token']?.toString().trim() ?? '';
    final has = token.isNotEmpty && token != 'null';
    final phone = u['phone']?.toString() ?? '';
    final name = AccountName.real(name: u['name'], phone: phone);
    final isDriver = u['is_driver'] == true;
    final isAdmin = u['is_admin'] == true;
    final isOwner = u['is_shop_owner'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: has
              ? AppColors.success.withValues(alpha: 0.35)
              : AppColors.danger.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: has
                  ? AppColors.success.withValues(alpha: 0.12)
                  : AppColors.danger.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              has ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
              size: 20,
              color: has ? AppColors.success : AppColors.danger,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ★ الاسم الحقيقي وحده: إن لم يكن له اسم فالرقم أسفله
                  //   يكفيه، فلا يُكرَّر الرقم في سطرين ولا يُخترع لقب.
                if (name.isNotEmpty && name != phone) ...[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  phone,
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 5,
                  children: [
                    if (isAdmin) _tag('أدمن', AppColors.primary),
                    if (isDriver) _tag('مندوب', AppColors.info),
                    if (isOwner) _tag('صاحب صيدلية', AppColors.warning),
                    _tag(
                      has ? 'إشعارات مفعّلة' : 'لا يستقبل إشعار',
                      has ? AppColors.success : AppColors.danger,
                    ),
                    if (has)
                      _tag('رمز محفوظ ····${_mask(token)}', AppColors.textHint),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// آخر ٤ خانات فقط — التوكن نفسه لا يُعرض ولا يُنسخ.
  static String _mask(String token) {
    if (token.length <= 4) return '····';
    return token.substring(token.length - 4);
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: GoogleFonts.cairo(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
