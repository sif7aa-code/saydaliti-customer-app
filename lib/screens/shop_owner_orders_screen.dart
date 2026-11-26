import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/account_name.dart';
import '../core/utils/currency_formatter.dart';
import '../services/auth_service.dart';
import '../services/realtime_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/image_viewer.dart';

/// ★ سجل طلبات صاحب الصيدلية المكتملة — **طلبات صيدليته هو**.
///
/// ★ سجل طلبات صاحب الصيدلية: مبيعاته **و** طلبات المندوب التي أرسلها.
///
/// ★ ليس سجلّ مشترياته الشخصية: التاجر هنا يبيع، والذي
///   يريده هو «متى بعت وكم ربحت» لا «ماذا اشتريت».
///
/// ★ «المكتملة» = المسلَّمة فقط. إظهار المعلّق أو المرفوض يجعله
///   يخسر مبلغاً لم يخسره بعد — أو يرى سجلاً لا نقداً.
///   استثناءً واحد: **طلب المندوب** يُعرض بكل حالاته، لأن حالته
///   هي كل ما ينتظره من مندوب، لا ربحاً له.
class ShopOwnerOrdersScreen extends StatefulWidget {
  const ShopOwnerOrdersScreen({super.key});

  @override
  State<ShopOwnerOrdersScreen> createState() => _ShopOwnerOrdersScreenState();
}

class _ShopOwnerOrdersScreenState extends State<ShopOwnerOrdersScreen>
    with TabRefreshTarget<ShopOwnerOrdersScreen> {
  @override
  String get tabId => 'owner_orders';

  /// ★ نقرة زرّ «طلباتي»: تصعد لأول طلب وتعيد الجلب من القاعدة —
  ///   فيرى مبيعات جديدة فوراً مع الرنّة.
  @override
  Future<void> Function() onTabRefresh() => _load;

  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _listenRealtime();
  }

  /// ★ بثّ فوري: طلب جديد **لصيدليتي أنا** يصل هنا لحظة كتابته في
  ///   القاعدة، فلا يحتاج التاجر سحب الصفحة ليعلم. وتغيّر حالة طلب
  ///   يعيد جلب المبيعات بصمت (تُحدَّث عند التسليم وحدها).
  ///
  ///   السيرفر يوجّه الحدث إلى هاتف صاحب الصيدلية وحده (بأرقام
  ///   `shops.owner_phone` الخاصة بصيدليات الطلب)، فلا يصل تاجراً آخر.
  StreamSubscription<RealtimeEvent>? _rtSub;

  void _listenRealtime() {
    _rtSub?.cancel();
    _rtSub = RealtimeService.instance.events.listen((e) {
      if (!mounted) return;
      if (e.topic == RtEvent.orderNew) {
        _showNewOrder(e.data['serial']?.toString().trim() ?? '');
        return;
      }
      if (e.topic == RtEvent.orderStatus) unawaited(_refreshQuiet());
    });
    RealtimeService.instance.start();
  }

  /// تنبيه الشاشة نفسها (لا إشعار نظام): الطلب الجديد ليس من مبيعاته
  /// بعد، فلا يُضاف للسجل — يكفي أن يعلم به الآن.
  void _showNewOrder(String serial) {
    final text = serial.isEmpty
        ? 'وصلتك طلبية جديدة — جهّزها الآن'
        : 'وصلتك طلبية جديدة $serial — جهّزها الآن';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.notifications_active_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  bool _quietBusy = false;

  /// إعادة الجلب بلا دوّارة تحميل: الشاشة تبقى كما هي ويُستبدل
  /// الرقم عند وصول الجديد، فلا وميض عند كل تسليم.
  Future<void> _refreshQuiet() async {
    if (_quietBusy) return;
    _quietBusy = true;
    final phone = AuthService.instance.phone ?? '';
    final res = await SupabaseService.instance.fetchShopCompletedOrders(phone);
    _quietBusy = false;
    if (!mounted || res == null) return;
    setState(() {
      _data = res;
      _error = SupabaseService.instance.lastShopOrdersError;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _rtSub?.cancel();
    super.dispose();
  }

  double _d(Object? v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  String _when(Object? v) {
    final s = v?.toString() ?? '';
    if (s.length < 10) return '';
    final d = DateTime.tryParse(s)?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} · ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final phone = AuthService.instance.phone ?? '';
    final res = await SupabaseService.instance.fetchShopCompletedOrders(phone);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _data = res;
      _error = SupabaseService.instance.lastShopOrdersError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final rows = (data?['rows'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('طلباتي المكتملة',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900)),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        // ★ «تحديث» في البداية (يمين RTL) لا في `actions` —
        //   نفس سبب شاشة المنتجات: الحافة اليسرى يحتلّها زر
        //   الخروج العائم في `ShopOwnerShell` فيبتلع اللمس.
        leading: IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loading ? null : () => AppRefresh.run(_load),
          tooltip: 'تحديث',
        ),
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
                      _error ?? 'جارِ فتح السجل…',
                      warn: _error != null,
                    )
                  else ...[
                    _summary(data),
                    const SizedBox(height: 16),
                    if (rows.isEmpty)
                      _message(
                        'لا توجد طلبات بعد.\n'
                        'السجل يمتلئ بتسليم كل طلب بيع، فور تسجيلك طلب مندوب.',
                      )
                    else
                      for (final r in rows) _row(r),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _summary(Map<String, dynamic> data) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: AppColors.buttonGradient,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Text(
              // ★ طلبات المندوب ليست مبيعات: عدّها في السجل لا في
              //   صافي الأرباح، وإلا صار «طلباتي» رقماً كاذياً.
              '${data['shop_name'] ?? ''} · ${data['count'] ?? 0} سجل'
              '${(data['driver_requests'] ?? 0) > 0 ? ' · ${data['driver_requests']} طلب مندوب' : ''}',
              style: GoogleFonts.cairo(
                color: Colors.white70,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              CurrencyFormatter.format(_d(data['net'])),
              style: GoogleFonts.cairo(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              'صافي الأرباح بعد الاستقطاع الذي تحدده إدارة التطبيق',
              style: GoogleFonts.cairo(
                color: Colors.white70,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _pill('المبيعات', _d(data['gross']), Colors.white),
                const SizedBox(width: 10),
                _pill('الاستقطاع', _d(data['commission']), Colors.white70),
              ],
            ),
          ],
        ),
      );

  Widget _pill(String label, double v, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(label,
                  style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: color)),
              Text(
                CurrencyFormatter.format(v),
                style: GoogleFonts.cairo(
                    fontSize: 14, fontWeight: FontWeight.w900, color: color),
              ),
            ],
          ),
        ),
      );

  /// ★ رقم الطلب كما يعرفه الزبون: `serial_number` المتسلسل، لا الرمز
