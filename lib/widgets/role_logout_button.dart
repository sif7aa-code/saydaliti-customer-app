import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/auth_service.dart';

/// زرّ خروج عائم لواجهات الأدوار (صاحب صيدلية / طبيب).
///
/// الشاشات الداخلية تحمل `AppBar` بأزرار تحديث على الحافة اليسرى في
/// RTL، فيُوضع هذا الزر على الحافة الأخرى في الهيكل صاحب الـ`Stack`.
class RoleLogoutButton extends StatelessWidget {
  const RoleLogoutButton({super.key});

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تسجيل الخروج',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'هل تريد الخروج من الحساب؟',
          style: GoogleFonts.cairo(fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('تراجع', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text('خروج', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await AuthService.instance.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _confirmLogout(context),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(
            Icons.logout_rounded,
            size: 20,
            color: AppColors.danger,
          ),
        ),
      ),
    );
  }
}
