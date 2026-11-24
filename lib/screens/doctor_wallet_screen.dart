import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ «محفظة العيادة» — كشفيات الحجوزات الموافَق عليها، للطبيب وسكرتيره.
///
///   كل قيد هنا كتبته `doctor_appointment_approve` داخل القاعدة عند
///   الموافقة على الحجز: الكشفية 15,000، يُخصم منها استقطاع ثابت 500
///   دينار لكل حجز (بلا نسبة مئوية)، ويُقيَّد الصافي 14,500 — قيد واحد
///   لا يتكرر (مفتاح فريد على معرّف الحجز). الشاشة تقرأ
///   `my_doctor_wallet` التي تعزل برقم الجلسة، فلا حساب يقرأ محفظة
///   عيادة غيره.
///
///   التصفير **يدوي من الأدمن وحده**؛ هذه الشاشة تقرأ فقط.
class DoctorWalletScreen extends StatefulWidget {
  const DoctorWalletScreen({super.key});

  @override
  State<DoctorWalletScreen> createState() => _DoctorWalletScreenState();
}

class _DoctorWalletScreenState extends State<DoctorWalletScreen>
    with TabRefreshTarget<DoctorWalletScreen> {
  /// تبويب «محفظتي» في واجهة الطبيب: النقرة تعيد جلب المحفظة.
  @override
  String get tabId => 'clinic_wallet';

  @override
  Future<void> Function() onTabRefresh() => _load;

  DoctorWallet? _wallet;
  bool _loading = true;
  bool _readFailed = false;
  String _failure = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final wallet = await DoctorService.instance.wallet();
    if (!mounted) return;
    final why = (SupabaseService.instance.lastRpcError ?? '').trim();
    setState(() {
      _loading = false;
      _wallet = wallet;
      _readFailed = wallet == null && why.isNotEmpty;
      _failure = _readFailed ? why : '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('محفظة العيادة'),
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
            : ListView(
                controller: tabScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _BalanceCard(wallet: _wallet),
                  const SizedBox(height: 18),
                  ..._clinics(),
                  const SizedBox(height: 8),
                  _footerNote(),
                  const SizedBox(height: 20),
                ],
              ),
      ),
    );
  }

  List<Widget> _clinics() {
    final wallets = _wallet?.wallets ?? const <ClinicWallet>[];
    if (wallets.isEmpty) return [_empty()];
    final out = <Widget>[];
    for (final w in wallets) {
      out.add(
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w.doctorName.isEmpty ? 'عيادة' : w.doctorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  // كل الأرقام أعلاه من هذه اللحظة: التصفير يقطع الخط
                  // الزمني، فلا يظهر في الحساب أي مبلغ قبله.
                  if (w.resetAt != null)
                    Text(
                      'منذ آخر تصفير: ${_dayLabel(w.resetAt!)}',
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textHint,
                      ),
                    ),
                ],
              ),
            ),
            _RoleChip(
              label: w.isDoctor && w.isSecretary
                  ? 'طبيب وسكرتير'
                  : (w.isDoctor ? 'طبيب' : 'سكرتير'),
            ),
            const SizedBox(width: 8),
            Text(
              'المستحق ${CurrencyFormatter.format(w.balance)}',
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      );
      out.add(const SizedBox(height: 8));
      if (w.entries.isEmpty) {
        out.add(
          Container(
            padding: const EdgeInsets.all(18),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              'لا كشفيات مقيَّدة لهذه العيادة بعد.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        );
      } else {
        for (final e in w.entries) {
          out.add(_EntryTile(entry: e));
        }
        out.add(const SizedBox(height: 8));
      }
    }
    return out;
  }

  Widget _empty() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Icon(
            _readFailed ? Icons.wifi_off_rounded : Icons.receipt_long_outlined,
            size: 42,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 10),
          Text(
            _readFailed
                ? (_failure.isEmpty
                      ? 'تعذّر جلب المحفظة — تحقّق من الاتصال'
                      : _failure)
                : 'لا كشفيات مقيَّدة بعد',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
          if (!_readFailed) ...[
            const SizedBox(height: 6),
            Text(
              'تُقيَّد الكشفية في المحفظة عند موافقة العيادة على الحجز، '
              'بعد خصم ثابت 500 دينار لكل حجز.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                height: 1.6,
                color: AppColors.textHint,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footerNote() {
    if (_wallet == null || _wallet!.wallets.isEmpty) return const SizedBox();
    return Row(
      children: [
        const Icon(
          Icons.lock_outline_rounded,
          size: 15,
          color: AppColors.textHint,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'التصفير يتم يدوياً من لوحة الأدمن فقط؛ الكشفيات تبقى مسجّلة هنا.',
            style: GoogleFonts.cairo(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.textHint,
            ),
          ),
        ),
      ],
    );
  }

  /// تاريخ يوم التصفير وحده — بلا ساعة: السطر سطر توضيحي لا إيصال.
  static String _dayLabel(DateTime at) {
    final d = at.day.toString().padLeft(2, '0');
    final m = at.month.toString().padLeft(2, '0');
    return '$d/$m/${at.year}';
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.cairo(
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          color: AppColors.primaryDark,
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.wallet});

  final DoctorWallet? wallet;

  @override
  Widget build(BuildContext context) {
    final balance = wallet?.balance ?? 0;
    final gross = wallet?.gross ?? 0;
    final commission = wallet?.commission ?? 0;
    final net = wallet?.net ?? 0;
    final paid = wallet?.paid ?? 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.navyCardGradient,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.account_balance_wallet_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'المستحق في المحفظة',
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'الصافي بعد خصم 500 دينار لكل حجز',
                      style: GoogleFonts.cairo(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            CurrencyFormatter.format(balance),
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _TotalLine(label: 'الكشفيات', value: gross),
              _TotalLine(label: 'الاستقطاع الثابت', value: commission),
              _TotalLine(label: 'الصافي', value: net),
              _TotalLine(label: 'صُرف بالتصفير', value: paid),
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
  final int value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: ${CurrencyFormatter.format(value)}',
      style: GoogleFonts.cairo(
        color: Colors.white.withValues(alpha: 0.9),
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final DoctorWalletEntry entry;

  @override
  Widget build(BuildContext context) {
    final gross = entry.grossAmount > 0 ? entry.grossAmount : entry.amount;
    final commission = entry.commission;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.payments_outlined,
              color: AppColors.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.note.isEmpty ? 'كشفية حجز' : entry.note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  commission > 0
                      ? 'الكشفية ${CurrencyFormatter.format(gross)}'
                            ' · استقطاع ${CurrencyFormatter.format(commission)}'
                      : 'الكشفية ${CurrencyFormatter.format(gross)}',
                  style: GoogleFonts.cairo(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textHint,
                  ),
                ),
                if (entry.createdAt != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    _stamp(entry.createdAt!),
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '+${CurrencyFormatter.format(entry.amount)}',
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
              Text(
                'الصافي',
                style: GoogleFonts.cairo(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textHint,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime at) {
    final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final period = at.hour < 12 ? 'ص' : 'م';
    return '${at.year}-${_two(at.month)}-${_two(at.day)}'
        ' · ${_two(h)}:${_two(at.minute)} $period';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
