import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../services/supabase_service.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import 'admin_shop_reset_flow.dart';
import 'wallet_screen.dart';

/// تفاصيل صاحب الصيدلية (الأدمن): صيدليته + عدد منتجاته + طلباته
/// (المستلمة/المكتملة/المرفوضة) + أرباحه، مع قائمة منتجاته.
class AdminShopOwnerDetailsScreen extends StatefulWidget {
  const AdminShopOwnerDetailsScreen({
    super.key,
    required this.owner,
    required this.stats,
  });

  final Map<String, dynamic> owner;
  final Map<String, dynamic> stats;

  @override
  State<AdminShopOwnerDetailsScreen> createState() =>
      _AdminShopOwnerDetailsScreenState();
}

class _AdminShopOwnerDetailsScreenState
    extends State<AdminShopOwnerDetailsScreen> {
  List<Map<String, dynamic>> _products = const [];
  bool _loading = true;

  /// رصيد الصيدلية من دفتر الأرباح (عمولة المنصة تُقرأ من الدفتر نفسها).
  Map<String, dynamic>? _balance;
  bool _resetting = false;

  Map<String, dynamic> get _shop =>
      Map<String, dynamic>.from((widget.owner['shop'] as Map?) ?? const {});

  Map<String, dynamic> get _stats => Map<String, dynamic>.from(widget.stats);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final shopId = _shop['id']?.toString() ?? '';
    final phone = widget.owner['phone']?.toString() ?? '';
    final products = shopId.isEmpty
        ? const <Map<String, dynamic>>[]
        : await SupabaseService.instance.fetchProducts(shopId: shopId);
    final balance = phone.isEmpty
        ? null
        : await SupabaseService.instance.fetchShopOwnerBalance(phone);
    if (!mounted) return;
    setState(() {
      _products = products;
      _balance = balance;
      _loading = false;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.primary,
        ),
      );
  }

  /// ★ تصفير رصيد هذه الصيدلية + أرقام بطاقته — بنسخة واحدة من المنطق
  ///   موجودة في `admin_shop_reset_flow.dart` (تستعملها أيضا بطاقة الصيدلية في
  ///   قائمة «أصحاب الصيدليات» فلا تتباعد الشاشتان).
  ///
  /// لا يحذف شيئاً: يسجّل «دفعة» بقيمة المستحق فيصبح الرصيد صفراً، وينقل خط
  /// أساس الصيدلية فتصير «طلبات / مكتملة / أرباح» صفراً في نفس اللحظة.
  Future<void> _resetBalance() async {
    final phone = widget.owner['phone']?.toString() ?? '';
    if (phone.isEmpty) return;
    final net = (_balance?['balance'] as num?)?.toDouble() ?? 0;

    setState(() => _resetting = true);
    final result = await adminResetShopBalance(
      context,
      phone: phone,
      shopName:
          _shop['name']?.toString() ??
          _stats['shop_name']?.toString() ??
          'هذه الصيدلية',
      balance: net,
    );
    if (!mounted) return;
    setState(() => _resetting = false);

    if (result.message.isNotEmpty) _toast(result.message);
    if (result.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.owner['name']?.toString().trim() ?? '';
    final phone = widget.owner['phone']?.toString() ?? '';
    final shopName =
        _shop['name']?.toString() ?? _stats['shop_name']?.toString() ?? '';
    final image =
        _shop['image_path']?.toString() ??
        _shop['logo_image']?.toString() ??
        '';
    final isOpen = _shop['is_open'] != false;
    final workingHours = _shop['working_hours']?.toString() ?? '—';
    // ★ صاحب صيدلية بلا صيدلية مرتبط: لا يُعرض سطر «مفتوح • —» المضلل —
    //   كان يظهر لأن `_shop['is_open'] != false` تعطي true لخريطة فارغة.
    final hasShop = _shop.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'صاحب الصيدلية',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: AppRefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // بطاقة الصاحب والصيدلية
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: image.isEmpty
                        ? Container(
                            width: 72,
                            height: 72,
                            color: AppColors.surfaceTint,
                            child: const Icon(
                              Icons.storefront_rounded,
                              color: AppColors.textHint,
                              size: 34,
                            ),
                          )
                        : AppImage(
                            image,
                            width: 72,
                            height: 72,
                            fit: BoxFit.cover,
                          ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: GoogleFonts.cairo(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (shopName.isNotEmpty)
                          Text(
                            shopName,
                            style: GoogleFonts.cairo(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        const SizedBox(height: 4),
                        Text(
                          phone,
                          style: GoogleFonts.cairo(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (hasShop) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                isOpen
                                    ? Icons.lock_open_rounded
                                    : Icons.lock_rounded,
                                color: isOpen
                                    ? AppColors.success
                                    : AppColors.danger,
                                size: 15,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '${isOpen ? 'مفتوح' : 'مغلق'} • $workingHours',
                                style: GoogleFonts.cairo(
                                  fontSize: 11.5,
                                  color: isOpen
                                      ? AppColors.success
                                      : AppColors.danger,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ★ المربع الوحيد الباقي: عدد المنتجات.
            //   كان هنا أربعة مربعات (منتجات / طلبات مستلمة / مكتملة /
            //   مرفوضة). الثلاثة الأخرى طلبات محسوبة، وكلها تُصفَّر مع
            //   الرصيد وتُعرض داخل [_BalanceCard] — فتكرارها هنا كان
            //   يعرض رقماً منسياً بجانب الصفر بعد التصفير.
            _StatBox(
              icon: Icons.shopping_bag_rounded,
              label: 'عدد المنتجات',
              value: '${(_stats['product_count'] as num?)?.toInt() ?? 0}',
              color: AppColors.info,
            ),
            _BalanceCard(
              balance: _balance,
              resetting: _resetting,
              onReset: _resetBalance,
            ),
            // ★ فتح المحفظة الكاملة (سجل الطلبات المسلَّمة) لهذه الصيدلية.
            //   بطاقة الرصيد أعلاه أرقام مجملة فقط؛ المحفظة تعرض الطلب
            //   تلو الطلب كما يراها صاحب الصيدلية نفسه في «محفظتي».
            if (phone.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ShopWalletScreen(
                          ownerPhone: phone,
                          title: 'محفظة الصيدلية',
                        ),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.5),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 18,
                  ),
                  label: Text(
                    'فتح المحفظة — سجل الطلبات المسلَّمة',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),

            Text(
              'منتجات ${shopName.isEmpty ? 'الصيدلية' : shopName}',
              style: GoogleFonts.cairo(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_products.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'لا توجد منتجات لهذه الصيدلية',
                    style: GoogleFonts.cairo(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
            else
              for (final p in _products)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child:
                            (p['image_path']?.toString() ??
                                    p['logo_image']?.toString() ??
                                    '')
                                .isEmpty
                            ? Container(
                                width: 48,
                                height: 48,
                                color: AppColors.surfaceTint,
                                child: const Icon(
                                  Icons.fastfood_rounded,
                                  color: AppColors.textHint,
                                ),
                              )
                            : AppImage(
                                p['image_path']?.toString() ??
                                    p['logo_image']?.toString() ??
                                    '',
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p['name']?.toString() ?? 'منتج',
                              style: GoogleFonts.cairo(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              p['is_active'] == false ? 'غير مفعّل' : 'مفعّل',
                              style: GoogleFonts.cairo(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: p['is_active'] == false
                                    ? AppColors.danger
                                    : AppColors.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        CurrencyFormatter.format(
                          (p['price'] as num?)?.toDouble() ?? 0,
                        ),
                        style: GoogleFonts.cairo(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 20),
          ],
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
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // ★ بلا `Expanded`: هذه البطاقة تُعرض داخل ListView مباشرة (وليس
    //   داخل Row)، و`Expanded` خارج Flex يرمي CastError وقت العرض
    //   في الطبعة النهائية، فيُستبدل العنصر بمربع خطأ داكن فارغ يمتد
    //   على طول الشاشة ويحجب بطاقة المحفظة التي تحته تماماً.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.cairo(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// بطاقة رصيد الصيدلية: السعر الكلي، استقطاع المنصة 15%، الصافي،
/// والمدفوع. ومعها زر التصفير (الأدمن فقط بكلمة مرور).
class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.balance,
    required this.resetting,
    required this.onReset,
  });

  final Map<String, dynamic>? balance;
  final bool resetting;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final d = balance;
    if (d == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    double n(String k) => (d[k] as num?)?.toDouble() ?? 0;
    int i(String k) => (d[k] as num?)?.toInt() ?? 0;

    final gross = n('gross');
    final commission = n('commission');
    final net = n('balance');
    final earned = n('earned');
    final paid = n('paid');
    final pending = n('pending');
    // ★★ النسبة تُشتقّ من دفتر الأرباح نفسه (commission ÷ gross) لا من
    //   ثابت في الواجهة: فلا يمكن أن يظهر «عمولة 15%» بينما الحساب
    //   فعلياً 10%. الرجوع للافتراضي فقط إذا كان الرصيد صفرياً.
    final rate = SupabaseService.commissionRateOf(d);

    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.navyCardGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_balance_wallet_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'رصيد الصيدلية',
                style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'عمولة المنصة $rate%',
                  style: GoogleFonts.cairo(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // صافي المستحق — الرقم الأهم
          Text(
            CurrencyFormatter.format(net),
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            'صافي مستحق لصاحب الصيدلية',
            style: GoogleFonts.cairo(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),

          const SizedBox(height: 14),
          Divider(color: Colors.white.withValues(alpha: 0.22), height: 1),
          const SizedBox(height: 12),

          // التفصيل المالي
          _BalanceRow(
            icon: Icons.receipt_long_rounded,
            label: 'السعر الكلي (بنود صيدليته)',
            value: CurrencyFormatter.format(gross),
          ),
          const SizedBox(height: 7),
          _BalanceRow(
            icon: Icons.percent_rounded,
            label: 'استقطاع المنصة $rate%',
            value: '- ${CurrencyFormatter.format(commission)}',
          ),
          const SizedBox(height: 7),
          _BalanceRow(
            icon: Icons.payments_rounded,
            label: 'إجمالي ما استحقه تاريخياً',
            value: CurrencyFormatter.format(earned),
          ),
          const SizedBox(height: 7),
          _BalanceRow(
            icon: Icons.price_check_rounded,
            label: 'مُدفوع له سابقاً (تصفيرات)',
            value: CurrencyFormatter.format(paid),
          ),
          if (pending > 0) ...[
            const SizedBox(height: 7),
            _BalanceRow(
              icon: Icons.hourglass_top_rounded,
              label: 'قيد الانتظار (لم تُسلَّم)',
              value: CurrencyFormatter.format(pending),
            ),
          ],
          const SizedBox(height: 7),
          _BalanceRow(
            icon: Icons.inventory_2_rounded,
            label: 'منتجات مبيعة / طلبات',
            value: '${i('items_sold')} / ${i('orders_count')}',
          ),

          const SizedBox(height: 14),

          // زر التصفير — يعمل حتى لو الرصيد صفر: التصفير يصفّر أيضاً
          // أرقام بطاقة الصيدلية (طلبات/مكتملة/أرباح) بنقل خط أساسه.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: resetting ? null : onReset,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white.withValues(alpha: 0.45),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: resetting ? 0.25 : 0.7),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
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
                net > 0
                    ? 'تصفير الرصيد والأرقام إلى صفر'
                    : 'تصفير أرقام الصيدلية (الرصيد صفر)',
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BalanceRow extends StatelessWidget {
  const _BalanceRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.8), size: 15),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.cairo(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.cairo(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}
