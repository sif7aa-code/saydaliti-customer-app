import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/shop_display.dart';
import '../services/shop_hours_store.dart';

/// ★ بوابة واحدة لكل مواضع «أضف إلى السلة»: بطاقة منتج، صف أفقي، شبكة،
///   تفاصيل منتج، شورتس، بحث، وزيادة الكمية من داخل السلة.
///
///   كلها تسأل هذا السؤال واحدًا: «هل يُسمح الآن؟» — فتخرج الرسالة واحدة
///   في كل التطبيق، ويقول النص متى يفتح الصيدلية فعلاً بدل «مغلق» مبهمة.
///
///   [fallbackOpen] حالة الصيدلية التي تعرفها الشاشة (من كائن `Shop` عندها).
///   تُستعمل فقط حين لم يكن جدول الصيدلية مسجَّلاً بعد في `ShopHoursStore`؛
///   وحين يكون الجدول معروفاً فالوقت الحالي هو الحكم، فلا تبقى شاشة تعرض
///   «مغلق» على صيدلية فتح قبل لحظة، ولا العكس.
abstract final class ShopGate {
  /// null = الإضافة مسموحة. غير ذلك = نص يُعرض للزبون كما هو.
  static String? blockMessage({
    required String shopId,
    required String shopName,
    bool fallbackOpen = true,
  }) {
    final status = ShopHoursStore.instance.statusFor(shopId);
    if (status == null) {
      // الجدول غير معروف: لا نختلق وقتاً، ونحترم ما قالته الشاشة.
      return fallbackOpen
          ? null
          : 'عذراً، ${shopDisplayName(shopName)} مغلق حالياً '
                'ولا يمكن إضافة منتجاته للسلة';
    }
    if (status.isOpen) return null;
    return status.blockMessage(shopName);
  }

  /// هل الزرّ يعمل الآن؟ (للألوان والشارات — العرض وحده، لا المنع)
  static bool isOpen({required String shopId, bool fallbackOpen = true}) {
    final status = ShopHoursStore.instance.statusFor(shopId);
    if (status == null) return fallbackOpen;
    return status.isOpen;
  }

  /// ★ شريط المنع الأحمر بأيقونة القفل — الشكل نفسه في كل الصفحات.
  static void showBlocked(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.lock_clock_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  /// Convenience: اسأل ثم اعرض — تُرجع true إذا كان الضغط ممنوعاً.
  static bool refuseIfNeeded(
    BuildContext context, {
    required String shopId,
    required String shopName,
    bool fallbackOpen = true,
  }) {
    final message = blockMessage(
      shopId: shopId,
      shopName: shopName,
      fallbackOpen: fallbackOpen,
    );
    if (message == null) return false;
    showBlocked(context, message);
    return true;
  }
}
