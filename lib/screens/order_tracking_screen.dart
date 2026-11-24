import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/map_launcher.dart';
import '../core/utils/order_display.dart';
import '../core/utils/order_elapsed.dart';
import '../services/auth_service.dart';
import '../services/catalog_cache.dart';
import '../services/status_center.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/image_viewer.dart';
import '../widgets/order_elapsed_text.dart';

/// شاشة تتبع توصيل الطلب الحقيقية: تظهر عند النقر على أي طلب
/// من "سجل طلباتي" أو من نافذة نجاح إرسال الطلب، وتتابع حالة الطلب
/// لحظياً (قيد الانتظار → مقبول → قيد التوصيل → مكتمل / مرفوض مع السبب).
class OrderTrackingScreen extends StatefulWidget {
  const OrderTrackingScreen({
    super.key,
    required this.orderId,
    required this.orderNumber,
  });

  final String orderId;
  final String orderNumber;

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _driverName;

  /// ★ رقم المندوب آخر مرة جُلب اسمه — يمنع ١٢ طلباً/دقيقة بلا داعٍ.
  String? _lastDriverPhone;
  String? _lastStatus;

  /// ★ بصمة آخر صف طلب مقروء — أساس مقارنة «هل تغيّر شيء فعلاً?».
  String? _orderSignature;
  Timer? _statusTimer;
  bool _refreshingStatus = false;
  bool _appActive = true;

  /// ٥ ثوانٍ في المقدمة، ٣٠ في الخلفية (توفير لسجلات Supabase).
  Duration get _statusInterval =>
      _appActive ? const Duration(seconds: 5) : const Duration(seconds: 30);

