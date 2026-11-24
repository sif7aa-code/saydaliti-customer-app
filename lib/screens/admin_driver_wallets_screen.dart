import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/account_name.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/driver_wallet_pending.dart';
import '../services/admin_password_session.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// محفظة المندوبين (الأدمن): رصيد كل مندوب من الدفتر الحيّ + سجل دفعاته،
/// مع **تصفير حقيقي** يسجّل «دفعة» بقيمة المستحق فيصبح الرصيد صفراً في
/// كل الواجهات — محفظة المندوب نفسه تقرأ الدفتر نفسه.
///
/// ★ لماذا هذه الشاشة؟ كان التصفير للمندوب غير موجود في التطبيق أصلاً.
///   الآن هو نفس مسار الصيدلية: تسجيل دفعة (لا حذف سجلات) ⇒ الرصيد صفر
///   صدقاً، ويبقى معلوماً كم استحق المندوب وكم دُفع له.
///
/// ★ مبالغ الخصم كاملة تظهر هنا لكل مندوب: شريط الحصيلة في الأعلى
///   (إجمالي خصم المناديب + مدفوع + مستحق)، وداخل كل بطاقة صندوق
///   «مبالغ الخصم» يُفصّل كل كود بنسبته وعدد طلباته ومجموع مبلّغه —
///   كلها من الدفتر (`driver_wallet_ledger`) عبر `admin_list_driver_wallets()`.
///   الدالة مُعاد تثبيتها في `SQL_DRIVER_PENDING_DISCOUNT.sql` بلا `raise`
///   (وهذا الملف يُغني عن `SQL_DRIVER_WALLET_DISCOUNTS.sql` ورقعته)، فلا
///   يعود «تعذّر الجلب (400)» يظهر بلا سبب: إن رفض الخادم يُقرأ نصّ
///   رفضه كاملاً في الشاشة.
///
/// ★ **المعلَّق** سطرٌ منفصل تحت المستحق في الشريط وفي البطاقة: خصم كود
///   — من عجلة الحظ أو من أكواد الأدمن — على طلب قبِله المندوب ولم يُسلَّمه
///   بعد. تحسبه القاعدة حيّاً من جدول الطلبات ولا تكتبه في الدفتر، فلا
///   يدخل «مستحق» ولا يُدفع، ويثبت في الرصيد لحظة التسليم.
class AdminDriverWalletsScreen extends StatefulWidget {
  const AdminDriverWalletsScreen({super.key});

  @override
  State<AdminDriverWalletsScreen> createState() =>
      _AdminDriverWalletsScreenState();
}

