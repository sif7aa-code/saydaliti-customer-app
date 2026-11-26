import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/deduction_label.dart';
import '../services/supabase_service.dart';
import 'admin_shop_owner_details_screen.dart';
import 'admin_shop_reset_flow.dart';
import '../widgets/app_refresh_indicator.dart';

/// أول نص غير فارغ بين القيمتين (مع trim)، وإلا [fallback].
///
/// ★ ضرورية لأن `_emptyOwnerStats()` تعيد `shop_name: ''` (نص فارغ لا
///   null)، و`'' ?? 'بدون صيدلية'` تعطي النص الفارغ نفسه فيظهر سطر فارغ
///   بلا أي كلمة — وهو ما كان يبدو «اسم الصيدلية لا يظهر».
String _firstNonEmpty(Object? a, Object? b, String fallback) {
  for (final v in [a, b]) {
    final s = v?.toString().trim() ?? '';
    if (s.isNotEmpty) return s;
  }
  return fallback;
}

/// لوحة أصحاب الصيدليات (الأدمن): قائمة كل حسابات أصحاب الصيدليات مع ملخص
/// إحصائيات لكل صاحب (منتجاته + الطلبات المستلمة/المكتملة/المرفوضة + الأرباح).
class AdminShopOwnersScreen extends StatefulWidget {
  const AdminShopOwnersScreen({super.key});

  @override
  State<AdminShopOwnersScreen> createState() => _AdminShopOwnersScreenState();
}

class _AdminShopOwnersScreenState extends State<AdminShopOwnersScreen> {
  bool _loading = true;
  bool _error = false;
  List<Map<String, dynamic>> _owners = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [quiet] = إعادة جلب بلا «دوّار تحميل»: تُستعمل عند العودة من شاشة الصيدلية
  /// بعد تصفير رصيده، فتتحدّث أرقام البطاقة (طلبات/مكتملة/أرباح) **فورًا**
  /// دون أن تختفي القائمة لحظة. الباقي كما هو تمامًا.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = false;
      });
    }
    final owners = await SupabaseService.instance.fetchShopOwners();

    // شريط الإحصائيات سريع لكل صاحب (متوازٍ).
    final enriched = await Future.wait(
      owners.map((o) async {
        final phone = o['phone']?.toString() ?? '';
        // ★ الصيدلية يُجلب **أولاً** لأن اسمه هو ما تحتاجه الإحصاءات.
        //   كان يُجلب بعد الإحصاءات، واسم الصيدلية كان يُمرَّر فارغاً
        //   (`o['shop_name']` لا وجود لهذا العمود في `fetchUsers`)
        //   فكانت الشاشات تعرض «بدون صيدلية» أو اسماً قديماً من
        //   `order_items.shop_name` — وهو نسخ قديم عند تغيير الاسم.
        final shop = await SupabaseService.instance.fetchShopByOwnerPhone(phone);
        final stats = await SupabaseService.instance.fetchShopOwnerStats(
          phone,
          shopName: shop?['name']?.toString().trim() ?? '',
        );
        // ★ مبلغ الصيدلية (بعد الاستقطاع الذي حدده الأدمن) من نفس دفتر التاجر:
        //   `get_shop_balance` هي التي تقرأها «محفظتي» عند صاحب الصيدلية،
        //   فلا رقمان مختلفان لنفس الصيدلية بين اللوحة والمحفظة.
        final wallet =
            await SupabaseService.instance.fetchShopOwnerBalance(phone);
        return {...o, 'stats': stats, 'shop': shop, 'wallet': wallet};
      }),
    );
    if (!mounted) return;
    setState(() {
      _owners = enriched;
      _loading = false;
      _error = enriched.isEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'محافظ الصيدليات وأصحابها',
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
            : _owners.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 140),
                      const Icon(
                        Icons.store_mall_directory_outlined,
                        size: 64,
                        color: AppColors.textHint,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          _error ? 'لا يوجد أصحاب صيدليات بعد' : 'تعذر التحميل',
                          style: GoogleFonts.cairo(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _owners.length,
                    itemBuilder: (_, i) =>
                        _OwnerCard(owner: _owners[i], onReload: () => _load(quiet: true)),
                  ),
      ),
    );
  }
}

class _OwnerCard extends StatefulWidget {
  const _OwnerCard({required this.owner, this.onReload});

  final Map<String, dynamic> owner;

  /// تُستدعى لإعادة قراءة أرقام البطاقة بصمت — بعد العودة من شاشة الصيدلية
  /// **وكذلك بعد تصفير مباشر من هذه البطاقة**.
  final Future<void> Function()? onReload;

  @override
  State<_OwnerCard> createState() => _OwnerCardState();
}

class _OwnerCardState extends State<_OwnerCard> {
  bool _resetting = false;

  Map<String, dynamic> get _owner => widget.owner;

