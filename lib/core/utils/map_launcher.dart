import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';

/// يفتح الموقع في Waze أو خرائط Google عبر اختيار المستخدم.
class MapLauncher {
  const MapLauncher._();

  static bool _hasCoords(dynamic lat, dynamic lng) =>
      lat is num && lng is num && lat != 0 && lng != 0;

  /// رابط الملاحة في Waze (يعمل على التطبيق وWeb).
  static String wazeUrl(dynamic lat, dynamic lng, String? address) {
    if (_hasCoords(lat, lng)) {
      return 'https://waze.com/ul?ll=${lat!.toStringAsFixed(6)},${lng!.toStringAsFixed(6)}&navigate=yes';
    }
    final q = Uri.encodeComponent((address ?? '').trim());
    return 'https://waze.com/ul?q=$q&navigate=yes';
  }

  /// رابط الملاحة في خرائط Google.
  static String googleUrl(dynamic lat, dynamic lng, String? address) {
    if (_hasCoords(lat, lng)) {
      final d = '${lat!.toStringAsFixed(6)},${lng!.toStringAsFixed(6)}';
      return 'https://www.google.com/maps/dir/?api=1&destination=$d&travelmode=driving';
    }
    final q = Uri.encodeComponent((address ?? '').trim());
    return 'https://www.google.com/maps/search/?api=1&query=$q';
  }

  static Future<bool> _open(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<void> _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.primary,
        ),
      );
    return Future<void>.value();
  }

  /// يعرض ورقة اختيار بين Waze وخرائط Google ثم يفتح التطبيق المطلوب.
  static Future<void> show(
    BuildContext context, {
    required dynamic latitude,
    required dynamic longitude,
    String? address,
  }) async {
    final hasDestination =
        _hasCoords(latitude, longitude) || (address ?? '').trim().isNotEmpty;
    if (!hasDestination) {
      await _toast(context, 'لا يوجد موقع محدد لهذا الطلب');
      return;
    }

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'افتح الموقع بالطريقة التي تناسبك',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: AppColors.accentDeep,
                child: Icon(Icons.navigation_rounded, color: Colors.white),
              ),
              title: const Text(
                'واز (Waze)',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: const Text('أسرع مسار للقيادة'),
              onTap: () => Navigator.pop(ctx, 'waze'),
            ),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: AppColors.primary,
                child: Icon(Icons.map_rounded, color: Colors.white),
              ),
              title: const Text(
                'خرائط Google',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: const Text('عرض الموقع والخريطة'),
              onTap: () => Navigator.pop(ctx, 'google'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (choice == null || !context.mounted) return;
    final url = choice == 'waze'
        ? wazeUrl(latitude, longitude, address)
        : googleUrl(latitude, longitude, address);
    final ok = await _open(url);
    if (!ok && context.mounted) {
      await _toast(context, 'تعذّر فتح تطبيق الخرائط');
    }
  }
}
