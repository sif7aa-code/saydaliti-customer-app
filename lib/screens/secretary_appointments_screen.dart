import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/deduction_label.dart';
import '../core/utils/map_launcher.dart';
import '../services/auth_service.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/doctor_appointment_card.dart';
import '../widgets/doctor_appointment_details.dart';
import 'doctor_availability_screen.dart';
import 'doctor_secretary_screen.dart';

/// ★ «موافقات الحجوزات» — شاشة سكرتير العيادة والطبيب.
///
///   طلب الأدمن (11-19): «إذا مريض يطلب حجز دكتور يظهر إشعار خارجي
///   وداخل التطبيق للسكرتير … موافقة أو رفض … إذا وافق السكرتير يظهر
///   رقم الحجز بدون تكرار واضح مع سعر الكشفية 15,000».
///
///   كل شيء هنا من `doctor_appointments_for_secretary` التي تعزل برقم
///   الجلسة داخل القاعدة (`doctors.secretary_phone` أو `doctors.phone`)،
///   فلا شاشة تقرأ حجوزات عيادة غيرها. الكشفية **لا تُقيَّد عند
///   الموافقة**: تؤكد العيادة انتهاء المعاينة بزر مستقل
///   (`doctor_queue_complete`) وهناك يُكتب قيد واحد في المحفظة.
///   معاينة «صافي المحفظة» تأخذ استقطاع العيادة من `my_doctor_wallet`
///   (يضبطه الأدمن) لا من نسبة مكتوبة هنا.
class SecretaryAppointmentsScreen extends StatefulWidget {
  const SecretaryAppointmentsScreen({super.key});

  @override
  State<SecretaryAppointmentsScreen> createState() =>
      _SecretaryAppointmentsScreenState();
}