  /// ★ تصفير هذه الصيدلية **مباشرة من البطاقة** — بنفس منطق زر المحفظة في
  ///   شاشة تفاصيل الصيدلية (`adminResetShopBalance`)، فلا نسختين من Dialog
  ///   وكلمة اللوحة. الرصيد يُجلب أولاً لأن الحوار يعرض المبلغ الذي سيُسجَّل.
  Future<void> _reset() async {
    if (_resetting) return;
    final phone = _owner['phone']?.toString() ?? '';
    if (phone.isEmpty) return;
    final shop = (_owner['shop'] as Map?) ?? const {};
    final stats =
        Map<String, dynamic>.from((_owner['stats'] as Map?) ?? const {});
    final shopName =
        _firstNonEmpty(shop['name'], stats['shop_name'], 'بدون صيدلية');

    // ★ الرصيد محمّل مع البطاقة، فلا رحلة أخرى عند الضغط. وإن غاب
    //   (فشل جلب) نجلبه الآن كي لا يُسجَّل صفرٌ كاذب في الحوار.
    final wallet = (_owner['wallet'] as Map?) ?? const {};
    double? balance = (wallet['balance'] as num?)?.toDouble();
    if (balance == null) {
      final fresh =
          await SupabaseService.instance.fetchShopOwnerBalance(phone);
      balance = (fresh['balance'] as num?)?.toDouble() ?? 0;
    }
    if (!mounted) return;

    setState(() => _resetting = true);
    final result = await adminResetShopBalance(
      context,
      phone: phone,
      shopName: shopName,
      balance: balance,
    );
    if (!mounted) return;
    setState(() => _resetting = false);

    if (result.message.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(result.message),
            behavior: SnackBarBehavior.floating,
            backgroundColor: result.ok ? AppColors.primary : AppColors.danger,
          ),
        );
    }
    if (result.ok) await widget.onReload?.call();
  }

  @override
  Widget build(BuildContext context) {
    final name = _firstNonEmpty(_owner['name'], null, 'صاحب صيدلية');
    final phone = _owner['phone']?.toString() ?? '';
    final shop = (_owner['shop'] as Map?) ?? const {};
    final stats =
        Map<String, dynamic>.from((_owner['stats'] as Map?) ?? const {});
    final shopName =
        _firstNonEmpty(shop['name'], stats['shop_name'], 'بدون صيدلية');
    final owner = _owner;

    return Card(
      elevation: 1.5,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AdminShopOwnerDetailsScreen(owner: owner, stats: stats),
            ),
          );
          // ★ بعد العودة — وقد يكون الرُصيد صُفّر من داخل الشاشة — تُعاد قراءة
          //   الأرقام بصمت فتظهر «طلبات / مكتملة / أرباح» مصفّرة فورًا.
          await widget.onReload?.call();
        },
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
                      Icons.storefront_rounded,
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
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w900,
                            fontSize: 14.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          shopName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          phone,
                          style: GoogleFonts.cairo(
                            fontSize: 11,
                            color: AppColors.textHint,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_left_rounded, color: AppColors.textHint),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _MiniStat(
                    icon: Icons.shopping_bag_rounded,
                    label: 'منتجات',
                    value: '${(stats['product_count'] as num?)?.toInt() ?? 0}',
                  ),
                  _MiniStat(
                    icon: Icons.receipt_long_rounded,
                    label: 'طلبات',
                    value: '${(stats['total_orders'] as num?)?.toInt() ?? 0}',
                  ),
                  _MiniStat(
                    icon: Icons.check_circle_rounded,
                    label: 'مكتملة',
                    value: '${(stats['delivered_orders'] as num?)?.toInt() ?? 0}',
                    color: AppColors.success,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // ★ مبلغ هذه الصيدلية كما في «محفظتي» عند صاحبها:
              //   السعر الكلي، الاستقطاع (ثابت أو نسبة)، والمستحق الآن.
              _ShopWalletLine(
                shopName: shopName,
                wallet: Map<String, dynamic>.from(
                  (_owner['wallet'] as Map?) ?? const {},
                ),
              ),
              const SizedBox(height: 10),
              // ★ تصفير هذه الصيدلية من البطاقة نفسها — المبلغ والأرقام معًا.
              //   مسطّحة بحدّ رفيع: لا خلفية رمادية ولا ظل.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _resetting || phone.isEmpty ? null : _reset,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    disabledForegroundColor:
                        AppColors.danger.withValues(alpha: 0.35),
                    side: BorderSide(
                      color: AppColors.danger.withValues(alpha: 0.45),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: _resetting
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.danger,
                          ),
                        )
                      : const Icon(Icons.restart_alt_rounded, size: 17),
                  label: Text(
                    'تصفير هذه الصيدلية (المبلغ والأرقام)',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ★ سطر محفظة الصيدلية داخل بطاقة «أصحاب الصيدليات».
///
/// يعرض **المبلغ المستحق** (بعد الاستقطاع) بخط بارز، وتحته السعر
/// الكلي والاستقطاع — كلها من `get_shop_balance` نفسها التي يقرأها
/// صاحب الصيدلية في «محفظتي»، فلا رقمان مختلفان لنفس الصيدلية.
class _ShopWalletLine extends StatelessWidget {
  const _ShopWalletLine({required this.shopName, required this.wallet});

  final String shopName;
  final Map<String, dynamic> wallet;

  @override
  Widget build(BuildContext context) {
    double n(String k) => (wallet[k] as num?)?.toDouble() ?? 0;
    final rule = deductionText(
      deductionMethodOf(wallet['deduction_method']),
      n('deduction_value'),
      unit: 'طلب',
    );
    final due = n('balance');
    final gross = n('gross');
    final commission = n('commission');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_balance_wallet_rounded,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'مستحق صيدلية $shopName',
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
                CurrencyFormatter.format(due),
                style: GoogleFonts.cairo(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'السعر الكلي: ${CurrencyFormatter.format(gross)}  ·  '
            'الاستقطاع ${CurrencyFormatter.format(commission)} ($rule)',
            style: GoogleFonts.cairo(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textHint,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    this.color = AppColors.info,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 16),
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