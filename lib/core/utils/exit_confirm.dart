import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// رسالة تأكيد قبل الخروج من التطبيق (زر الرجوع في أندرويد).
class ExitConfirm {
  const ExitConfirm._();

  static bool _showing = false;

  /// يُستدعى عند محاولة الخروج: إمّا يغلق التطبيق أو يُلغى.
  static Future<void> guard(BuildContext context) async {
    if (_showing) return;
    _showing = true;
    try {
      final leave = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          icon: const Icon(
            Icons.logout_rounded,
            color: AppColors.primary,
            size: 34,
          ),
          title: const Text(
            'هل تريد الخروج من التطبيق؟',
            textAlign: TextAlign.center,
          ),
          content: const Text(
            'يمكنك المتابعة لاحقاً بدون أي مشكلة.',
            textAlign: TextAlign.center,
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'إلغاء',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'خروج',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      );
      if (leave == true) {
        await SystemNavigator.pop();
      }
    } finally {
      _showing = false;
    }
  }
}
