import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/map_launcher.dart';
import '../services/doctor_service.dart';

/// ★ بطاقة «حجزك عند دكتور/ة» — ما يراه صاحب الحجز في «حجوزاتي».
///
///   رقمها من **سلسلة الحجوزات وحدها** (`doctor_serial_seq`)، فلا هو
///   طلب صيدلية ولا «طلب مندوب». لا مندوب في هذه الدورة: الحجز يمرّ من
///   المريض إلى سكرتير العيادة مباشرة، والرقم يظهر بعد الموافقة فقط.
class DoctorAppointmentCard extends StatelessWidget {
  const DoctorAppointmentCard({
    super.key,
    required this.appointment,
    this.onDetails,
  });

  final DoctorAppointment appointment;

  /// فتح شيت «تفاصيل حجز دكتور/ة» — البطاقة وحدها لا تُعطي الموعد كاملاً
  /// ولا مراقبة الخطوات، والشيت هو ما يفتحه صاحب الحجز ليقرأ الباقي.
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final a = appointment;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onDetails,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            'حجزك عند دكتور/ة',
                            style: GoogleFonts.cairo(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (a.serialLabel.isNotEmpty)
                          SerialBadge(serial: a.serialLabel),
                      ],
                    ),
                  ),
                  AppointmentStateChip(status: a.status),
                ],
              ),
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.category_outlined,
                label: 'التخصص',
                value: a.specialty,
              ),
              _InfoRow(
                icon: Icons.badge_outlined,
                label: 'الدكتور',
                value: a.doctorName,
              ),
              _InfoRow(
                icon: Icons.person_outline_rounded,
                label: 'المريض',
                value: a.patientName,
              ),
              _InfoRow(
                icon: Icons.event_available_outlined,
                label: 'الموعد',
                value: a.whenLabel,
              ),
              if (a.address.isNotEmpty)
                _InfoRow(
                  icon: Icons.location_on_outlined,
                  label: 'الموقع',
                  value: a.address,
                ),

              const SizedBox(height: 10),
              // ★ لا زر «اتصال» هنا: الرقم المحفوظ في الحجز هو رقم المريض
              //   نفسه (حتى تتصل به العيادة)، فاتصال صاحبه بنفسه لا معنى
              //   له. بطاقة المريض تعرض موقعه وزر التفاصيل وحدهما.
              SizedBox(
                width: double.infinity,
                child: _MiniButton(
                  icon: Icons.map_outlined,
                  label: 'الموقع',
                  onPressed: () => MapLauncher.show(
                    context,
                    latitude: a.latitude,
                    longitude: a.longitude,
                    address: a.address,
                  ),
                ),
              ),
              // سطر يقول إن البطاقة تُفتح: بلا هذا الدليل تُظنّ قائمة
              // معلومات مغلقة، فيسأل صاحبها أين التفاصيل.
              if (onDetails != null) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'تفاصيل الحجز ومراقبته',
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryDark,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_left_rounded,
                      size: 16,
                      color: AppColors.primaryDark,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// شارة الرقم التسلسلي — الخضراء تُميّز الحجز عن رقم الطلب العادي.
class SerialBadge extends StatelessWidget {
  const SerialBadge({super.key, required this.serial});

  final String serial;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Text(
        serial,
        style: GoogleFonts.cairo(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: AppColors.primaryDark,
        ),
      ),
    );
  }
}

/// شارة الحالة — البطاقة والشيت يقرآن النص نفسه من [DoctorStatus.label]،
/// فلا يقول أحدهما «جديد» والآخر «بانتظار مندوب» للحجز نفسه.
class AppointmentStateChip extends StatelessWidget {
  const AppointmentStateChip({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final label = DoctorStatus.label(status);
    // ★ لكل خطوة لونها: انتظار الموافقة كهرماني، ثم الموافقة خضراء —
    //   والرفض/الإلغاء أحمر أو رمادي.
    final color = switch (status) {
      'pending' => AppColors.warning,
      'approved' => AppColors.success,
      'called' => AppColors.accentDeep,
      'accepted' => AppColors.success,
      'done' => AppColors.success,
      'cancelled' => AppColors.textHint,
      'rejected' => AppColors.danger,
      _ => AppColors.warning,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.cairo(
          fontSize: 11.5,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: AppColors.textHint),
          const SizedBox(width: 7),
          Text(
            '$label:',
            style: GoogleFonts.cairo(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.45)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