  /// بصمة محتوى صف الطلب: تُجمع أعمدته وقيمه في سطر واحد.
  ///
  /// ★ لماذا؟ الشرط القديم كان `!identical(_order, order)`، وكل رحلة
  ///   شبكة تُنتج **كاشاً جديداً** من `jsonDecode` ⇒ الشرط كان صحيحاً
  ///   **دائماً**، فتُعاد بناء الشاشة كلها (بنودها وصورها) اثنتي عشرة
  ///   مرة في الدقيقة رغم أن الحالة نادراً ما تتغيّر. ومع اللقطة
  ///   المحلية صار-writing القرص يتكرر خلفها. البصمة تقيس المحتوى
  ///   نفسه: لا نبني ولا نكتب إلا عند تغيّر حقيقي.
  static String _signatureOf(Map<String, dynamic> order) =>
      order.entries.map((e) => '${e.key}=${e.value}').join('\u0001');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _startStatusTimer();
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(_statusInterval, (_) => _refreshStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) {
      _refreshStatus();
      _startStatusTimer();
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// تحديث خفيف للحالة واسم المندوب فقط دون إعادة تحميل البنود.
  Future<void> _refreshStatus() async {
    if (_refreshingStatus || _loading) return;
    _refreshingStatus = true;
    try {
      final order = await SupabaseService.instance.fetchOrderById(
        widget.orderId,
      );
      if (order == null || !mounted) return;
      final nextStatus = order['status']?.toString();

      // ★★ اسم المندوب يُجلب مرّة واحدة لا في كل نبضة.
      //   كان كل ٥ ثوانٍ يستدعي `findUser` ⇒ ١٢ طلباً/دقيقة بلا داعٍ،
      //   على شاشة يشاهدها الزبون طوال التوصيل. الآن تُجلب عند تغيّر
      //   رقم المندوب فقط — وهو نادراً ما يحدث.
      String? driverName = _driverName;
      final driverPhone = order['assigned_driver_phone']?.toString() ?? '';
      if (driverPhone.isNotEmpty && driverPhone != _lastDriverPhone) {
        final driver = await SupabaseService.instance.findUser(driverPhone);
        driverName = driver?['name']?.toString();
        _lastDriverPhone = driverPhone;
      }
      if (!mounted) return;

      // ★★ `setState` لم يكن مشروطاً عملياً قط: المقارنة كانت
      //   `!identical(_order, order)` وكل رحلة شبكة تُنتج كاشاً جديداً من
      //   `jsonDecode` ⇒ الشرط صحيح **دائماً**، فتُعاد بناء الشاشة مع كل
      //   بنودها وصورها ١٢ مرة في الدقيقة. ومع اللقطة المحلية كانت كتابة
      //   القرص تتكرر خلفها. البصمة تقيس المحتوى: لا بناء ولا كتابة إلا
      //   عند تغيّر حقيقي.
      final signature = _signatureOf(order);
      final changed =
          nextStatus != _lastStatus ||
          driverName != _driverName ||
          signature != _orderSignature;
      if (changed) {
        _orderSignature = signature;
        setState(() {
          _order = order;
          _driverName = driverName;
        });
        // اللقطة المحلية تُحدَّث مع كل تغيّر حقيقي، فيكون الفتح القادم
        // للشاشة طازجاً لا قديماً.
        _saveSnapshot(order, _items, driverName);
      }
      // تغيّر الحالة أثناء التتبّع ⇒ إشعار بصوت + سبب واضح (اسم المندوب).
      if (nextStatus != null && nextStatus != _lastStatus) {
        final first = _lastStatus == null;
        _lastStatus = nextStatus;
        if (!first) _announceStatus(order, nextStatus, driverName);
      }
    } finally {
      _refreshingStatus = false;
    }
  }

  // ── اللقطة المحلية ─────────────────────────────────────────────────────
  //
  // ★ لماذا؟ شاشة التتبع كانت تنتظر **ثلاث رحلات شبكة متتابعة**
  //   (الطلب ← بنوده ← اسم المندوب) قبل أن ترسم أي شيء، فتظهر دائرة
  //   تحميل طويلة على شبكة ضعيفة — وهو أسرع مكان يحتاجه الزبون وهو
  //   ينتظر طلبه. الآن ترسم آخر نسخة محفوظة فوراً، والرحلات نفسها
  //   تُصحّح ما بعدها في الخلفية.
  //
  // ★ لا خصوصية تُخترق: المفتاح يحمل معرف الطلب، والداخل يُخزّن رقم
  //   صاحب الطلب، ولا تُعرض اللقطة إلا إذا كان **رقم الحساب الحالي هو
  //   رقم الطلب نفسه**. ومسحها يتم عند تسجيل الخروج
  //   ([CatalogCache.clearAllObjects]).

  String get _snapKey => 'track_${widget.orderId}';

  void _saveSnapshot(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> items,
    String? driverName,
  ) {
    unawaited(
      CatalogCache.instance.writeObject(_snapKey, {
        'user_phone': order['user_phone']?.toString() ?? '',
        'order': order,
        'items': items,
        'driver_name': driverName,
      }),
    );
  }

  /// لقطة صالحة لهذا الحساب، أو null إن لم توجد أو كانت لحساب آخر.
  Future<Map<String, dynamic>?> _readSnapshot() async {
    final snap = await CatalogCache.instance.readObject(_snapKey);
    if (snap == null) return null;
    final phone = AuthService.instance.phone ?? '';
    if (phone.isEmpty) return null;
    if ((snap['user_phone'] ?? '').toString() != phone) return null;
    final raw = snap['order'];
    if (raw is! Map) return null;
    return snap;
  }

  Future<void> _load() async {
    // ★ عند السحب للتحديث يبقى المحتوى الظاهر ظاهراً: دائرة التدوير
    //   كانت تُبدّل الشاشة كاملة فارغةً في كل مرة.
    setState(() => _loading = _order == null);

    // ★ ١) رسم محلي فوري (لا يضبط `_lastStatus`: الانطلاقة الحقيقية
    //   تُحدَّد من ردّ السيرفر حتى لا يُنطق إشعار بحالة قديمة).
    final snap = await _readSnapshot();
    if (snap != null && mounted) {
      setState(() {
        _order = Map<String, dynamic>.from(snap['order'] as Map);
        _items = ((snap['items'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final name = snap['driver_name'];
        _driverName = name is String ? name : null;
        _loading = false;
      });
    }

    // ★ ٢) ثم الرحلات الثلاث كما كانت، فتُبدّل النسخة القديمة.
    final order = await SupabaseService.instance.fetchOrderById(widget.orderId);
    final items = order == null
        ? const <Map<String, dynamic>>[]
        : await SupabaseService.instance.fetchOrderItems(
            order['id'].toString(),
          );
    String? driverName;
    if (order != null) {
      final driverPhone = order['assigned_driver_phone']?.toString() ?? '';
      if (driverPhone.isNotEmpty) {
        final driver = await SupabaseService.instance.findUser(driverPhone);
        driverName = driver?['name']?.toString();
        // ★ يُسجَّل الرقم: نبضة التتبع الأولى كانت تجلب اسم المندوب
        //   **مرة ثانية** بعد الفتح، لأن المقارنة لم تكن تعرف أنه جُلب.
        _lastDriverPhone = driverPhone;
      }
    }
    if (!mounted) return;
    if (order?['status'] != null) _lastStatus = order!['status'].toString();
    if (order != null) _orderSignature = _signatureOf(order);
    setState(() {
      // ★ فشل الشبكة (order null) أو ردّ بلا بنود لا يمحو ما رسمته
      //   اللقطة الجيدة — لا نستبدل شيئاً ببيانات أقل.
      _order = order ?? _order;
      if (items.isNotEmpty) _items = items;
      if (driverName != null) _driverName = driverName;
      _loading = false;
    });
    if (order != null) _saveSnapshot(order, _items, _driverName);
  }

  /// إشعار بصوت التنبيه عند تغيّر حالة الطلب أثناء التتبّع.
  void _announceStatus(
    Map<String, dynamic> order,
    String status,
    String? driverName,
  ) {
    final info = _statusNotice(status, order, driverName);
    unawaited(
      StatusCenter.instance.broadcast(
        title: info.$1,
        body: info.$2,
        status: status,
        orderId: widget.orderId,
        sound: info.$3,
        dedupeKey: 'order:${widget.orderId}:$status',
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// (عنوان، نص، نغمة) الإشعار المناسب لكل حالة.
  (String, String, String) _statusNotice(
    String status,
    Map<String, dynamic> order,
    String? driverName,
  ) {
    final who = (driverName != null && driverName.trim().isNotEmpty)
        ? driverName.trim()
        : 'المندوب';
    final serial = OrderDisplay.serial(order);
    switch (status) {
      case 'accepted':
        return (
          'تم قبول طلبك',
          'تم قبول طلبك $serial بواسطة $who وسيصلك قريباً.',
          'accepted',
        );
      case 'delivering':
        return (
          'طلبك في الطريق',
          'المندوب $who في طريقه إليك — الطلب $serial.',
          'accepted',
        );
      case 'delivered':
        return (
          'تم توصيل طلبك',
          'تم توصيل الطلب $serial بنجاح. شكراً لتعاملك معنا.',
          'delivered',
        );
      case 'rejected':
        final why = order['rejection_reason']?.toString().trim() ?? '';
        return (
          'تم رفض الطلب',
          'تم رفض طلبك $serial — السبب: ${why.isEmpty ? 'غير محدد' : why}',
          'rejected',
        );
      case 'cancelled':
        return ('تم إلغاء الطلب', 'تم إلغاء الطلب $serial.', 'rejected');
      default:
        return ('تحديث جديد', 'تم تحديث حالة طلبك $serial.', 'alert');
    }
  }

  Future<void> _openSupport() async {
    await ContactTools.openSupport(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'تتبع الطلب ${widget.orderNumber}',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _order == null
          ? const Center(child: Text('تعذر العثور على الطلب'))
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _TrackingBody(
                order: _order!,
                items: _items,
                driverName: _driverName,
                onSupport: _openSupport,
              ),
            ),
    );
  }
}

/// محتوى التتبع: خط زمني لحالة الطلب + التفاصيل.
class _TrackingBody extends StatelessWidget {
  const _TrackingBody({
    required this.order,
    required this.items,
    required this.driverName,
    required this.onSupport,
  });

  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> items;
  final String? driverName;
  final VoidCallback onSupport;

  String get _status => order['status']?.toString() ?? 'pending';

  bool get _isRejected => _status == 'rejected' || _status == 'cancelled';

  bool get _isDelivered => _status == 'delivered';

  String get _label {
    switch (_status) {
      case 'accepted':
        return 'تم قبول الطلب';
      case 'delivering':
        return 'طلبك في الطريق';
      case 'delivered':
        return 'تم التوصيل بنجاح';
      case 'rejected':
      case 'cancelled':
        return 'تم رفض الطلب';
      // ★ طلب بوصفة: الصيدلية تراجعها قبل أن يصل للمندوبين.
      case 'pharmacy_review':
        return 'بانتظار موافقة الصيدلية على الوصفة';
      default:
        return 'قيد الانتظار';
    }
  }

  Color get _color {
    switch (_status) {
      case 'accepted':
        return AppColors.success;
      case 'delivering':
        return AppColors.info;
      case 'delivered':
        return AppColors.success;
      case 'rejected':
      case 'cancelled':
        return AppColors.danger;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = (order['total_amount'] as num?)?.toDouble() ?? 0;
    final address = order['address']?.toString() ?? '';
    // ملاحظة الزبون — تُقرأ من الطلب نفسه فتظهر فور إنشائه (قيد الانتظار)
    // وتبقى كما هي في كل المراحل حتى بعد التوصيل.
    final notes = order['notes']?.toString().trim() ?? '';
    // ★ ملاحظة الخصم تُشتقّ من الطلب نفسه لا من ذاكرة مؤقتة، فتبقى
    //   بعد إغلاق السلة وفي كل المراحل حتى بعد التوصيل.
    final discountNote = OrderDisplay.discountNote(order, showCode: true);
    final discountAmount = OrderDisplay.discount(order);
    final beforeDiscount = OrderDisplay.priceBeforeDiscount(order);
    final customerName = OrderDisplay.customerName(order);
    final serial = OrderDisplay.serial(order);
    final driverPhone = order['assigned_driver_phone']?.toString() ?? '';
    final driver = driverName == null || driverName!.isEmpty
        ? (driverPhone.isEmpty ? 'لم يُعيّن بعد' : driverPhone)
        : '$driverName ($driverPhone)';

    // تجميع البنود حسب الصيدلية.
    final shopGroups = <String, List<Map<String, dynamic>>>{};
    for (final it in items) {
      final s = it['shop_name']?.toString() ?? 'صيدلية';
      shopGroups.putIfAbsent(s, () => []).add(it);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        // بطاقة الحالة
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: AppColors.buttonGradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: _color.withValues(alpha: 0.25),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _isRejected
                        ? Icons.cancel_rounded
                        : Icons.local_shipping_rounded,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _label,
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _isRejected
                    ? 'تعذّر إيصال طلبك هذا المرة.'
                    : (_isDelivered
                          ? 'وصل طلبك بنجاح إلى العنوان المحدد.'
                          : 'سنتابع حالة طلبك لحظة بلحظة ونحدّثها لك تلقائياً.'),
                style: GoogleFonts.cairo(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              // رقم الطلب التسلسلي واسم الزبون.
              Row(
                children: [
                  const Icon(Icons.tag_rounded, color: Colors.white, size: 15),
                  const SizedBox(width: 5),
                  Text(
                    serial,
                    style: GoogleFonts.cairo(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Icon(
                    Icons.person_rounded,
                    color: Colors.white,
                    size: 15,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      customerName,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              // ★ «كم صارله طلبي؟»: وقت الإرسال وكم مضى عليه في بطاقة
              //   الحالة نفسها، لأن الزبون يسألها قبل أي تفصيل آخر.
              //   النص يتحرّك وحده فلا يحتاج انتظار دورة التحديث.
              //   وبعد التوصيل يقف العدّاد ويتغيّر اللفظ إلى «استغرق».
              if (OrderElapsed.placedAt(order) != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.schedule_rounded,
                      color: Colors.white,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'أُرسل ${OrderElapsed.clock(order['created_at'])}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: OrderElapsedText(
                        order: order,
                        showIcon: false,
                        style: GoogleFonts.cairo(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_isRejected) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.danger.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.block_rounded,
                  color: AppColors.danger,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'سبب الرفض: ${order['rejection_reason']?.toString() ?? 'غير محدد'}',
                    style: GoogleFonts.cairo(
                      color: AppColors.danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),

        // الخط الزمني
        Text(
          'مسار تتبع توصيل الطلب',
          style: GoogleFonts.cairo(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        _TimelineStep(
          icon: Icons.receipt_long_rounded,
          title: 'تم استلام الطلب',
          subtitle: _fmt(order['created_at']?.toString()),
        ),
        _TimelineStep(
          icon: Icons.storefront_rounded,
          title: 'تم قبول الطلب',
          subtitle: _status == 'pharmacy_review'
              ? 'بانتظار موافقة الصيدلية على الوصفة'
              : _status == 'pending'
              ? 'بانتظار موافقة المندوب'
              : _fmt(order['accepted_at']?.toString()),
          titleColor: _isRejected ||
                  _status == 'pending' ||
                  _status == 'pharmacy_review'
              ? AppColors.textSecondary
              : AppColors.primary,
          active: !_isRejected &&
              _status != 'pending' &&
              _status != 'pharmacy_review',
          last: false,
        ),
        _TimelineStep(
          icon: Icons.delivery_dining_rounded,
          title: 'طلبك في الطريق',
          subtitle: ['accepted', 'pending', 'pharmacy_review'].contains(_status)
              ? 'لم يبدأ التوصيل بعد'
              : _isRejected
              ? 'لم يبدأ التوصيل'
              : _fmt(order['delivering_at']?.toString()),
          titleColor: _status == 'delivering' || _status == 'delivered'
              ? AppColors.primary
              : AppColors.textSecondary,
          active: _status == 'delivering' || _status == 'delivered',
          last: false,
        ),
        _TimelineStep(
          icon: Icons.flag_rounded,
          title: 'تم التوصيل',
          subtitle: _status == 'delivered'
              ? _fmt(order['delivered_at']?.toString())
              : 'بعد اكتمال التوصيل بنجاح',
          titleColor: _status == 'delivered'
              ? AppColors.success
              : AppColors.textSecondary,
          active: _status == 'delivered',
          last: true,
        ),
        const SizedBox(height: 20),

        // المندوب الذي استلم الطلب
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primaryLight.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'مندوب التوصيل',
                      style: GoogleFonts.cairo(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      driver,
                      style: GoogleFonts.cairo(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                _isRejected ? Icons.block_rounded : _deliveryIcon,
                color: _color,
                size: 22,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // المنتجات
        _SectionTitle('تفاصيل الطلب'),
        const SizedBox(height: 8),
        if (shopGroups.isEmpty)
          Text(
            'لا توجد منتجات',
            style: GoogleFonts.cairo(color: AppColors.textHint),
          )
        else
          for (final entry in shopGroups.entries)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
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
                      const Icon(
                        Icons.storefront_rounded,
                        color: AppColors.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.key,
                          style: GoogleFonts.cairo(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final it in entry.value)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          _TrackThumb(image: it['product_image']?.toString()),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  it['product_name']?.toString() ?? 'منتج',
                                  style: GoogleFonts.cairo(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'سعر القطعة: ${CurrencyFormatter.format((it['price'] as num?)?.toDouble() ?? 0)}',
                                  style: GoogleFonts.cairo(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'عدد ${(it['quantity'] as num?)?.toInt() ?? 1}',
                            style: GoogleFonts.cairo(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        const SizedBox(height: 8),
        // ── ملاحظة الزبون: تظهر له ثابتة منذ لحظة إنشاء الطلب ──
        // وقبل قبوله/توصيله، وتبقى ظاهرة حتى بعد الاستلام.
        if (notes.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.info.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.info.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.sticky_note_2_rounded,
                  color: AppColors.info,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ملاحظتي للطلب',
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: AppColors.info,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notes,
                        style: GoogleFonts.cairo(
                          fontSize: 12.5,
                          height: 1.6,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (address.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceTint.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  color: AppColors.primary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    address,
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // فتح الموقع في Waze أو خرائط Google.
                InkWell(
                  onTap: () => MapLauncher.show(
                    context,
                    latitude: order['latitude'],
                    longitude: order['longitude'],
                    address: address,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.navigation_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'افتح الموقع',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        // ★ ملاحظة الخصم تسبق «إجمالي الطلب» مباشرة: هكذا يقرأها
        // الزبون قبل الرقم فيفهم لماذا هو أقل من مجموع البنود.
        if (discountNote.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.success.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.local_offer_rounded,
                  color: AppColors.success,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    discountNote,
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      height: 1.6,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        // ★ تفصيل السعر: «سعر الطلب بعد الخصم» محفوظاً ومرئياً باسمه.
        //   `total_amount` في الصف هو المدفوع بعد الخصم أصلاً، فيُعرض
        //   تحت عنوان «السعر بعد الخصم» لا تحت «إجمالي» مبهم، ومعه
        //   الأصلي ومبلغ الكود من نفس الصف — فبلا عمود جديد ولا SQL.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.18),
            ),
          ),
          child: discountAmount <= 0
              // بلا كود: السطر الواحد كما كان، فلا حشو أصفار.
              ? _PriceLine(
                  label: 'إجمالي الطلب',
                  value: CurrencyFormatter.format(total),
                  color: AppColors.primary,
                  icon: Icons.payments_rounded,
                  strong: true,
                  bigValue: true,
                )
              : Column(
                  children: [
                    _PriceLine(
                      label: 'سعر الطلب قبل الخصم',
                      value: CurrencyFormatter.format(beforeDiscount),
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(height: 9),
                    _PriceLine(
                      label: 'الخصم',
                      value: '- ${CurrencyFormatter.format(discountAmount)}',
                      color: AppColors.success,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 11),
                      child: Divider(
                        color: AppColors.divider,
                        thickness: 1,
                        height: 1,
                      ),
                    ),
                    _PriceLine(
                      label: 'السعر بعد الخصم',
                      value: CurrencyFormatter.format(total),
                      color: AppColors.primary,
                      icon: Icons.payments_rounded,
                      strong: true,
                      bigValue: true,
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 20),

        // خدمة العملاء — إنستغرام
        OutlinedButton.icon(
          onPressed: onSupport,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF25D366),
            side: const BorderSide(color: Color(0xFF25D366)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: const Icon(Icons.chat_bubble_rounded, size: 18),
          label: Text(
            'خدمة العملاء (إنستغرام)',
            style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  IconData get _deliveryIcon {
    switch (_status) {
      case 'delivered':
        return Icons.check_circle_rounded;
      case 'delivering':
        return Icons.delivery_dining_rounded;
      case 'accepted':
        return Icons.storefront_rounded;
      default:
        return Icons.hourglass_empty_rounded;
    }
  }
}

/// ★ سطر سعر: عنوان على اليمين ومبلغ على اليسار، داخل بطاقة السعر.
///
///   بلا خلفية ولا ظل داخل البطاقة — الفرق بين «قبل» و«بعد» يُقرأ من
///   ثقل الخط ولون المبلغ وحدهما (قاعدة الأسطح المسطّحة)، فالتفصيل
///   ثلاثة أسطر متتالية لا ثلاث بطاقات.
///
///   [color] للمبلغ والأيقونة فقط؛ عنوان السطر المطوي يبقى رمادياً
///   الهادئ ليظلّ «السعر بعد الخصم» هو الوحيد الثقيل الأخضر.
class _PriceLine extends StatelessWidget {
  const _PriceLine({
    required this.label,
    required this.value,
    required this.color,
    this.icon,
    this.strong = false,
    this.bigValue = false,
  });

  final String label;
  final String value;
  final Color color;
  final IconData? icon;
  final bool strong;
  final bool bigValue;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: strong ? FontWeight.w900 : FontWeight.w700,
              color: strong ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.cairo(
            fontSize: bigValue ? 16 : 13.5,
            fontWeight: bigValue ? FontWeight.w900 : FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: GoogleFonts.cairo(
        fontSize: 15,
        fontWeight: FontWeight.w900,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.titleColor,
    this.active = true,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color? titleColor;
  final bool active;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? (titleColor ?? AppColors.primary)
        : AppColors.textHint;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    color: active
                        ? color.withValues(alpha: 0.35)
                        : AppColors.divider,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: active
                          ? AppColors.textPrimary
                          : AppColors.textHint,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '—';
  final l = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} — ${two(l.hour)}:${two(l.minute)}';
}

/// صورة المنتج في شاشة التتبع.
class _TrackThumb extends StatelessWidget {
  const _TrackThumb({this.image});

  final String? image;

  @override
  Widget build(BuildContext context) {
    final hasImage = image != null && image!.trim().isNotEmpty;
    return Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.imageBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.imageBorder),
      ),
      child: hasImage
          ? TappableImage(
              url: image,
              title: 'صورة المنتج',
              child: AppImage(
                image!,
                fit: BoxFit.cover,
                cacheWidth: 300,
                cacheHeight: 300,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.fastfood_rounded,
                  color: AppColors.textHint,
                  size: 18,
                ),
              ),
            )
          : const Icon(
              Icons.fastfood_rounded,
              color: AppColors.textHint,
              size: 18,
            ),
    );
  }
}
