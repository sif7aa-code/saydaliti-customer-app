import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/map_launcher.dart';
import '../core/utils/order_elapsed.dart';
import '../services/doctor_service.dart';
import 'doctor_appointment_card.dart';
import 'order_elapsed_text.dart';

/// ★ شيت «تفاصيل حجز دكتور/ة» — مراقبة الحجز كما يُراقَب الطلب.
///
///   الدورة الجديدة: المريض يثبّت الحجز ⇒ إشعار سكرتير العيادة ⇒
///   السكرتير يكتب رقم الحجز ويوافق ⇒ يصل المريض إشعار برقمه. لا مندوب
///   في هذه الدورة إطلاقاً، فلا خطوة «مندوب» في الشيت.
///
///   الخطوات تُقرأ من أوقات القاعدة (`created_at` · `approved_at`) لا
///   من تخمين الواجهة: خطوة لم يُكتب وقتها لم تحدث.
class DoctorAppointmentDetails {
  const DoctorAppointmentDetails._();

  static Future<void> show(
    BuildContext context, {
    required DoctorAppointment appointment,
    bool clinicView = false,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: _DetailsSheet(
          appointment: appointment,
          clinicView: clinicView,
        ),
      ),
    );
  }
}

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.appointment, this.clinicView = false});

  final DoctorAppointment appointment;

  /// يُفتح من شاشة السكرتير/الطبيب: الرقم المعروض هو هاتف المريض الذي
  /// تتصل به العيادة، لا رقم العيادة نفسها.
  final bool clinicView;

  @override
  Widget build(BuildContext context) {
    final a = appointment;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'تفاصيل حجز دكتور/ة',
                      style: GoogleFonts.cairo(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (a.serialLabel.isNotEmpty) ...[
                    SerialBadge(serial: a.serialLabel),
                    const SizedBox(width: 8),
                  ],
                  AppointmentStateChip(status: a.status),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _StepTrack(appointment: a),

                    const SizedBox(height: 16),
                    _MetaLine(
                      icon: Icons.event_available_outlined,
                      text: 'الموعد: ${a.whenLabel}',
                    ),
                    if (a.createdAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            Text(
                              '${OrderElapsed.counterLabel(a.elapsedFields)}: ',
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            OrderElapsedText(
                              order: a.elapsedFields,
                              showIcon: false,
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                color: AppColors.primaryDark,
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 14),
                    _InfoRow(
                      icon: Icons.category_outlined,
                      label: 'نوع التخصص',
                      value: a.specialty,
                    ),
                    _InfoRow(
                      icon: Icons.badge_outlined,
                      label: 'اسم الدكتور',
                      value: a.doctorName,
                    ),
                    _InfoRow(
                      icon: Icons.person_outline_rounded,
                      label: 'اسم المريض أو صاحب الحجز',
                      value: a.patientName,
                    ),
                    _InfoRow(
                      icon: Icons.phone_outlined,
                      label: clinicView
                          ? 'هاتف المريض'
                          : 'رقم هاتف الحجز',
                      value: a.contactPhone,
                    ),
                    _InfoRow(
                      icon: Icons.location_on_outlined,
                      label: 'الموقع',
                      value: a.address,
                    ),
                    _InfoRow(
                      icon: Icons.person_outline_rounded,
                      label: 'ثبّته',
                      value: a.bookedName,
                    ),
                    // ★ الكشفية سطرها الخاص: استقطاع ثابت 500 دينار لكل
                    //   حجز معتمد — لا نسبة ولا ضرب، والمنتظر يقول ذلك.
                    _InfoRow(
                      icon: Icons.payments_outlined,
                      label: 'كشفية الحجز',
                      value: a.isRejected
                          ? '${CurrencyFormatter.format(a.examFee)} — لم تُقيَّد (مرفوض)'
                          : a.isPending
                          ? '${CurrencyFormatter.format(a.examFee)} — تُقيَّد عند الموافقة'
                          : '${CurrencyFormatter.format(a.examFee)}'
                                ' (صافي '
                                '${CurrencyFormatter.format(a.examFee - (a.examFee < 500 ? a.examFee : 500))}'
                                ' بعد استقطاع ثابت 500)',
                    ),

                    const SizedBox(height: 16),
                    Row(
                      children: [
                        // ★ زر الاتصال للعيادة وحدها: الرقم المحفوظ رقم
                        //   المريض، فلا يعود صاحب الحجز يتصل بنفسه.
                        if (clinicView) ...[
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: a.contactPhone.isEmpty
                                  ? null
                                  : () => ContactTools.callCustomer(
                                      context,
                                      a.contactPhone,
                                    ),
                              icon: const Icon(Icons.call_rounded, size: 18),
                              label: Text(
                                'اتصال بالمريض',
                                style: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              style: _outline,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => MapLauncher.show(
                              context,
                              latitude: a.latitude,
                              longitude: a.longitude,
                              address: a.address,
                            ),
                            icon: const Icon(Icons.map_outlined, size: 18),
                            label: Text(
                              'الموقع',
                              style: GoogleFonts.cairo(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: _outline,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// نفس حدود أزرار البطاقة، فلا يختلف شكل الزر بين البطاقة والشيت.
  static ButtonStyle get _outline => OutlinedButton.styleFrom(
    foregroundColor: AppColors.primary,
    side: BorderSide(color: AppColors.primary.withValues(alpha: 0.45)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
}

/// خطوات الحجز: مثبّت · موافقة العيادة برقمه.
///
/// تُقرأ من أوقات القاعدة وحدها — خطوة لم يُكتب وقتها لم تحدث، فلا
/// تُخضرّ «تمّ الحجز» لأن الواجهة افترضتها.
class _StepTrack extends StatelessWidget {
  const _StepTrack({required this.appointment});

  final DoctorAppointment appointment;

  @override
  Widget build(BuildContext context) {
    final a = appointment;
    final rejected = a.isRejected;
    final approved =
        a.approvedAt != null || a.isApproved || a.isAccepted || a.isDone;
    final approvalDetail = rejected
        ? 'رفضت العيادة الموعد — بلا كشفية'
        : approved
        ? [
            if (a.serialLabel.isNotEmpty) 'رقم الحجز ${a.serialLabel}',
            if (a.approvedAt != null) _clock(a.approvedAt),
          ].join(' · ')
        : 'بانتظار موافقة سكرتير العيادة وكتابة رقم الحجز';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'مراقبة الحجز',
            style: GoogleFonts.cairo(
              fontSize: 12.5,
              fontWeight: FontWeight.w900,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          _Step(
            title: 'الحجز مثبّت',
            detail: _clock(a.createdAt),
            reached: true,
            isLast: rejected || a.isCancelled,
          ),
          if (a.isCancelled)
            _Step(
              title: 'أُلغي الحجز',
              detail: '—',
              reached: false,
              isLast: true,
            )
          else if (rejected)
            _Step(
              title: 'رفضت العيادة',
              detail: approvalDetail,
              reached: false,
              isLast: true,
            )
          else ...[
            _Step(
              title: 'موافقة العيادة',
              detail: approvalDetail,
              reached: approved,
              isLast: !a.isDone,
            ),
            if (a.isDone)
              _Step(
                title: 'تمّ الحجز',
                detail: _clock(a.doneAt),
                reached: true,
                isLast: true,
              ),
          ],
        ],
      ),
    );
  }

  /// ساعة محلية من وقت القاعدة — '—' للوقت الغائب، ولا وقت مختلَق.
  static String _clock(DateTime? at) =>
      at == null ? '—' : OrderElapsed.clock(at.toUtc().toIso8601String());
}

class _Step extends StatelessWidget {
  const _Step({
    required this.title,
    required this.detail,
    required this.reached,
    required this.isLast,
  });

  final String title;
  final String detail;
  final bool reached;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final color = reached ? AppColors.primary : AppColors.textHint;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: reached ? AppColors.primaryLight : AppColors.divider,
                shape: BoxShape.circle,
              ),
              child: Icon(
                reached ? Icons.check_rounded : Icons.circle_outlined,
                size: 13,
                color: color,
              ),
            ),
            if (!isLast)
              Container(width: 2, height: 18, color: AppColors.divider),
          ],
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                    color: reached ? AppColors.textPrimary : AppColors.textHint,
                  ),
                ),
                Text(
                  detail,
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: reached ? AppColors.primaryDark : AppColors.textHint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
      padding: const EdgeInsets.only(top: 7),
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

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: AppColors.primary),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: AppColors.primaryDark,
            ),
          ),
        ),
      ],
    );
  }
}
