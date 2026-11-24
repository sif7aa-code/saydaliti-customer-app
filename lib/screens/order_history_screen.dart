import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/order_display.dart';
import '../core/utils/order_elapsed.dart';
import '../services/auth_service.dart';
import '../services/catalog_cache.dart';
import '../services/supabase_service.dart';
import 'order_tracking_screen.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/order_elapsed_text.dart';

/// سجل طلباتي الحقيقي: يعرض طلبات المستخدم من قاعدة البيانات
/// (حسب رقم هاتفه) بأحدث ترتيب، وكل طلب يفتح شاشة التتبع.
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  List<Map<String, dynamic>> _orders = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// مفتاح اللقطة المحلية — **برقم الهاتف**، فحساب آخر على الجهاز نفسه
  /// لا يقرأ لقطة صاحبه.
  static String _snapKey(String phone) => 'orders_$phone';

  Future<void> _load() async {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      setState(() {
        _loading = false;
        _orders = const [];
        _error = 'سجّل الدخول لعرض طلباتك';
      });
      return;
    }
    setState(() {
      // ★ لا نُخفي ما هو ظاهر: عند السحب للتحديث كانت القائمة تختفي
      //   وتحلّ محلها دائرة تحميل، فيبدو التحديث أبطأ من الفعل نفسه.
      _loading = _orders.isEmpty;
      _error = null;
    });

    // ★ ١) اللقطة المحلية أولاً: نرسمها قبل أي رحلة شبكة.
    //
    //   كان فتح «سجل طلباتي» يعرض دائرة تدور حتى يردّ السيرفر (٦٠٠م–١٥ث
    //   حسب الشبكة). الآن القائمة القديمة تظهر في الإطار التالي مباشرة،
    //   ثم يبدّلها الردّ الطازج — نفس أسلوب الرئيسية والكتالوج.
    final snap = await CatalogCache.instance.readObject(_snapKey(phone));
    final local = snap == null
        ? const <Map<String, dynamic>>[]
        : ((snap['orders'] ?? []) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
    if (!mounted) return;
    if (local.isNotEmpty) {
      setState(() {
        _orders = local;
        _loading = false;
      });
    }

    // ★ ٢) الردّ الطازج من الشبكة.
    final orders = await SupabaseService.instance.fetchOrdersByPhone(phone);
    if (!mounted) return;
    // ★ قائمة فارغة من الشبكة لا تمسح المحتوى الجيد: `fetchOrdersByPhone`
    //   يرجع `[]` عند انقطاع الشبكة وحين لا توجد طلبات فعلاً — والفرق
    //   لا يظهر لنا، فالأأمن إبقاء المحلي وعرضه بدل شاشة «لا توجد طلبات»
    //   كاذبة. تُستبدل المحلي فقط بردّ فيه بيانات.
    final shown = orders.isEmpty && local.isNotEmpty ? local : orders;
    setState(() {
      // ★ كل الطلبات تظهر — بما فيها المُسلَّمة (أُعيد هذا بعد طلب
      //   الأدمن: «ارجع إخفاء الطلبات كما كانت»).
      _orders = shown;
      _loading = false;
      _error = shown.isEmpty ? 'لا توجد طلبات حتى الآن' : null;
    });
    if (orders.isNotEmpty) {
      unawaited(
        CatalogCache.instance.writeObject(_snapKey(phone), {'orders': orders}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'سجل طلباتي',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                // عدد البطاقات + شريط المكافآت + المسافة الفاصلة.
                itemCount:
                    _orders.length +
                    1 +
                    ((_error != null && _orders.isEmpty) ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Column(children: [const SizedBox(height: 14)]);
                  }
                  if (_error != null && _orders.isEmpty) {
                    return _EmptyState(message: _error!);
                  }
                  final order = _orders[index - 1];
                  final id = order['id'].toString();
                  return _OrderCard(
                    // مفتاح ثابت: بدونه يعيد Flutter استخدام بطاقة لطلب
                    // آخر بعد التحديث (القائمة مرتّبة تنازلياً بالتاريخ).
                    key: ValueKey<String>(id),
                    order: order,
                  );
                },
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          const Icon(
            Icons.receipt_long_outlined,
            size: 54,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// ملصق حالة الطلب.
String orderStatusLabel(String status) {
  switch (status) {
    case 'accepted':
      return 'تم قبول الطلب';
    case 'delivering':
      return 'قيد التوصيل الآن';
    case 'delivered':
      return 'تم التوصيل بنجاح';
    case 'rejected':
    case 'cancelled':
      return 'تم رفض الطلب';
    // ★ طلب وصفة لم تعتمده الصيدلية بعد: ليس «قيد الانتظار» الغامض
    //   ولا رفضاً — الزبون يعرف أن صيدليته تراجع وصفته الآن.
    case 'pharmacy_review':
      return 'بانتظار موافقة الصيدلية على الوصفة';
    default:
      return 'قيد الانتظار';
  }
}

Color orderStatusColor(String status) {
  switch (status) {
    case 'accepted':
      return AppColors.info;
    case 'delivering':
      return AppColors.primary;
    case 'delivered':
      return AppColors.success;
    case 'rejected':
    case 'cancelled':
      return AppColors.danger;
    default:
      return AppColors.warning;
  }
}

/// طلب واحد في السجل: يفتح شاشة التتبع عند النقر.
class _OrderCard extends StatefulWidget {
  const _OrderCard({super.key, required this.order});

  final Map<String, dynamic> order;

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  List<Map<String, dynamic>>? _items;
  bool _loadingItems = false;

  @override
  void didUpdateWidget(covariant _OrderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // البطاقة تُعاد استخدامها عند تغيّر ترتيب القائمة بعد التحديث.
    final oldId = oldWidget.order['id'].toString();
    if (oldId != widget.order['id'].toString()) _items = null;
  }

  Future<void> _loadItems() async {
    if (_items != null || _loadingItems) return;
    setState(() => _loadingItems = true);
    final id = widget.order['id'].toString();
    // ★ بنود الطلب محفوظة محلياً من زيارة سابقة ⇒ الملخص يكتب اسمه فوراً
    //   بدل «…»، ثم يُحدَّث من الشبكة في الخلفية.
    final snap = await CatalogCache.instance.readObject('items_$id');
    final local = snap == null
        ? null
        : ((snap['items'] ?? []) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
    if (!mounted) return;
    if (local != null && local.isNotEmpty) {
      // بنود الطلب **لقطات ثابتة** (اسم المنتج وسعره وقت الشراء) ولا
      // تتغيّر بعدها، فالنسخة المحلية تكفي بلا رحلة شبكة إضافية.
      setState(() {
        _items = local;
        _loadingItems = false;
      });
      return;
    }
    final items = await SupabaseService.instance.fetchOrderItems(id);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loadingItems = false;
    });
    if (items.isNotEmpty) {
      unawaited(
        CatalogCache.instance.writeObject('items_$id', {'items': items}),
      );
    }
  }

  String get _summary {
    final items = _items;
    if (items == null || items.isEmpty) return '…';
    if (items.length == 1) {
      return items.first['product_name']?.toString() ?? '';
    }
    final first = items.first['product_name']?.toString() ?? '';
    return '$first + ${items.length - 1} منتجات أخرى';
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final status = order['status']?.toString() ?? 'pending';
    final statusColor = orderStatusColor(status);
    final statusLabel = orderStatusLabel(status);
    final orderNumber = OrderDisplay.serial(order);
    final total = (order['total_amount'] as num?)?.toDouble() ?? 0;
    // ★ الزبون هنا يخزّن «وفّر» على كل طلب، فالمقارنة بين طلبين
    //   تتعذّر بلا رقم الخصم ظاهراً بجانب الإجمالي.
    final discountNote = OrderDisplay.discountNote(order, showCode: true);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          _loadItems();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => OrderTrackingScreen(
                orderId: order['id'].toString(),
                orderNumber: orderNumber,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      orderNumber,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      statusLabel,
                      style: GoogleFonts.cairo(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.storage_rounded,
                    color: AppColors.textHint,
                    size: 13,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      _summary,
                      style: GoogleFonts.cairo(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // ★ التاريخ وحده كان لا يُخبر الزبون شيئاً عن الانتظار:
                  //   الآن تحته «كم مضى على الطلب» مباشرة، ويتوقف عند
                  //   «استغرق…» بعد التوصيل لأن العدّاد الحيّ على طلب
                  //   وصل منذ أيام يوحي بأنه متأخر.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _fmtDate(order['created_at']?.toString()),
                          style: GoogleFonts.cairo(
                            color: AppColors.textHint,
                            fontSize: 11,
                          ),
                        ),
                        if (OrderElapsed.placedAt(order) != null) ...[
                          const SizedBox(height: 3),
                          OrderElapsedText(
                            order: order,
                            iconSize: 12,
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    CurrencyFormatter.format(total),
                    style: GoogleFonts.cairo(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              if (status == 'delivered') ...[
                const SizedBox(height: 12),
                _DeliveryStatusStrip(status: status),
              ],
              // ★ ملاحظة الخصم تحت الإجمالي مباشرة.
              if (discountNote.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.local_offer_rounded,
                      size: 14,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        discountNote,
                        style: GoogleFonts.cairo(
                          color: AppColors.success,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
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

/// ★ شريط حالة التوصيل — يعرض الخطوة الحالية فقط.
///
/// كان مكانه زرّ «تأكيد استلام الطلب»؛ حُذف الزر لأن نظام الأكواد
/// المحذوف كان هو سبب وجوده. وبقيت الحاجة الحقيقية: أن يعرف الزبون
/// أين طلبه. الشريط يعرض **خطوة واحدة** تتغيّر مع الحالة، وكل خطوة
/// تحمل رقمها ونسبتها — أوضح من شريط خطوات ملتبس.
class _DeliveryStatusStrip extends StatelessWidget {
  const _DeliveryStatusStrip({required this.status});

  final String status;

  /// الخطوة الجارية لهذا الطلب.
  ///
  /// الترتيب: pending → accepted → delivering → delivered.
  /// أي حالة أخرى (مرفوض/ملغى) ⇒ -1 أي لا شريط خطوات.
  ///
  /// ★ نفس منطق دالة `order_status_steps` على الخادم عمداً: الشريط
  ///   يعمل فوراً بلا انتظار شبكة، وقاعدة البيانات تعطي نفس الرقم
  ///   لمن يستعلم بها مباشرة. الفرق بينهما في جدول واحد فقط
  ///   (الحالة)، فاحتمال الاختلاف معدوم.
  static int _currentStep(String status) {
    switch (status) {
      case 'accepted':
        return 1;
      case 'delivering':
        return 2;
      case 'delivered':
        return 3;
      case 'pending':
        return 0;
      // ★ الصيدلية تراجع الوصفة: نفس خطوة «تم استلام الطلب» — لا
      //   شريط إلغاء أحمر يوحي بأن الطلب انتهى.
      case 'pharmacy_review':
        return 0;
      case 'rejected':
      case 'cancelled':
        // طلب غير نشط: لا معنى لشريط الخطوات.
        return -1;
      default:
        return -1;
    }
  }

  static const List<String> _steps = [
    'تم استلام الطلب',
    'قيد التجهيز',
    'مع المندوب',
    'تم التوصيل',
  ];

  @override
  Widget build(BuildContext context) {
    final step = _currentStep(status);

    // طلب غير نشط: لا شريط خطوات، بل سبب واحد واضح.
    if (step < 0) {
      return _strip(
        AppColors.danger,
        Icons.cancel_rounded,
        orderStatusLabel(status),
      );
    }

    final done = step == 3;
    final active = step < 3;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: (done ? AppColors.success : AppColors.primary).withValues(
          alpha: 0.08,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (done ? AppColors.success : AppColors.primary).withValues(
            alpha: 0.28,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                done
                    ? Icons.check_circle_rounded
                    : active
                    ? Icons.local_shipping_rounded
                    : Icons.hourglass_top_rounded,
                color: done ? AppColors.success : AppColors.primary,
                size: 17,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  done ? 'تم التوصيل بنجاح' : _steps[step],
                  style: GoogleFonts.cairo(
                    color: done ? AppColors.success : AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${step + 1} / 4',
                style: GoogleFonts.cairo(
                  color: done ? AppColors.success : AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          // شريط التقدّم: أربع خانات، المضيء منها خطوة وما قبلها.
          Row(
            children: [
              for (var i = 0; i < _steps.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: i <= step
                          ? (done ? AppColors.success : AppColors.primary)
                          : AppColors.divider,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// سطر سبب واحد (طلب مرفوض/ملغى).
  Widget _strip(Color color, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.cairo(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)}/${dt.year} — ${two(dt.hour)}:${two(dt.minute)}';
}
