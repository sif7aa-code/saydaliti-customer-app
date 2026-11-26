import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/deduction_label.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ محفظة التاجر — الرصيد الحقيقي **بعد** قِص الاستقطاع الذي حدده الأدمن.
///
/// ★ ليس مجموع مبيعاته: `balance` = `net` أي مبيعاته المسلَّمة بعد
///   استقطاع (ثابت أو نسبة — يضبطه الأدمن لكل صيدلية) لكل طلب
///   **خاص به هو**. عرض 100% كان يقول له إن له أكثر مما له فعلاً.
class ShopWalletScreen extends StatefulWidget {
  const ShopWalletScreen({super.key, this.ownerPhone, this.title});

  /// ★ هاتف صاحب الصيدلية المطلوب عرض محفظته.
  ///   `null` = صاحب هذا الحساب نفسه (تبويب «محفظتي» في واجهة الصيدلية).
  ///   ومن لوحة الأدمن نمرر هاتف صاحب الصيدلية: الأدمن يُستثنى من واجهة
  ///   صاحب الصيدلية في `app.dart`، فبدون هذه البوابة لا يرى المحفظة
  ///   الكاملة (سجل الطلبات) في أي مكان.
  final String? ownerPhone;

  /// عنوان الشاشة: «محفظتي» عند التاجر، وعنوان مخصّص من لوحة الأدمن.
  final String? title;

  @override
  State<ShopWalletScreen> createState() => _ShopWalletScreenState();
}

class _ShopWalletScreenState extends State<ShopWalletScreen>
    with TabRefreshTarget<ShopWalletScreen> {
  /// ★ المعرّف للتاجر نفسه فقط: الشاشة تُفتح أيضاً من لوحة الأدمن
  ///   (`ownerPhone` ممرَّر) كصفحة مستقلة، وتلك لا تقف خلف زرّ في
  ///   قائمة سفلية، فلا تصغي لنداء «نُقر تبويب».
  @override
  String get tabId => widget.ownerPhone == null ? 'owner_wallet' : '';

  /// ★ نقرة زرّ «محفظتي»: تصعد لأعلى الرصيد وتعيد الحساب من القاعدة.
  @override
  Future<void> Function() onTabRefresh() => _load;

  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _d(Object? v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  int _int(Object? v) =>
      v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

  Future<void> _load() async {
    // ★ حارس الدور: هذه الشاشة لمحفظة صاحب الصيدلية. الزبون لا محفظة
    //   له إطلاقاً (طلب الأدمن 2026-11-19)، فلا تُجلب له أرقام ولا تُعرض.
    //   فتحها من لوحة الأدمن بهاتف صاحب الصيدلية يمرّ (`ownerPhone != null`).
    if (widget.ownerPhone == null &&
        !AuthService.instance.isShopOwner &&
        !AuthService.instance.isAdmin) {
      setState(() {
        _loading = false;
        _error = 'لا محفظة لهذا الحساب';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final phone = widget.ownerPhone ?? AuthService.instance.phone ?? '';
    final res = await SupabaseService.instance.fetchShopWallet(phone);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _data = res;
      _error = SupabaseService.instance.lastShopWalletError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final rows = (data?['rows'] as List?) ?? const [];
    final deduction = deductionText(
      deductionMethodOf(data?['deduction_method']),
      _d(data?['deduction_value']),
      unit: 'طلب',
    );
    // ★ عدد الطلبات من صيدليته: `entries` هي الحقيقة المحتسبة في
    //   الرصيد (طلبات مسلَّمة لها قيود ربح)؛ وإن غابت فالاحتياطي
    //   عدد الصفوف المعروضة.
    final ordersCount = data?['entries'] != null
        ? _int(data?['entries'])
        : rows.length;

    // ★ حين تُفتح الشاشة بضغطة من لوحة الأدمن (خارج `ShopOwnerShell`)
    //   نحتاج زر رجوع في البداية و«تحديث» في النهاية. وداخل التبويب
    //   لا يوجد ما نرجع إليه، فيبقى «تحديث» في البداية لأن الحافة
    //   اليسرى يحتلّها زر الخروج العائم فيبتلع اللمس.
    final pushed = Navigator.of(context).canPop();
    final refreshBtn = IconButton(
      icon: const Icon(Icons.refresh_rounded),
      onPressed: _loading ? null : () => AppRefresh.run(_load),
      tooltip: 'تحديث',
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.title ?? 'محفظتي',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900)),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        leading: pushed ? null : refreshBtn,
        actions: pushed ? [refreshBtn] : null,
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
                  if (data == null)
                    _message(
                      _error ?? 'جارِ فتح المحفظة…',
                      warn: _error != null,
                    )
                  else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: AppColors.buttonGradient,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'رصيدك بعد الاستقطاع',
                            style: GoogleFonts.cairo(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            CurrencyFormatter.format(_d(data['balance'])),
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            '${data['shop_name'] ?? ''} · استقطاع $deduction',
                            style: GoogleFonts.cairo(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'عدد الطلبات من صيدليتك: $ordersCount',
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        _stat(
                          'إجمالي المبيعات',
                          _d(data['gross']),
                          AppColors.textPrimary,
                        ),
                        const SizedBox(width: 10),
                        _stat(
                          'الاستقطاع',
                          _d(data['commission']),
                          AppColors.danger,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text('آخر الطلبات',
                        style: GoogleFonts.cairo(
                            fontSize: 15, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    if (rows.isEmpty)
                      _message('لا يوجد طلب مسلَّم بعد — الرصيد يُحتسب عند '
                          'تسليم كل طلب.')
                    else
                      for (final r in rows) _row(r),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _stat(String label, double v, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            children: [
              Text(label,
                  style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Text(
                CurrencyFormatter.format(v),
                style: GoogleFonts.cairo(
                    fontSize: 16, fontWeight: FontWeight.w900, color: color),
              ),
            ],
          ),
        ),
      );

  /// ★ رقم الطلب كما يعرفه الزبون: `serial_number` المتسلسل، لا
///   الرمز العشوائي `#MURU1387`. التاجر يستقبل مكالمة على الرقم
///   المتسلسل، فالرمز العشوائي لا يصلحه إلى شيء.
String _label(Map<String, dynamic> r) {
  final s = r['serial_number'] ?? r['label'] ?? r['order_number'];
  final t = '${s ?? ''}'.trim();
  if (t.isEmpty) return '—';
  return t.replaceFirst(RegExp(r'^#'), '');
}

  Widget _row(Map<String, dynamic> r) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'طلب ${_label(r)}',
                    style: GoogleFonts.cairo(
                        fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  CurrencyFormatter.format(_d(r['net'])),
                  style: GoogleFonts.cairo(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'مبيعات ${CurrencyFormatter.format(_d(r['gross']))}'
              '  −  استقطاع ${CurrencyFormatter.format(_d(r['commission']))}',
              style: GoogleFonts.cairo(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textHint,
              ),
            ),
          ],
        ),
      );

  Widget _message(String text, {bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 12),
        child: Column(
          children: [
            Icon(
              warn
                  ? Icons.error_outline_rounded
                  : Icons.account_balance_wallet_outlined,
              size: 54,
              color: warn ? AppColors.danger : AppColors.textHint,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 13.5,
                height: 1.7,
                fontWeight: FontWeight.w700,
                color: warn ? AppColors.danger : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}