class _AdminDriverWalletsScreenState extends State<AdminDriverWalletsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  /// ★ حصيلة الخادم (إجمالي خصم المندوبين وعدد المندوبين والسطور
  ///   والمدفوع) — من نفس ردّ القائمة الذي تُرسم منه البطاقات، فالحصيلة
  ///   والأرقام داخلها من مصدر واحد. فارغة قبل أول جلب ناجح.
  Map<String, dynamic> _totals = const {};

  /// المناديب الموسَّعون — سجل الدفعات يُجلب عند أول توسيع فقط.
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
    final items = await SupabaseService.instance.adminListDriverWallets();
    if (!mounted) return;
    setState(() {
      _items = items ?? const [];
      _totals = items == null
          ? const {}
          : SupabaseService.instance.lastAdminDriverWalletTotals;
      _error = items == null
          ? (SupabaseService.instance.lastAdminDriverWalletError ??
                'تعذّر التحميل')
          : null;
      _loading = false;
    });
    // سجل دفعات المناديب الموسَّعين قد يكون قديماً بعد التصفير — نُحدّثه.
    for (final phone in _expanded) {
      await _loadPayouts(phone, force: true);
    }
  }

  Future<void> _loadPayouts(String phone, {bool force = false}) async {
    if (!force && _payouts.containsKey(phone)) return;
    if (!mounted) return;
    setState(() => _payoutsLoading.add(phone));
    final rows = await SupabaseService.instance.adminDriverPayouts(phone);
    if (!mounted) return;
    setState(() {
      _payoutsLoading.remove(phone);
      if (rows != null) _payouts[phone] = rows;
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

  /// ★ تصفير رصيد مندوب — الأدمن فقط بكلمة مرور (كلمة اللوحة نفسها).
  ///
  /// لا يحذف شيئاً: يسجّل «دفعة» بقيمة المستحق فيصبح الرصيد صفراً.
  Future<void> _resetWallet(Map<String, dynamic> item) async {
    final phone = item['phone']?.toString() ?? '';
    if (phone.isEmpty) return;
    final due = (item['due'] as num?)?.toDouble() ?? 0;
    if (due <= 0) {
      _toast('رصيد هذا المندوب صفر أصلاً');
      return;
    }

    // ★ كلمة المرور من الجلسة إن كُتبت سابقاً في هذا الفتح للتطبيق:
    //   لا نطلبها مرة أخرى — تُكتب مرة واحدة لكل فتح (ذاكرة فقط).
    final cachedPw = AdminPasswordSession.cached;
    final hasCached = (cachedPw ?? '').isNotEmpty;

    final pwCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تصفير رصيد المندوب',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'سيُسجَّل أنك دفعت ${CurrencyFormatter.format(due)} '
              'فيصبح الرصيد صفراً.\n'
              'لا يُحذف أي سجل من الدفتر — تبقى معرفة كم استحق المندوب '
              'وكم دُفع له.',
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
            // ★ حقل الكلمة يظهر فقط إن لم تكن محفوظة لهذه الجلسة.
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
    setState(() => _resetting.add(phone));
    final res = await SupabaseService.instance.adminResetDriverWallet(
      phone,
      password,
      note: note,
    );
    if (!mounted) return;
    setState(() => _resetting.remove(phone));

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
      _toast('تم التصفير — سُجّلت دفعة ${CurrencyFormatter.format(paid)}');
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
          'محفظة المندوبين',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 140),
                  const Icon(
                    Icons.delivery_dining_outlined,
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
              )
            : _items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 140),
                  const Icon(
                    Icons.local_offer_outlined,
                    size: 64,
                    color: AppColors.textHint,
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        'لا توجد خصومات مسجّلة للمندوبين بعد',
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
                      'يُسجَّل الخصم تلقائياً عند تسليم طلب فيه كود',
                      style: GoogleFonts.cairo(
                        color: AppColors.textHint,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  _TotalsStrip(totals: _totals, items: _items),
                  Expanded(
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: _items.length,
                      itemBuilder: (_, i) => _DriverWalletCard(
                        item: _items[i],
                        expanded: _expanded.contains(
                          _items[i]['phone']?.toString() ?? '',
                        ),
                        payouts: _payouts[_items[i]['phone']?.toString() ?? ''],
                        payoutsLoading: _payoutsLoading.contains(
                          _items[i]['phone']?.toString() ?? '',
                        ),
                        resetting: _resetting.contains(
                          _items[i]['phone']?.toString() ?? '',
                        ),
                        onToggle: () {
                          final phone = _items[i]['phone']?.toString() ?? '';
                          if (phone.isEmpty) return;
                          setState(() {
                            if (!_expanded.remove(phone)) {
                              _expanded.add(phone);
                            }
                          });
                          if (_expanded.contains(phone)) {
                            _loadPayouts(phone);
                          }
                        },
                        onReset: () => _resetWallet(_items[i]),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _DriverWalletCard extends StatelessWidget {
  const _DriverWalletCard({
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

  /// ★ الاسم الحقيقي للمندوب، فرقمه الثابت — لا لقب «مندوب» يجمعهم.
  String get _name {
    return AccountName.real(name: item['name'], phone: item['phone']);
  }

  @override
  Widget build(BuildContext context) {
    final phone = item['phone']?.toString() ?? '';
    final orders = (item['orders'] as num?)?.toInt() ?? 0;
    final earned = (item['earned'] as num?)?.toDouble() ?? 0;
    final paid = (item['paid'] as num?)?.toDouble() ?? 0;
    final due = (item['due'] as num?)?.toDouble() ?? 0;
    final overpaid = (item['overpaid'] as num?)?.toDouble() ?? 0;

    // ★ معلَّق هذا المندوب: خصم أكواد على طلبات قبَلها ولم تُسلَّم.
    final pending = DriverWalletPending.from(item);

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
                      Icons.delivery_dining_rounded,
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
                          _name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w900,
                            fontSize: 14.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        // ★ الرقم لا يتكرر سطرين: فحين لا اسم حقيقي
                        //   يظهر وحده في الأعلى.
                        if (phone.isNotEmpty && phone != _name)
                          Text(
                            phone,
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              color: AppColors.textHint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        // ★ المعلَّق ظاهر قبل التوسيع: هو «الشغل الجاري»
                        //   عند هذا المندوب، والأدمن يسأل عنه أول ما يفتح.
                        if (pending.hasMoney)
                          Text(
                            pending.totalsLabel ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              color: AppColors.warning,
                              fontWeight: FontWeight.w800,
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
              if (expanded) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    _StatBox(
                      icon: Icons.receipt_long_rounded,
                      label: 'طلبات',
                      value: '$orders',
                    ),
                    _StatBox(
                      icon: Icons.trending_up_rounded,
                      label: 'إجمالي الاستحقاق',
                      value: CurrencyFormatter.format(earned),
                    ),
                    _StatBox(
                      icon: Icons.payments_rounded,
                      label: 'مدفوع سابقاً',
                      value: CurrencyFormatter.format(paid),
                    ),
                  ],
                ),
                // ★ مبالغ الخصم كاملة: كل كود استلمه المندوب بنسبته
                //   وعدد طلباته ومجموع مبلّغه — من الدفتر نفسه.
                const SizedBox(height: 12),
                _DiscountsBox(item: item),
                // ★ ثم معلَّقه: خصم طلبات قبَلها ولم تُسلَّم. صندوق
                //   منفصل لأن هذا المال ليس في الدفتر بعد، ولا يُدفع
                //   ولا يدخل «مستحق» — يُثبَّت عند التسليم.
                if (pending.hasRows) ...[
                  const SizedBox(height: 10),
                  _PendingBox(pending: pending),
                ],
                if (overpaid > 0) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        size: 16,
                        color: AppColors.warning,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'مدفوع له أكثر من المستحق بمقدار '
                          '${CurrencyFormatter.format(overpaid)} — الرصيد صفر.',
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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

/// شارة حالة الرصيد: أحمر «مستحق» + المبلغ، أو أصفر «مدفوع أكثر»،
/// أو أخضر «صفر».
class _DueBadge extends StatelessWidget {
  const _DueBadge({required this.due, required this.overpaid});

  final double due;
  final double overpaid;

  @override
  Widget build(BuildContext context) {
    final (color, label) = due > 0
        ? (AppColors.danger, 'مستحق ${CurrencyFormatter.format(due)}')
        : overpaid > 0
        ? (AppColors.warning, 'مدفوع أكثر')
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

/// سجل الدفعات: كل سطر «مبلغ + ملاحظة + تاريخ». تُجلب عند التوسيع.
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
        'لا توجد دفعات مسجّلة بعد',
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
          'سجل الدفعات (${rows.length})',
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
                        : 'دفعة',
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

/// ★ شريط الحصيلة أعلى القائمة: إجمالي خصم المندوبين + عدد المندوبين
///   والطلبات + المدفوع والمستحق.
///
/// أرقامه من **نفس ردّ الخادم** الذي تُرسم منه البطاقات؛ وإن كانت القاعدة
/// لم تُرسل حصيلة (نسخة SQL قديمة) جُمعت من البطاقات نفسها — فلا يظهر
/// رقم أعلى يخالف مجموع الأسفل.
class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals, required this.items});

  final Map<String, dynamic> totals;
  final List<Map<String, dynamic>> items;

  static double _num(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  /// خصم مندوب واحد: الحقل الجديد، وإلا الاستحقاق (هما نفس الدفتر).
  static double _ofRow(Map<String, dynamic> e) {
    final d = _num(e, 'discount_total');
    return d > 0 ? d : _num(e, 'earned');
  }

  @override
  Widget build(BuildContext context) {
    final hasServer = totals.isNotEmpty;
    final discount = hasServer
        ? _num(totals, 'total_discount')
        : items.fold<double>(0, (s, e) => s + _ofRow(e));
    final drivers = hasServer ? _num(totals, 'drivers').toInt() : items.length;
    final orders = hasServer
        ? _num(totals, 'rows').toInt()
        : items.fold<int>(
            0,
            (s, e) =>
                s + (e['orders'] is num ? (e['orders'] as num).toInt() : 0),
          );
    final paid = hasServer
        ? _num(totals, 'total_paid')
        : items.fold<double>(0, (s, e) => s + _num(e, 'paid'));
    final due = hasServer
        ? _num(totals, 'total_due')
        : items.fold<double>(0, (s, e) => s + _num(e, 'due'));

    // ★ المعلَّق: من حصيلة الخادم إن أرسلها، وإلا مجموع البطاقات نفسها.
    //   وحين لا تُرسله نسخة القاعدة القديمة **لا سطر** — لا «معلَّق ٠»
    //   الذي يوحي بأن لا عمل قائماً عند المناديب.
    final fromTotals = DriverWalletPending.from(totals);
    double pendingSum = 0;
    int pendingOrders = 0;
    bool pendingKnown = fromTotals.known;
    if (fromTotals.known) {
      pendingSum = fromTotals.amount;
      pendingOrders = fromTotals.orders;
    } else {
      for (final e in items) {
        final p = DriverWalletPending.from(e);
        if (!p.known) continue;
        pendingKnown = true;
        pendingSum += p.amount;
        pendingOrders += p.orders;
      }
    }
    // الحصيلة المجمَّعة تُلبس نفس شكل البطاقة، فتُصاغ الأعداد من مصدر
    // واحد («طلب / طلبان / طلبات») ولا تُكتب القاعدة النحوية مرتين.
    final pendingTotal = DriverWalletPending(
      known: pendingKnown,
      amount: pendingSum,
      orders: pendingOrders,
      rows: const <Map<String, dynamic>>[],
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.imageBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_offer_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'إجمالي خصم المندوبين',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                CurrencyFormatter.format(discount),
                style: GoogleFonts.cairo(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$drivers مندوب · $orders طلب بخصم · '
            'مدفوع ${CurrencyFormatter.format(paid)} · '
            'مستحق ${CurrencyFormatter.format(due)}',
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textHint,
            ),
          ),
          // ★ المال الذي لم يستحق بعد: خصم أكواد على طلبات مقبولة لم
          //   تُسلَّم. سطر منفصل تحت المستحق حتى لا يُحسب معه دفعاً.
          if (pendingTotal.hasMoney || pendingTotal.orders > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.hourglass_top_rounded,
                  size: 15,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'معلَّق عند المناديب · ${pendingTotal.orders} '
                    '${pendingTotal.ordersWord} — يُثبَّت عند التسليم',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                Text(
                  CurrencyFormatter.format(pendingTotal.amount),
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: AppColors.warning,
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

/// ★ معلَّق مندوب واحد: خصم أكواد على طلبات قبَلها ولم تُسلَّم بعد.
///   كل سطر برقم الطلب وكوده وحالته، والمجموع في الأعلى. المصدر: جدول
///   الطلبات الحيّ عبر `driver_pending_wallet` — لا الدفتر، فليس فيه بعد.
class _PendingBox extends StatelessWidget {
  const _PendingBox({required this.pending});

  final DriverWalletPending pending;

  /// «عجلة · مقبول» — كلمة العجلة أمام الحالة إن كان الكود من عجلة
  /// الحظ، وتُحذف الفاصلة حين يغيب أحد الطرفين.
  static String _pendingTag(PendingRow r) => <String>[
    if (r.fromWheel) 'عجلة',
    if (r.status.isNotEmpty) r.status,
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.hourglass_top_rounded,
                size: 15,
                color: AppColors.warning,
              ),
              const SizedBox(width: 6),
              Text(
                'معلَّق حتى التسليم',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                CurrencyFormatter.format(pending.amount),
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
          for (final raw in pending.rows)
            Builder(
              builder: (context) {
                // `pending.rows` خريطة جاهزة من المحلّل، فلا فحص نوع
                // ولا نسخة هنا — التحليل كلّه في مصدر واحد.
                final r = DriverWalletPending.row(raw);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          'طلب ${r.label}'
                          '${r.code == null ? '' : ' · ${r.code}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      // «عجلة» ثم الحالة — من القاعدة، ولا نصّ يُخترع هنا.
                      if (_pendingTag(r).isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          _pendingTag(r),
                          style: GoogleFonts.cairo(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textHint,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        CurrencyFormatter.format(r.amount),
                        style: GoogleFonts.cairo(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w900,
                          color: AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 6),
          Text(
            'يُضاف إلى مستحقه لحظة تسليم الطلب — لا يُدفع الآن.',
            style: GoogleFonts.cairo(
              fontSize: 10.5,
              color: AppColors.textHint,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// ★ مبالغ خصم مندوب واحد بالكامل: إجماليه ثم كل كود استلمه — بنسبته
///   وعدد طلباته ومجموع مبلّغه. المصدر: دفتر محفظة المندوب في القاعدة.
class _DiscountsBox extends StatelessWidget {
  const _DiscountsBox({required this.item});

  final Map<String, dynamic> item;

  static double _num(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final raw = item['codes'];
    final codes = raw is List ? raw : const <dynamic>[];
    final total = _num(item, 'discount_total') > 0
        ? _num(item, 'discount_total')
        : _num(item, 'earned');
    final orders = item['orders'] is num ? (item['orders'] as num).toInt() : 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.brand.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'مبالغ الخصم',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                CurrencyFormatter.format(total),
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.brand,
                ),
              ),
            ],
          ),
          if (codes.isEmpty) ...[
            const SizedBox(height: 6),
            Text(
              total > 0
                  ? 'مجموع خصومه من $orders طلب — ولم تُرسل القاعدة تفصيل '
                        'الأكواد (شغّل SQL_DRIVER_WALLET_DISCOUNTS.sql)'
                  : 'لم يستلم هذا المندوب كود خصم بعد',
              style: GoogleFonts.cairo(
                fontSize: 11,
                color: AppColors.textHint,
                fontWeight: FontWeight.w600,
                height: 1.5,
              ),
            ),
          ] else
            for (final r in codes)
              Builder(
                builder: (context) {
                  final c = r is Map
                      ? Map<String, dynamic>.from(r)
                      : <String, dynamic>{};
                  final amount = _num(c, 'amount');
                  final percent = _num(c, 'percent');
                  final count = c['orders'] is num
                      ? (c['orders'] as num).toInt()
                      : 0;
                  final code = '${c['code'] ?? '—'}';
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            code,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (percent > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              '${percent.toStringAsFixed(0)}٪',
                              style: GoogleFonts.cairo(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          '×$count',
                          style: GoogleFonts.cairo(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textHint,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          CurrencyFormatter.format(amount),
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }
}
