import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/map_launcher.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/doctor_appointment_card.dart';
import '../widgets/doctor_appointment_details.dart';
import 'doctor_availability_screen.dart';

/// ★ «موافقات الحجوزات» — شاشة سكرتير العيادة والطبيب.
///
///   طلب الأدمن (11-19): «إذا مريض يطلب حجز دكتور يظهر إشعار خارجي
///   وداخل التطبيق للسكرتير … موافقة أو رفض … إذا وافق السكرتير يظهر
///   رقم الحجز بدون تكرار واضح مع سعر الكشفية 15,000».
///
///   كل شيء هنا من `doctor_appointments_for_secretary` التي تعزل برقم
///   الجلسة داخل القاعدة (`doctors.secretary_phone` أو `doctors.phone`)،
///   فلا شاشة تقرأ حجوزات عيادة غيرها. الكشفية تُقيَّد في محفظة الطبيب
///   **من داخل `doctor_appointment_approve`** عند الموافقة وحدها، والشاشة
///   تقرأ ما رجع من الخادم ولا تتوقع مالاً بنفسها.
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
    if (!mounted) return;
    // الفراغ الحقيقي ردّ 2xx بلا صفوف؛ أي سبب آخر (شبكة أو دالة غير
    // مثبّتة) يُقال بنصّه ولا يُغطّى بكلمة «لا حجوزات».
    final why = (SupabaseService.instance.lastRpcError ?? '').trim();
    setState(() {
      _loading = false;
      _rows = list;
      _readFailed = list.isEmpty && why.isNotEmpty;
      _failure = _readFailed ? why : '';
    });
  }

  Future<void> _approve(DoctorAppointment a) async {
    if (_busy != null) return;
    // ★ الرقم أولاً: لا موافقة بلا رقم يكتبه السكرتير، وهو رقم المريض.
    final typed = await showDialog<int>(
      context: context,
      builder: (_) => _SerialDialog(patientName: a.patientName),
    );
    if (!mounted || typed == null) return;
    setState(() => _busy = a.id);
    final res = await DoctorService.instance.approve(a.id, typed);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    if (res.already) {
      _toast('هذا الحجز موافَق عليه من قبل', true);
      await _load();
      return;
    }
    final serial = res.serial.isNotEmpty ? res.serial : '$typed';
    final fee = res.examFee > 0 ? res.examFee : a.examFee;
    final commission = res.commission > 0
        ? res.commission
        : (fee > 0 ? fee ~/ 10 : 0);
    final net = res.netAmount > 0 ? res.netAmount : fee - commission;
    await _showApprovedDialog(
      serial: serial,
      fee: fee,
      commission: commission,
      net: net,
    );
    await _load();
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
                    'استقطاع ثابت 500 دينار: −${CurrencyFormatter.format(commission)}',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'صافي محفظة العيادة: ${CurrencyFormatter.format(net)}',
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: AppColors.primary,
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

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('موافقات الحجوزات'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
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
            : _rows.isEmpty
            ? _empty()
            : ListView(
                controller: tabScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
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
              'الرفض. عند الموافقة تُكتب الكشفية 15,000 د.ع ويُخصم منها '
              'استقطاع ثابت 500 دينار، ويُقيَّد الصافي في محفظة العيادة.',
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
  const _SerialDialog({required this.patientName});

  final String patientName;

  @override
  State<_SerialDialog> createState() => _SerialDialogState();
}

class _SerialDialogState extends State<_SerialDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

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
            Text(
              widget.patientName.isEmpty
                  ? 'اكتب أي رقم حجز متوفر. سيظهر للمريض في إشعار الموافقة، '
                        'ولا يتكرر في حجز آخر.'
                  : 'اكتب أي رقم حجز متوفر للمريض '
                        '${widget.patientName}. سيظهر في إشعار الموافقة، '
                        'ولا يتكرر في حجز آخر.',
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
    this.onApprove,
    this.onReject,
    this.onDetails,
  });

  final DoctorAppointment appointment;
  final bool pendingApproval;
  final bool busy;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onDetails;

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
                          ? 'صافي المحفظة '
                                '${CurrencyFormatter.format(a.examFee - (a.examFee ~/ 10))}'
                          : (a.isRejected
                                ? 'مرفوض — بلا كشفية'
                                : 'مقيَّد في محفظة العيادة'),
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