///   العشوائي `#MURU1387`. التاجر يردّ على مكالمة بالرقم المتسلسل.
String _label(Map<String, dynamic> r) {
  final s = r['serial_number'] ?? r['label'] ?? r['order_number'];
  final t = '${s ?? ''}'.trim();
  if (t.isEmpty) return '—';
  return t.replaceFirst(RegExp(r'^#'), '');
}

  Widget _row(Map<String, dynamic> r) {
    // ★ طلب المندوب بلا ربح — نعرضه بشارة حالة لا بمبلغ صفر،
    //   وإلا يُقرأ كأنه طلب بيع خسر شيئاً (وهو لم يخسر شيئاً).
    final isDriverRequest = '${r['kind'] ?? 'sale'}' == 'driver_request';
    final status = '${r['status'] ?? ''}';
    final net = _d(r['net']);
    final items = (r['items'] as List?) ?? const [];
    final driver = '${r['driver_name'] ?? ''}'.trim();
    final driverPhone = '${r['driver_phone'] ?? ''}'.trim();
    final rx = '${r['prescription'] ?? ''}'.trim();
    final when = _when(r['delivered_at'] ?? r['created_at']);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (isDriverRequest ? AppColors.primary : AppColors.success)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isDriverRequest
                      ? Icons.delivery_dining_rounded
                      : Icons.check_circle_rounded,
                  size: 24,
                  color: isDriverRequest ? AppColors.primary : AppColors.success,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            isDriverRequest
                                ? 'طلب مندوب #${_label(r)}'
                                : 'طلب ${_label(r)}',
                            style: GoogleFonts.cairo(
                                fontSize: 14, fontWeight: FontWeight.w900),
                          ),
                        ),
                        if (isDriverRequest) ...[
                          const SizedBox(width: 6),
                          _badge(status),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isDriverRequest
                          ? 'أرسلته $when'
                          : '$when · مبيعات '
                              '${CurrencyFormatter.format(_d(r['gross']))} '
                              '− استقطاع ${CurrencyFormatter.format(_d(r['commission']))}',
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isDriverRequest)
                Text(
                  CurrencyFormatter.format(net),
                  style: GoogleFonts.cairo(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: AppColors.success,
                  ),
                ),
            ],
          ),

          // ★ من أنجز الطلب — لا يُطلب من التاجر أن يبحث عنه.
          if (driver.isNotEmpty || driverPhone.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.delivery_dining_rounded,
                    size: 14, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // ★ الرقم أولاً: هو ما يتصل به التاجر عند طارئ.
                    // ★ الاسم الحقيقي فإن غاب فالرقم — لا كلمة «مندوب»
                    //   مجهولة صاحبه.
                    'أنجزه ${AccountName.withPhone(name: driver, phone: driverPhone)}',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],

          // ★ الوصفة الطبية المرفقة عند الطلب — يفتحها الصيدلي بالحجم
          //   الكامل. لا يظهر السطر أصلاً إن لم تكن للطلب وصفة.
          if (rx.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => ImageViewerScreen.open(
                context,
                url: rx,
                title: 'الوصفة الطبية · طلب ${_label(r)}',
              ),
              child: Row(
                children: [
                  const Icon(Icons.medical_information_rounded,
                      size: 15, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Text(
                    'الوصفة الطبية المرفقة — اضغط لعرضها',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ★ أصناف هذه الصيدلية فقط — الطلب قد يحتوي صيدليات أخرى،
          //   وعرضها له يوحي أنه باعها وهي ليست له.
          if (items.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final it in items) _chip(it),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// صورة الصنف واسمه وكميته — مختصر لأن السجل قد يكون طويلاً.
  Widget _chip(Map<String, dynamic> it) {
    final img = '${it['image'] ?? ''}'.trim();
    final qty = (it['qty'] as num?)?.toInt() ?? 1;
    final name = '${it['name'] ?? 'منتج'}';
    return Container(
      width: 168,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: SizedBox(
              width: 38,
              height: 38,
              child: img.startsWith('https://')
                  ? AppImage(
                      img,
                      width: 38,
                      height: 38,
                      fit: BoxFit.cover,
                      cacheWidth: 76,
                      cacheHeight: 76,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: AppColors.surfaceTint,
                        child: Icon(Icons.image_not_supported_outlined, size: 16),
                      ),
                    )
                  : const ColoredBox(
                      color: AppColors.surfaceTint,
                      child: Icon(Icons.image_not_supported_outlined, size: 16),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                      fontSize: 11.5, fontWeight: FontWeight.w800),
                ),
                Text(
                  '$qty × ${CurrencyFormatter.format(_d(it['total']))}',
                  style: GoogleFonts.cairo(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// ★ شارة حالة طلب المندوب — بالعربية لا بمصطلح إنجليزي.
  Widget _badge(String status) {
    final (text, color) = switch (status) {
      'pending' => ('بانتظار مندوب', AppColors.warning),
      'accepted' => ('قُبل', AppColors.primary),
      'delivering' => ('في الطريق', AppColors.primary),
      'delivered' => ('وصل', AppColors.success),
      'rejected' => ('لا مندوب', AppColors.danger),
      _ => (status, AppColors.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: GoogleFonts.cairo(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }

  Widget _message(String text, {bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 12),
        child: Column(
          children: [
            Icon(
              warn
                  ? Icons.error_outline_rounded
                  : Icons.receipt_long_outlined,
              size: 54,
              color: warn ? AppColors.danger : AppColors.textHint,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 13.5,
                height: 1.8,
                fontWeight: FontWeight.w700,
                color: warn ? AppColors.danger : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}