class _SecretaryAppointmentsScreenState
    extends State<SecretaryAppointmentsScreen>
    with TabRefreshTarget<SecretaryAppointmentsScreen> {
  /// تبويب «الحجوزات» في واجهة الطبيب: النقرة تعيد جلب الحجوزات.
  @override
  String get tabId => 'clinic_appointments';

  @override
  Future<void> Function() onTabRefresh() => _load;

  List<DoctorAppointment> _rows = const [];
  /// قائمة انتظار اليوم من `doctor_queue` — الدور والاستدعاء والإنهاء.
  DoctorQueue _queue = const DoctorQueue();
  /// ★ إحصائيات اليوم: المراجعون الآن + المكتمل + المرفوض (بلا تكرار).
  DoctorDayStats _dayStats = const DoctorDayStats();
  /// استقطاع كل عيادة كما ضبطه الأدمن (من محفظة العيادة نفسها).
  Map<String, ClinicWallet> _clinics = const {};
  bool _loading = true;
  bool _readFailed = false;
  String _failure = '';

  /// معرّف الحجز الذي يجري عليه إجراء الآن — يمنع النقر المزدوج.
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await DoctorService.instance.forSecretary();
    // الفراغ الحقيقي ردّ 2xx بلا صفوف؛ أي سبب آخر (شبكة أو دالة غير
    // مثبّتة) يُقال بنصّه ولا يُغطّى بكلمة «لا حجوزات».
    final why = (SupabaseService.instance.lastRpcError ?? '').trim();
    final wallet = await DoctorService.instance.wallet();
    final queue = await DoctorService.instance.queue();
    final stats = await DoctorService.instance.dayStats();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = list;
      _queue = queue;
      _dayStats = stats;
      _clinics = {
        for (final w in wallet?.wallets ?? const <ClinicWallet>[]) w.doctorId: w,
      };
      _readFailed = list.isEmpty && why.isNotEmpty;
      _failure = _readFailed ? why : '';
    });
  }

  /// ★ استدعاء المريض: الاستدعاء المتعدد مسموح — والرد يقول إن كان
  ///   مستدعى قبلاً.
  Future<void> _callPatient(DoctorQueueItem item) async {
    if (_busy != null) return;
    setState(() => _busy = 'call:${item.id}');
    final res = await DoctorService.instance.callPatient(item.id);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    final who = item.patientName.isEmpty ? item.serialLabel : item.patientName;
    _toast(
      res.already ? 'هذا المريض مستدعى الآن' : 'استُدعي $who — وصله إشعار «حان دورك»',
      true,
    );
    await _load();
  }

  /// «المريض التالي»: أول منتظر (أصغر رقم) لم يُستدعَ بعد.
  Future<void> _callNext(DoctorQueueClinic clinic) async {
    if (_busy != null) return;
    setState(() => _busy = 'next:${clinic.doctorId}');
    final res = await DoctorService.instance.callNext(clinic.doctorId);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    _toast('استُدعي المريض التالي${res.serial.isNotEmpty ? ' — ${res.serial}' : ''}', true);
    await _load();
  }

  /// ★ تأكيد انتهاء المعاينة — هنا يُقيَّد المال مرة واحدة.
  Future<void> _completeVisit(DoctorQueueItem item, DoctorQueueClinic clinic) async {
    if (_busy != null) return;
    final net = _netFor(clinic.doctorId, 15000);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'انتهاء المعاينة',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'تأكيد انتهاء معاينة ${item.patientName.isEmpty ? 'هذا المريض' : item.patientName}'
          '${item.serialLabel.isEmpty ? '' : ' (${item.serialLabel})'}؟\n'
          '${net == null ? '' : 'سيُقيَّد صافي ${CurrencyFormatter.format(net)} في محفظة العيادة الآن — '}'
          'مرة واحدة فقط، ولا يُحتسب مرتين ولو تكرر الضغط.',
          style: GoogleFonts.cairo(
            fontSize: 13,
            height: 1.7,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'إلغاء',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            icon: const Icon(Icons.task_alt_rounded, size: 18),
            label: Text(
              'تأكيد الانتهاء',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = 'done:${item.id}');
    final res = await DoctorService.instance.completeVisit(item.id);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    if (res.already) {
      _toast(
        'معاينة هذا الحجز منتهية من قبل — لا قيد جديد',
        true,
      );
    } else if (res.credited) {
      _toast(
        'انتهت المعاينة — قُيَّد ${CurrencyFormatter.format(res.netAmount)} في محفظة العيادة',
        true,
      );
    } else {
      _toast('انتهت المعاينة — لا قيد مالي جديد', true);
    }
    await _load();
  }

  /// ★ إلغاء انتظار مريض وحذف حجزه نهائياً — للمنتظر فقط (لم تكتمل
  ///   معاينته). القاعدة ترفض المكتمل والمرفوض حتى لو نودي عليها.
  Future<void> _deleteWaiting(DoctorQueueItem item) async {
    if (_busy != null) return;
    final who = item.patientName.isEmpty ? 'هذا المريض' : item.patientName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'إلغاء الانتظار وحذف الحجز',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'سيُلغى انتظار $who'
          '${item.serialLabel.isEmpty ? '' : ' (${item.serialLabel})'} '
          'ويُحذف حجزه نهائياً من العيادة، ويصل المريض إشعار بالإلغاء.\n'
          'لا يمكن التراجع، والمعاينات المكتملة لا تُحذف.',
          style: GoogleFonts.cairo(
            fontSize: 13,
            height: 1.7,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'تراجع',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'حذف نهائي',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = 'del:${item.id}');
    final res = await DoctorService.instance.deleteAppointment(item.id);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    _toast('أُلغي الانتظار وحُذف الحجز نهائياً', true);
    await _load();
  }

  /// صافي الكشفية حسب استقطاع العيادة (كما في ردّ القاعدة) — للعرض فقط.
  int? _netFor(String doctorId, int fee) {
    final c = _clinics[doctorId];
    if (c == null) return null;
    final cut = c.deductionMethod == DeductionMethod.percent
        ? (fee * c.deductionValue / 100).round()
        : c.deductionValue.round();
    return fee - (cut > fee ? fee : cut);
  }

  Future<void> _approve(DoctorAppointment a) async {
    if (_busy != null) return;
    String? lastError;
    while (true) {
      // ★ الرقم أولاً: لا موافقة بلا رقم يكتبه السكرتير، وهو رقم المريض.
      //   يُقترح تلقائياً أصغر رقم متاح اليوم في العيادة، فيكفي الضغط،
      //   ويُعاد الاقتراح بعد كل رفض برقم مستعمل.
      var suggested = 0;
      final doctorId = a.doctorId;
      if (doctorId != null && doctorId.isNotEmpty) {
        suggested = await DoctorService.instance.nextSerial(doctorId);
      }
      if (!mounted) return;
      final typed = await showDialog<int>(
        context: context,
        builder: (_) => _SerialDialog(
          patientName: a.patientName,
          initial: suggested,
          error: lastError,
        ),
      );
      if (!mounted) return;
      if (typed == null) {
        // إغلاق بعد محاولة فاشلة: نحدّث الشاشة من القاعدة قبل الخروج.
        if (lastError != null) await _load();
        return;
      }
      setState(() => _busy = a.id);
      final res = await DoctorService.instance.approve(a.id, typed);
      if (!mounted) return;
      setState(() => _busy = null);
      if (!res.ok) {
        lastError = res.error;
        // ★ لا تبقى الشاشة على حال قديم: القاعدة هي الحكم بعد كل محاولة.
        await _load();
        if (!mounted) return;
        final stillPending = _rows.any(
          (r) => r.id == a.id && r.status == 'pending',
        );
        if (!stillPending) {
          _toast('تمت الموافقة — حُدِّثت القائمة', true);
          return;
        }
        if (lastError.contains('انتهت الجلسة') ||
            lastError.contains('سجّل الدخول')) {
          _toast(lastError, false);
          return;
        }
        // الحوار يُعاد فاتحاً وبه سبب الرفض والرقم المتاح الجديد.
        continue;
      }
      if (res.already) {
        _toast('هذا الحجز موافَق عليه من قبل', true);
        await _load();
        return;
      }
      final serial = res.serial.isNotEmpty ? res.serial : '$typed';
      final fee = res.examFee > 0 ? res.examFee : a.examFee;
      // ★ الاستقطاع من ردّ القاعدة وحده (يحدده الأدمن)؛ لا نسبة مخترعة هنا.
      final commission = res.commission > 0 ? res.commission : 0;
      final net = res.netAmount > 0 ? res.netAmount : fee - commission;
      await _showApprovedDialog(
        serial: serial,
        fee: fee,
        commission: commission,
        net: net,
      );
      await _load();
      return;
    }
  }

  Future<void> _reject(DoctorAppointment a) async {
    if (_busy != null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'رفض الحجز',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'سيُبلَّغ المريض برفض الموعد، ولا تُقيَّد أي كشفية في محفظة '
          'الطبيب. هل ترفض هذا الحجز؟',
          style: GoogleFonts.cairo(
            fontSize: 13,
            height: 1.6,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'إلغاء',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'رفض',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = a.id);
    final res = await DoctorService.instance.reject(a.id);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    _toast(res.already ? 'الحجز مرفوض من قبل' : 'تم رفض الحجز', true);
    await _load();
  }

  /// ★ حوار الموافقة: الرقم مرة واحدة، والكشفية بجانبه — كما طلب
  ///   الأدمن. لا يُكرَّر الرقم في سطر ثانٍ.
  Future<void> _showApprovedDialog({
    required String serial,
    required int fee,
    required int commission,
    required int net,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(
          Icons.check_circle_rounded,
          color: AppColors.primary,
          size: 44,
        ),
        title: Text(
          'تمت الموافقة',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (serial.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'رقم الحجز $serial',
                  style: GoogleFonts.cairo(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              serial.isEmpty
                  ? 'وصل إشعار المريض بالموافقة.'
                  : 'وصل إشعار المريض برقم حجزه.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(
                children: [
                  Text(
                    'الكشفية ${CurrencyFormatter.format(fee)}',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'الاستقطاع: −${CurrencyFormatter.format(commission)}',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'صافي عند انتهاء المعاينة: ${CurrencyFormatter.format(net)}',
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'لا يُقيَّد شيء الآن — القيد يكون عند تأكيد انتهاء المعاينة.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(
              'حسناً',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  void _toast(String msg, bool ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _rows.where((a) => a.status == 'pending').toList();
    final history = _rows.where((a) => a.status != 'pending').toList();
    final showQueue = _queue.ok && _queue.clinics.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('موافقات الحجوزات'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          // ★ زر إدارة السكرتير للطبيب وحده — السكرتير لا يغيّر نفسه.
          if (AuthService.instance.isDoctor)
            IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DoctorSecretaryScreen(),
                  ),
                );
              },
              tooltip: 'سكرتير العيادة',
              icon: const Icon(Icons.support_agent_rounded),
            ),
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const DoctorAvailabilityScreen(),
                ),
              );
            },
            tooltip: 'حجز الزبائن',
            icon: const Icon(Icons.toggle_on_rounded),
          ),
          IconButton(
            onPressed: _load,
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_rows.isEmpty && !showQueue)
            ? _empty()
            : ListView(
                controller: tabScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  _DayStatsCard(stats: _dayStats),
                  const SizedBox(height: 10),
                  if (showQueue) ...[
                    const _SectionTitle(title: 'قائمة الانتظار الآن'),
                    const SizedBox(height: 8),
                    for (final c in _queue.clinics)
                      _QueueCard(
                        key: ValueKey<String>('queue:${c.doctorId}'),
                        clinic: c,
                        busy: _busy != null,
                        netPreview: _netFor(c.doctorId, 15000),
                        onCall: (item) => _callPatient(item),
                        onNext: () => _callNext(c),
                        onComplete: (item) => _completeVisit(item, c),
                        onDelete: (item) => _deleteWaiting(item),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if (pending.isNotEmpty) ...[
                    _SectionTitle(
                      title: 'بانتظار موافقتك',
                      count: pending.length,
                    ),
                    const SizedBox(height: 8),
                    for (final a in pending)
                      _AppointmentCard(
                        key: ValueKey<String>('pending:${a.id}'),
                        appointment: a,
                        clinic: a.doctorId == null ? null : _clinics[a.doctorId],
                        pendingApproval: true,
                        busy: _busy == a.id,
                        onApprove: () => _approve(a),
                        onReject: () => _reject(a),
                        onDetails: () => DoctorAppointmentDetails.show(
                          context,
                          appointment: a,
                          clinicView: true,
                        ),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if (history.isNotEmpty) ...[
                    const _SectionTitle(title: 'سجل الحجوزات'),
                    const SizedBox(height: 8),
                    for (final a in history)
                      _AppointmentCard(
                        key: ValueKey<String>('history:${a.id}'),
                        appointment: a,
                        clinic: a.doctorId == null ? null : _clinics[a.doctorId],
                        pendingApproval: false,
                        busy: false,
                        onDetails: () => DoctorAppointmentDetails.show(
                          context,
                          appointment: a,
                          clinicView: true,
                        ),
                      ),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
      ),
    );
  }

  Widget _empty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 90),
        Icon(
          _readFailed ? Icons.wifi_off_rounded : Icons.event_busy_rounded,
          size: 60,
          color: AppColors.textHint,
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            _readFailed
                ? (_failure.isEmpty
                      ? 'تعذّر جلب الحجوزات — تحقّق من الاتصال'
                      : _failure)
                : 'لا حجوزات في هذه العيادة بعد',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (!_readFailed)
          Center(
            child: Text(
              'عندما يحجز مريض عند الطبيب تصل هنا للموافقة برقم حجزه أو '
              'الرفض. رقم الحجز يُكتب عند الموافقة، والكشفية لا تُقيَّد في '
              'المحفظة إلا بعد زر «تأكيد انتهاء المعاينة».',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.textHint,
              ),
            ),
          ),
      ],
    );
  }
}

/// ★ قائمة انتظار العيادة: المستدعون الآن + المنتظرون، وأزرار
///   «استدعاء المريض» و«المريض التالي» و«تأكيد انتهاء المعاينة».
///
///   المال لا يتحرك من هنا إلا بزر «تأكيد انتهاء المعاينة»، والقاعدة
///   وحدها تقرر القيد مرة واحدة.
class _QueueCard extends StatelessWidget {
  const _QueueCard({
    super.key,
    required this.clinic,
    required this.busy,
    this.netPreview,
    this.onCall,
    this.onNext,
    this.onComplete,
    this.onDelete,
  });

  final DoctorQueueClinic clinic;
  final bool busy;
  final int? netPreview;
  final ValueChanged<DoctorQueueItem>? onCall;
  final VoidCallback? onNext;
  final ValueChanged<DoctorQueueItem>? onComplete;

  /// إلغاء انتظار مريض وحذف حجزه نهائياً (المنتظر وحده).
  final ValueChanged<DoctorQueueItem>? onDelete;

  @override
  Widget build(BuildContext context) {
    final calledList = clinic.calledList;
    final waiting = clinic.waiting;
    final net = netPreview;
    final nowItem = calledList.isEmpty ? null : calledList.first;
    final nextItem = waiting.isEmpty ? null : waiting.first;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: AppColors.primaryLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.groups_2_outlined,
                  size: 19,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  clinic.doctorName.isEmpty ? 'عيادة' : clinic.doctorName,
                  style: GoogleFonts.cairo(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                '${waiting.length} منتظر',
                style: GoogleFonts.cairo(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ★ دور مَن الآن (المستدعى) ودور مَن بعده (أول منتظر) — واضحان
          //   بلا حساب: شارة الرقم والاسم.
          Row(
            children: [
              Expanded(
                child: _TurnChip(
                  label: calledList.length > 1
                      ? 'الآن (+${calledList.length - 1})'
                      : 'الآن',
                  item: nowItem,
                  highlight: true,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _TurnChip(label: 'التالي', item: nextItem),
              ),
            ],
          ),
          const SizedBox(height: 10),

          for (final item in calledList) ...[
            _CalledBlock(
              item: item,
              netPreview: net,
              busy: busy,
              onComplete: onComplete,
            ),
            const SizedBox(height: 9),
          ],

          Row(
            children: [
              Expanded(
                child: Text(
                  waiting.isEmpty
                      ? 'لا أحد في الانتظار'
                      : (calledList.isEmpty
                          ? 'لا مريض في الكشف الآن'
                          : '${calledList.length} في الكشف · ${waiting.length} منتظر'),
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textHint,
                  ),
                ),
              ),
              if (waiting.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: busy ? null : onNext,
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  label: Text(
                    'المريض التالي',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
            ],
          ),

          for (final item in waiting) ...[
            const SizedBox(height: 9),
            Row(
              children: [
                SerialBadge(
                  serial: item.serialLabel.isEmpty ? '—' : item.serialLabel,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.patientName.isEmpty ? 'مريض' : item.patientName,
                        style: GoogleFonts.cairo(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        item.position <= 0
                            ? 'التالي'
                            : 'يسبقه ${item.position}',
                        style: GoogleFonts.cairo(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: busy ? null : () => onCall?.call(item),
                  icon: const Icon(Icons.campaign_rounded, size: 17),
                  label: Text(
                    'استدعاء المريض',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                IconButton(
                  onPressed: busy ? null : () => onDelete?.call(item),
                  tooltip: 'إلغاء الانتظار وحذف الحجز',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 19,
                    color: AppColors.danger,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// شارة «الآن / التالي» في بطاقة العيادة: رقم الدور واسم صاحبه مباشرةً.
class _TurnChip extends StatelessWidget {
  const _TurnChip({required this.label, this.item, this.highlight = false});

  final String label;
  final DoctorQueueItem? item;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final it = item;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: highlight ? AppColors.primaryLight : AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlight
              ? AppColors.primary.withValues(alpha: 0.35)
              : AppColors.divider,
        ),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: highlight ? AppColors.primary : AppColors.textHint,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: it == null
                ? Text(
                    'لا أحد',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textHint,
                    ),
                  )
                : Row(
                    children: [
                      SerialBadge(
                        serial: it.serialLabel.isEmpty ? '—' : it.serialLabel,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          it.patientName.isEmpty ? 'مريض' : it.patientName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
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
}

/// بطاقة مريض مستدعى — تُعرض لكل مستدعى، فقد يكون أكثر من واحد
/// في الكشف في الوقت نفسه (استدعاء متعدد).
class _CalledBlock extends StatelessWidget {
  const _CalledBlock({
    required this.item,
    required this.busy,
    this.netPreview,
    this.onComplete,
  });

  final DoctorQueueItem item;
  final bool busy;
  final int? netPreview;
  final ValueChanged<DoctorQueueItem>? onComplete;

  @override
  Widget build(BuildContext context) {
    final net = netPreview;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SerialBadge(
                serial: item.serialLabel.isEmpty ? '—' : item.serialLabel,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.patientName.isEmpty
                          ? 'المريض المستدعى'
                          : item.patientName,
                      style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: AppColors.primaryDark,
                      ),
                    ),
                    Text(
                      'في الكشف الآن',
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          FilledButton.icon(
            onPressed: busy ? null : () => onComplete?.call(item),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.task_alt_rounded, size: 18),
            label: Text(
              net == null
                  ? 'تأكيد انتهاء المعاينة'
                  : 'تأكيد انتهاء المعاينة · يُقيَّد ${CurrencyFormatter.format(net)}',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ★ «إحصائيات اليوم» — أرقام العيادة من القاعدة (سكرتير/طبيب/ممرض
///   يقرؤون نفس الأرقام): المراجعون الآن، المكتمل، المرفوض.
///   كل حجز يُعدّ في خانة واحدة بحسب حالته — لا تكرار.
class _DayStatsCard extends StatelessWidget {
  const _DayStatsCard({required this.stats});

  final DoctorDayStats stats;

  @override
  Widget build(BuildContext context) {
    if (!stats.ok) {
      return Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.insights_rounded,
              size: 18,
              color: AppColors.textHint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'إحصائيات اليوم غير مثبّتة على الخادم بعد — شغّل '
                'SQL_DOCTOR_DAY_STATS.sql ثم اسحب للتحديث.',
                style: GoogleFonts.cairo(
                  fontSize: 11.5,
                  height: 1.6,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textHint,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final multi = stats.clinics.length > 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.insights_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 7),
              Text(
                'إحصائيات اليوم',
                style: GoogleFonts.cairo(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${stats.called} في الكشف · ${stats.waiting} منتظر',
                style: GoogleFonts.cairo(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textHint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  value: stats.current,
                  label: 'المراجعون الآن',
                  icon: Icons.groups_2_rounded,
                  color: AppColors.primary,
                  bg: AppColors.primaryLight,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatTile(
                  value: stats.done,
                  label: 'مكتمل اليوم',
                  icon: Icons.task_alt_rounded,
                  color: AppColors.success,
                  bg: AppColors.success.withValues(alpha: 0.12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatTile(
                  value: stats.rejected,
                  label: 'مرفوض اليوم',
                  icon: Icons.block_rounded,
                  color: AppColors.danger,
                  bg: AppColors.danger.withValues(alpha: 0.10),
                ),
              ),
            ],
          ),
          if (multi) ...[
            const SizedBox(height: 10),
            Container(height: 1, color: AppColors.divider),
            const SizedBox(height: 8),
            for (final c in stats.clinics)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.doctorName.isEmpty ? 'عيادة' : c.doctorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    Text(
                      '${c.current} الآن · ${c.done} مكتمل · '
                      '${c.rejected} مرفوض',
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 6),
          Text(
            'كل حجز يُحتسب مرة واحدة بحسب حالته — اليوم من منتصف ليل بغداد.',
            style: GoogleFonts.cairo(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.textHint,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    required this.bg,
  });

  final int value;
  final String label;
  final IconData icon;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(height: 3),
          Text(
            '$value',
            style: GoogleFonts.cairo(
              fontSize: 20,
              height: 1.1,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.cairo(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: GoogleFonts.cairo(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count',
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: AppColors.accentDeep,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// ★ حوار «أي رقم حجز متوفر؟» — يفتح قبل الموافقة، ولا تُرسل الموافقة
///   بلا رقم صحيح. الرقم الذي يُكتب هو الذي يراه المريض في إشعاره.
class _SerialDialog extends StatefulWidget {
  const _SerialDialog({
    required this.patientName,
    this.initial = 0,
    this.error,
  });

  final String patientName;
  /// رقم مقترح من القاعدة (٠ = لا اقتراح).
  final int initial;
  /// سبب رفض المحاولة السابقة — يُعرض أعلى الحقل.
  final String? error;

  @override
  State<_SerialDialog> createState() => _SerialDialogState();
}

class _SerialDialogState extends State<_SerialDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    if (widget.initial > 0) {
      _ctrl.text = '${widget.initial}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String? _validate(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n <= 0 || n > 9999999) {
      return 'اكتب رقماً صحيحاً أكبر من صفر';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      icon: const Icon(
        Icons.confirmation_number_outlined,
        color: AppColors.primary,
        size: 40,
      ),
      title: Text(
        'رقم الحجز',
        textAlign: TextAlign.center,
        style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
      ),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    height: 1.5,
                    color: AppColors.danger,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              'اكتب رقم حجز هذه العيادة'
              '${widget.patientName.isEmpty ? '' : ' للمريض ${widget.patientName}'}. '
              'يبدأ العدّاد من #1 كل يوم، ولا يتكرر في حجز آخر من نفس '
              'العيادة اليوم.'
              '${widget.initial > 0 ? ' الرقم المُقترح ${widget.initial} هو أصغر رقم متاح الآن.' : ''}',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              textInputAction: TextInputAction.done,
              style: GoogleFonts.cairo(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'مثال: 55',
                hintStyle: GoogleFonts.cairo(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textHint,
                ),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
              ),
              validator: _validate,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'إلغاء',
            style: GoogleFonts.cairo(
              fontWeight: FontWeight.w800,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: Text(
            'موافقة',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  void _submit() {
    if (_form.currentState?.validate() != true) return;
    Navigator.of(context).pop(int.parse(_ctrl.text.trim()));
  }
}

/// بطاقة الحجز عند السكرتير: الرقم مرة واحدة في الشارة، والكشفية في
/// سطرها الخاص. أزرار الموافقة/الرفض للمنتظر وحده.
class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({
    super.key,
    required this.appointment,
    required this.pendingApproval,
    required this.busy,
    this.clinic,
    this.onApprove,
    this.onReject,
    this.onDetails,
  });

  final DoctorAppointment appointment;
  final bool pendingApproval;
  final bool busy;
  /// عيادة الحجز واستقطاعها الحالي — المصدر الوحيد لصافي البطاقة.
  final ClinicWallet? clinic;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onDetails;

  /// صافي ما سيُقيَّد في المحفظة عند تأكيد انتهاء المعاينة، بنفس حساب
  /// القاعدة: نسبة من الكشفية أو مبلغ ثابت، والاستقطاع لا يتجاوز الكشفية.
  String get _pendingNetText {
    final c = clinic;
    if (c == null) return 'يُقيَّد بعد المعاينة';
    final fee = appointment.examFee;
    final cut = c.deductionMethod == DeductionMethod.percent
        ? (fee * c.deductionValue / 100).round()
        : c.deductionValue.round();
    final net = fee - (cut > fee ? fee : cut);
    return 'يُقيَّد ${CurrencyFormatter.format(net)} بعد المعاينة';
  }

  @override
  Widget build(BuildContext context) {
    final a = appointment;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: pendingApproval
              ? AppColors.warning.withValues(alpha: 0.55)
              : AppColors.divider,
        ),
      ),
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
                            pendingApproval ? 'حجز جديد' : 'حجز دكتور/ة',
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
              _Row(icon: Icons.person_outline_rounded, label: 'المريض', value: a.patientName),
              _Row(icon: Icons.badge_outlined, label: 'الدكتور', value: a.doctorName),
              _Row(icon: Icons.category_outlined, label: 'التخصص', value: a.specialty),
              _Row(icon: Icons.event_available_outlined, label: 'الموعد', value: a.whenLabel),
              _Row(icon: Icons.phone_outlined, label: 'هاتف المريض', value: a.contactPhone),
              if (a.address.isNotEmpty)
                _Row(icon: Icons.location_on_outlined, label: 'الموقع', value: a.address),

              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.payments_outlined,
                      size: 18,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'الكشفية ${CurrencyFormatter.format(a.examFee)}',
                        style: GoogleFonts.cairo(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ),
                    Text(
                      pendingApproval
                          ? _pendingNetText
                          : (a.isRejected
                                ? 'مرفوض — بلا كشفية'
                                : a.isDone
                                ? 'مقيَّد في محفظة العيادة'
                                : 'يُقيَّد عند انتهاء المعاينة'),
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: a.contactPhone.isEmpty
                          ? null
                          : () => ContactTools.callCustomer(
                              context,
                              a.contactPhone,
                            ),
                      icon: const Icon(Icons.call_rounded, size: 17),
                      label: Text(
                        'اتصال بالمريض',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.45),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => MapLauncher.show(
                        context,
                        latitude: a.latitude,
                        longitude: a.longitude,
                        address: a.address,
                      ),
                      icon: const Icon(Icons.map_outlined, size: 17),
                      label: Text(
                        'الموقع',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.45),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              if (pendingApproval) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : onReject,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: Text(
                          'رفض',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          side: BorderSide(
                            color: AppColors.danger.withValues(alpha: 0.5),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: busy ? null : onApprove,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_rounded, size: 19),
                        label: Text(
                          'موافقة',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                      ),
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

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.value});

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
