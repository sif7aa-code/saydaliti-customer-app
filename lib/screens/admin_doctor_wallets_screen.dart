import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/deduction_label.dart';
import '../services/admin_password_session.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ محافظ الأطباء (الأدمن): لكل عيادة كشفياتها كاملة، الاستقطاع الذي
///   حدده الأدمن (ثابت أو نسبة)، الصافي، المصروف بالتصفير، والمستحق الآن.
///
///   كل الأرقام من `admin_list_doctor_wallets()` المحمية بالأدمن. التصفير
///   **يدوي من هذه الشاشة وحدها**: يسجّل «صرفاً» بقيمة المستحق فيصبح
///   الرصيد صفراً في كل الواجهات، ولا يُحذف قيد واحد من الدفتر.
class AdminDoctorWalletsScreen extends StatefulWidget {
  const AdminDoctorWalletsScreen({super.key});

  @override
  State<AdminDoctorWalletsScreen> createState() =>
      _AdminDoctorWalletsScreenState();
}

class _AdminDoctorWalletsScreenState extends State<AdminDoctorWalletsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];
  Map<String, dynamic> _totals = const {};

  final Set<String> _expanded = {};
  final Map<String, List<Map<String, dynamic>>> _payouts = {};
  final Set<String> _payoutsLoading = {};
  final Set<String> _resetting = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final items = await SupabaseService.instance.adminListDoctorWallets();
    if (!mounted) return;
    setState(() {
      _items = items ?? const [];
      _totals = items == null
          ? const {}
          : SupabaseService.instance.lastAdminDoctorWalletTotals;
      _error = items == null
          ? (SupabaseService.instance.lastAdminDoctorWalletError ??
                'تعذّر التحميل')
          : null;
      _loading = false;
    });
    for (final id in _expanded) {
      await _loadPayouts(id, force: true);
    }
  }

  Future<void> _loadPayouts(String doctorId, {bool force = false}) async {
    if (!force && _payouts.containsKey(doctorId)) return;
    if (!mounted) return;
    setState(() => _payoutsLoading.add(doctorId));
    final rows = await SupabaseService.instance.adminDoctorPayouts(doctorId);
    if (!mounted) return;
    setState(() {
      _payoutsLoading.remove(doctorId);
      if (rows != null) _payouts[doctorId] = rows;
    });
  }

  void _toast(String msg, {bool ok = true}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.primary : AppColors.danger,
        ),
      );
  }

  /// ★ تصفير رصيد عيادة — الأدمن فقط بكلمة مرور اللوحة.
  Future<void> _resetWallet(Map<String, dynamic> item) async {
    final doctorId = item['id']?.toString() ?? '';
    if (doctorId.isEmpty) return;
    final due = (item['due'] as num?)?.toDouble() ?? 0;
    if (due <= 0) {
      _toast('رصيد هذه العيادة صفر أصلاً');
      return;
    }
    final name = item['name']?.toString() ?? '';

    // كلمة المرور من الجلسة إن كُتبت سابقاً في هذا الفتح للتطبيق.
    final cachedPw = AdminPasswordSession.cached;
    final hasCached = (cachedPw ?? '').isNotEmpty;

    final pwCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تصفير رصيد العيادة',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name.isEmpty ? '' : 'العيادة: $name\n',
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'سيُسجَّل أنك صرفت ${CurrencyFormatter.format(due)} '
              'فيصبح الرصيد صفراً، ويبدأ الحساب من جديد من هذه اللحظة.\n'
              'لا يُحذف أي قيد من الدفتر — تبقى معرفة كم استحقت العيادة '
              'وكم صُرف لها.',
              style: GoogleFonts.cairo(fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: noteCtrl,
              decoration: InputDecoration(
                labelText: 'ملاحظة (اختياري)',
                labelStyle: GoogleFonts.cairo(),
                border: const OutlineInputBorder(),
              ),
              style: GoogleFonts.cairo(),
            ),
            if (!hasCached) ...[
              const SizedBox(height: 12),
              TextField(
                controller: pwCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'كلمة مرور الأدمن',
                  labelStyle: GoogleFonts.cairo(),
                  border: const OutlineInputBorder(),
                ),
                style: GoogleFonts.cairo(),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text('تصفير', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      pwCtrl.dispose();
      noteCtrl.dispose();
      return;
    }

    final password = hasCached ? cachedPw! : pwCtrl.text.trim();
    final note = noteCtrl.text.trim();
    pwCtrl.dispose();
    noteCtrl.dispose();
    if (password.isEmpty) {
      _toast('كلمة مرور الأدمن مطلوبة', ok: false);
      return;
    }
    if (!hasCached) AdminPasswordSession.remember(password);

    if (!mounted) return;
    setState(() => _resetting.add(doctorId));
    final res = await SupabaseService.instance.adminResetDoctorWallet(
      doctorId,
      password,
      note: note,
    );
    if (!mounted) return;
    setState(() => _resetting.remove(doctorId));

    if (res == null) {
      _toast('فشل: تعذّر الاتصال أو تعذّر تنفيذ التصفير على الخادم', ok: false);
      return;
    }
    if (res['ok'] != true) {
      _toast('${res['error'] ?? 'تعذّر التصفير'}', ok: false);
      return;
    }
    if (res['reset'] == true) {
      final paid = (res['paid_now'] as num?)?.toDouble() ?? due;
      _toast(
        paid > 0
            ? 'تم التصفير — سُجّل صرف ${CurrencyFormatter.format(paid)} '
                  'وبدأ الحساب من الصفر'
            : 'تم التصفير — بدأ الحساب من الصفر',
      );
    } else {
      _toast('${res['message'] ?? 'لا يوجد رصيد للتصفير'}');
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'محافظ الأطباء',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
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
            : _error != null
            ? _errorView()
            : _items.isEmpty
            ? _emptyView()
            : Column(
                children: [
                  _TotalsStrip(totals: _totals, items: _items),
                  Expanded(
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final item = _items[i];
                        final id = item['id']?.toString() ?? '';
                        return _ClinicWalletCard(
                          item: item,
                          expanded: _expanded.contains(id),
                          payouts: _payouts[id],
                          payoutsLoading: _payoutsLoading.contains(id),
                          resetting: _resetting.contains(id),
                          onToggle: () {
                            if (id.isEmpty) return;
                            setState(() {
                              if (!_expanded.remove(id)) _expanded.add(id);
                            });
                            if (_expanded.contains(id)) _loadPayouts(id);
                          },
                          onReset: () => _resetWallet(item),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _errorView() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 140),
        const Icon(
          Icons.local_hospital_outlined,
          size: 64,
          color: AppColors.textHint,
        ),
        const SizedBox(height: 12),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            onPressed: () => AppRefresh.run(_load),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(
              'إعادة المحاولة',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyView() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 140),
        const Icon(
          Icons.account_balance_wallet_outlined,
          size: 64,
          color: AppColors.textHint,
        ),
        const SizedBox(height: 12),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              'لا كشفيات مقيَّدة لعيادة بعد',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'تُقيَّد الكشفية عند موافقة العيادة على الحجز',
            style: GoogleFonts.cairo(
              color: AppColors.textHint,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ClinicWalletCard extends StatelessWidget {
  const _ClinicWalletCard({
    required this.item,
    required this.expanded,
    required this.payouts,
    required this.payoutsLoading,
    required this.resetting,
    required this.onToggle,
    required this.onReset,
  });

  final Map<String, dynamic> item;
  final bool expanded;
  final List<Map<String, dynamic>>? payouts;
  final bool payoutsLoading;
  final bool resetting;
  final VoidCallback onToggle;
  final VoidCallback onReset;

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _day(DateTime at) =>
      '${_two(at.day)}/${_two(at.month)}/${at.year}';

  @override
  Widget build(BuildContext context) {
    final phone = item['phone']?.toString() ?? '';
    final secretaryPhone = item['secretary_phone']?.toString() ?? '';
    final orders = (item['orders'] as num?)?.toInt() ?? 0;
    final gross = (item['gross'] as num?)?.toDouble() ?? 0;
    final commission = (item['commission'] as num?)?.toDouble() ?? 0;
    final net = (item['net'] as num?)?.toDouble() ?? 0;
    final paid = (item['paid'] as num?)?.toDouble() ?? 0;
    final due = (item['due'] as num?)?.toDouble() ?? 0;
    final rule = deductionText(
      deductionMethodOf(item['commission_method']),
      (item['commission_value'] as num?)?.toDouble() ?? 0,
      unit: 'حجز',
    );
    final overpaid = paid > net ? paid - net : 0.0;
    final resetAt = DateTime.tryParse(
      item['reset_at']?.toString() ?? '',
    )?.toLocal();

    return Card(
      elevation: 1.5,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                    child: const Icon(
                      Icons.local_hospital_rounded,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['name']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w900,
                            fontSize: 14.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (phone.isNotEmpty)
                          Text(
                            'الطبيب: $phone',
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              color: AppColors.textHint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (secretaryPhone.isNotEmpty)
                          Text(
                            'السكرتير: $secretaryPhone',
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              color: AppColors.textHint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        // الأرقام المحسوبة أدناه كلها بعد آخر تصفير فقط.
                        if (resetAt != null)
                          Text(
                            'منذ آخر تصفير: ${_day(resetAt)}',
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              color: AppColors.textHint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  _DueBadge(due: due, overpaid: overpaid),
                  const SizedBox(width: 6),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: AppColors.textHint,
                  ),
                ],
              ),
              // ★ السعر والاستقطاع مرئيّان دائماً (بلا توسيع): الكشفيات،
              //   الاستقطاع المفروض (ثابت أو نسبة كما ضبطه الأدمن)، ثم
              //   الصافي — والمستحق في الشارة أعلى البطاقة.
              const SizedBox(height: 6),
              Text(
                'الكشفيات ${CurrencyFormatter.format(gross)}  ·  '
                'الاستقطاع ${CurrencyFormatter.format(commission)} ($rule)'
                '  ·  الصافي ${CurrencyFormatter.format(net)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.cairo(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textHint,
                ),
              ),
              if (expanded) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    _StatBox(
                      icon: Icons.receipt_long_rounded,
                      label: 'حجوزات',
                      value: '$orders',
                    ),
                    _StatBox(
                      icon: Icons.payments_outlined,
                      label: 'الكشفيات',
                      value: CurrencyFormatter.format(gross),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _StatBox(
                      icon: Icons.remove_circle_outline_rounded,
                      label: 'الاستقطاع',
                      value: CurrencyFormatter.format(commission),
                    ),
                    _StatBox(
                      icon: Icons.savings_outlined,
                      label: 'الصافي',
                      value: CurrencyFormatter.format(net),
                    ),
                    _StatBox(
                      icon: Icons.done_all_rounded,
                      label: 'صُرف',
                      value: CurrencyFormatter.format(paid),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _PayoutsLog(payouts: payouts, loading: payoutsLoading),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (due <= 0 || resetting) ? null : onReset,
                    icon: resetting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.restart_alt_rounded, size: 18),
                    label: Text(
                      due <= 0 ? 'الرصيد صفر' : 'تصفير الرصيد إلى صفر',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DueBadge extends StatelessWidget {
  const _DueBadge({required this.due, required this.overpaid});

  final double due;
  final double overpaid;

  @override
  Widget build(BuildContext context) {
    final (color, label) = due > 0
        ? (AppColors.danger, 'مستحق ${CurrencyFormatter.format(due)}')
        : overpaid > 0
        ? (AppColors.warning, 'صُرف أكثر')
        : (AppColors.brand, 'صفر');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.cairo(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.info.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.info, size: 16),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              label,
              style: GoogleFonts.cairo(
                fontSize: 9.5,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// سجل الصرف: كل سطر «مبلغ + ملاحظة + تاريخ». تُجلب عند التوسيع.
class _PayoutsLog extends StatelessWidget {
  const _PayoutsLog({required this.payouts, required this.loading});

  final List<Map<String, dynamic>>? payouts;
  final bool loading;

  String _dateLabel(Object? raw) {
    final s = raw?.toString() ?? '';
    final dt = DateTime.tryParse(s);
    if (dt == null) return s.length >= 10 ? s.substring(0, 10) : s;
    final local = dt.toLocal();
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$d/$m/${local.year} $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    final rows = payouts ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) {
      return Text(
        'لا يوجد صرف مسجّل بعد',
        style: GoogleFonts.cairo(
          fontSize: 11.5,
          color: AppColors.textHint,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'سجل الصرف (${rows.length})',
          style: GoogleFonts.cairo(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        for (final p in rows)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.payments_outlined,
                  size: 16,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (p['note']?.toString().trim().isNotEmpty ?? false)
                        ? p['note'].toString()
                        : 'صرف',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  CurrencyFormatter.format(
                    (p['amount'] as num?)?.toDouble() ?? 0,
                  ),
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _dateLabel(p['created_at']),
                  style: GoogleFonts.cairo(
                    fontSize: 10,
                    color: AppColors.textHint,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// شريط الحصيلة أعلى القائمة — من نفس رد الخادم الذي تُرسم منه البطاقات.
class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals, required this.items});

  final Map<String, dynamic> totals;
  final List<Map<String, dynamic>> items;

  static double _num(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final hasServer = totals.isNotEmpty;
    final gross = hasServer
        ? _num(totals, 'total_gross')
        : items.fold<double>(0, (s, e) => s + _num(e, 'gross'));
    final commission = hasServer
        ? _num(totals, 'total_commission')
        : items.fold<double>(0, (s, e) => s + _num(e, 'commission'));
    final net = hasServer
        ? _num(totals, 'total_net')
        : items.fold<double>(0, (s, e) => s + _num(e, 'net'));
    final paid = hasServer
        ? _num(totals, 'total_paid')
        : items.fold<double>(0, (s, e) => s + _num(e, 'paid'));
    final due = hasServer
        ? _num(totals, 'total_due')
        : items.fold<double>(0, (s, e) => s + _num(e, 'due'));
    final doctors = hasServer
        ? _num(totals, 'doctors').toInt()
        : items.length;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: AppColors.navyCardGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_balance_wallet_rounded,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'حصيلة محافظ الأطباء',
                style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                '$doctors عيادة',
                style: GoogleFonts.cairo(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'المستحق الآن: ${CurrencyFormatter.format(due)}',
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: [
              _TotalLine(label: 'الكشفيات', value: gross),
              _TotalLine(label: 'الاستقطاعات', value: commission),
              _TotalLine(label: 'الصافي', value: net),
              _TotalLine(label: 'صُرف', value: paid),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: ${CurrencyFormatter.format(value)}',
      style: GoogleFonts.cairo(
        color: Colors.white.withValues(alpha: 0.9),
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}
