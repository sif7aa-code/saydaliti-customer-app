import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import 'app_image.dart';

/// إشعار واحد قابل للنقر — مشترك بين ورقة الجرس وشاشة الإشعارات.
class NotificationItemTile extends StatelessWidget {
  const NotificationItemTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.isRead,
    required this.onTap,
    this.badge,
    this.imageUrl,
    this.soundLabel,
  });

  final String title;
  final String subtitle;
  final String time;
  final bool isRead;
  final VoidCallback onTap;

  /// شارة اختيارية (مثل "شعار" للإشعار العام).
  final String? badge;

  /// شعار الحساب (شعار خاص بكل حساب) داخل الإشعار.
  final String? imageUrl;

  /// اسم صوت التنبيه المرتبط بالإشعار.
  final String? soundLabel;

  @override
  Widget build(BuildContext context) {
    final color = isRead ? AppColors.iconContainer : AppColors.primaryLight;
    final accent = isRead ? AppColors.textHint : AppColors.primary;
    final logo = (imageUrl ?? '').trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isRead
                ? AppColors.divider
                : AppColors.primary.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (logo.isNotEmpty)
              Container(
                width: 38,
                height: 38,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isRead
                        ? AppColors.divider
                        : AppColors.primary.withValues(alpha: 0.4),
                  ),
                ),
                child: AppImage(
                  logo,
                  width: 38,
                  height: 38,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isRead
                      ? AppColors.iconContainer
                      : AppColors.primary.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isRead
                      ? Icons.notifications_none_rounded
                      : Icons.notifications_active_rounded,
                  color: accent,
                  size: 20,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: GoogleFonts.cairo(
                            fontWeight: isRead
                                ? FontWeight.w700
                                : FontWeight.w900,
                            fontSize: 13,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (badge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            badge!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  time,
                  style: GoogleFonts.cairo(
                    fontSize: 10,
                    color: AppColors.textHint,
                  ),
                ),
                if (soundLabel != null && soundLabel!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Icon(
                    Icons.volume_up_rounded,
                    size: 12,
                    color: AppColors.textHint,
                    semanticLabel: 'له صوت تنبيه',
                  ),
                ],
                if (!isRead) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.danger,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// تنسيق "منذ ..." من التاريخ الخام.
String timeAgoLabel(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'الآن';
  if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
  if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
  if (diff.inDays < 30) return 'منذ ${diff.inDays} يوم';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)}/${dt.year}';
}
