import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/driver_wallet_pending.dart';
import '../core/utils/exit_confirm.dart';
import '../core/utils/map_launcher.dart';
import '../core/utils/order_display.dart';
import '../core/utils/order_elapsed.dart';
import '../services/auth_service.dart';
import '../services/notification_sound.dart';
import '../services/realtime_service.dart';
import '../services/status_center.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/image_viewer.dart';
import '../widgets/order_elapsed_text.dart';
import '../widgets/welcome_banner.dart';

/// اسمي كما هو في حسابي — يظهر للزبون: «تم قبول طلبك بواسطة مصطفى».
/// مشترك بين شاشة الطلبات وورقة تفاصيل الطلب.
String get _myDriverName {
  final n = AuthService.instance.name?.trim() ?? '';
  if (n.isNotEmpty) return n;
  return AuthService.instance.phone ?? '';
}

/// شاشة المندوب: قائمة سفلية فقط (متاحة / قيد التنفيذ / مكتمل / مرفوض).
/// عند قبول الطلب تُعرض المعلومات كاملة (الصيدليات، الأوقات، الموقع على الخرائط)
/// مع إمكانية الرفض مع السبب، وتسجيل خروج مؤكَّد.
class DriverOrdersScreen extends StatefulWidget {
  const DriverOrdersScreen({super.key});

  @override
  State<DriverOrdersScreen> createState() => _DriverOrdersScreenState();
}

class _DriverOrdersScreenState extends State<DriverOrdersScreen>
    with WidgetsBindingObserver {
  int _tabIndex = 0;

  /// ★ متحكّم قائمة المندوب: النقرة على أي زرّ من القائمة السفلية تصعد
  ///   بها لأول طلب (انظر [_onNavTap]).
  final ScrollController _listScroll = ScrollController();
  bool _navBusy = false;
  bool _loading = true;
  List<Map<String, dynamic>> _available = [];

  /// ★ `true` = آخر قراءة للمتاحة **سقطت** (لم يقرأها الجهاز أصلاً)،
  ///   فالفارغ هنا ليس «لا طلبات عندك» والشاشة تقول ذلك بصريح العبارة.
  bool _availableReadFailed = false;

  List<Map<String, dynamic>> _inProgress = [];
  List<Map<String, dynamic>> _completed = [];
  List<Map<String, dynamic>> _rejected = [];

  String get _myPhone => AuthService.instance.phone ?? '';

  /// ★ محفظة المندوب: `null` = ما زلنا نسأل أو فشل الطلب.
  ///   العرض الفاشل لا يُظهر صفراً — المندوب يظن أن رصيده صفر،
  ///   وهذا تضليل ماليّ أسوأ من الفراغ.
  Map<String, dynamic>? _wallet;
  bool _walletBusy = false;
  String? _walletError;

  Future<void> _loadWallet() async {
    if (_walletBusy) return;
    setState(() => _walletBusy = true);
    final res = await SupabaseService.instance.fetchDriverWallet(_myPhone);
    if (!mounted) return;
    setState(() {
      _walletBusy = false;
      _wallet = res;
      // ★ نخزّن سبب التعذّر: «جارِ فتح» بلا نهاية كانت تُعرض لأن
      //   الدالة غير مثبّتة، وهو عطل يحتاج Solution لا انتظاراً.
      _walletError = SupabaseService.instance.lastDriverWalletError;
    });
  }

  Timer? _pollTimer;
  bool _polling = false;
  bool _appActive = true;

  /// ★ فترة استطلاع الطلبات. أطول في الخلفية لتوفير سجلات Supabase،
  ///   لأن الإشعار يصل حينها عبر FCM.
  ///
  ///   مع البثّ الحيّ (`RealtimeService`) لم يعد الاستطلاع وسيلة
  ///   الوصول — هو شبكة أمان فقط عند انقطاع البث صامتاً، لذلك خُفّض
  ///   من ١٥ إلى ٨ ثوانٍ (طلب ٢٠٢٦-١٠-١٠: «خفّض مدة انتظار الفحص»):
  ///   أسوأ حال عند انقطاع البث ٨ ثوانٍ بدل ١٥، وبلا بثّ ٥ لا ٦.
  Duration get _pollInterval {
    if (!_appActive) return const Duration(seconds: 20);
    return RealtimeService.instance.isConnected
        ? const Duration(seconds: 8)
        : const Duration(seconds: 5);
  }

  /// ★ اشتراك البثّ: حدث `order.new` / `order.status` من السيرفر.
  StreamSubscription<RealtimeEvent>? _rtSub;

  /// ★★ دمج أحداث البث المتقاربة (تقليل استهلاك بلا تغيير سلوك):
  ///   دفعة قبول/تحديث قد تُرسل عدة أحداث متتالية، فكان كل حدث يستدعي
  ///   `_poll()` ⇒ استطلاعات متتابعة لنفس النتيجة. نؤخر ٧٠٠ms وندمج.
  Timer? _rtPollDebounce;

  /// معرّفات طلبات حُسمت على هذا الجهاز: قُبلت فعلاً، أو ثبت أن
  /// مندوباً آخر أخذها. لا يُعاد إرسال إجراء عليها إطلاقاً — وهذا هو
  /// منع «تكرار القبول» من بطاقة قديمة ما زالت معروضة على الشاشة.
  final Set<String> _settled = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AuthService.instance.refreshFromServer();
    _load();
    _loadWallet();
    _startPolling();
    _listenRealtime();
  }

  /// ★ البثّ الفوري بدل الانتظار: السيرفر ينشر `order.new` لكل
  ///   المندوبين المتصلين في نفس اللحظة، فتُجلب القائمة عند وصوله
  ///   مباشرة — بلا انتظار دورة الاستطلاع (كانت ٦ ثوانٍ).
  ///
  ///   و`order.status` يسحب البطاقة من «متاح» لحظة قبولها من زميل،
  ///   مع رسالة صريحة بدل أن يضغط المندوب على طلبٍ لم يعد موجوداً.
  void _listenRealtime() {
    _rtSub?.cancel();
    _rtSub = RealtimeService.instance.events.listen((e) {
      if (!mounted) return;
      if (e.topic == RtEvent.orderNew) {
        _schedulePoll();
        return;
      }
      if (e.topic != RtEvent.orderStatus) return;

      final id = e.data['id']?.toString() ?? '';
      final status = e.data['status']?.toString() ?? '';
      final driver = e.data['driverPhone']?.toString().trim() ?? '';
      if (id.isEmpty || status == 'pending') return;

      // البطاقة كانت معروضة عندي «متاحة» ثم أخذها زميل ⇒ نُخبره بها.
      final wasMineToSee = _available.any((o) => o['id']?.toString() == id);
      _settled.add(id);
      _dropFromList(_available, id);
      if (driver.isNotEmpty && driver != _myPhone) {
        _dropFromList(_inProgress, id);
      }
      if (wasMineToSee && status != 'rejected' && status != 'cancelled') {
        final serial = e.data['serial']?.toString().trim() ?? '';
        _showMessage(
          serial.isEmpty
              ? 'تم القبول من قبل مندوب آخر'
              : 'الطلب $serial تم القبول من قبل مندوب آخر',
          false,
        );
      }
      _schedulePoll();
    });
    RealtimeService.instance.start();
  }

  void _schedulePoll() {
    _rtPollDebounce?.cancel();
    _rtPollDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_poll());
    });
  }

  /// يسحب طلباً من قائمة محلية (القوائم الفارغة قد تكون `const []`).
  void _dropFromList(List<Map<String, dynamic>> list, String id) {
    if (list.isEmpty) return;
    final before = list.length;
    list.removeWhere((o) => o['id']?.toString() == id);
    if (list.length != before && mounted) setState(() {});
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (_appActive) _poll();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) {
      // العودة للتطبيق ⇒ جلب فوري + استئناف سرعة الاستطلاع.
      _load();
      _startPolling();
    }
  }

  @override
  void dispose() {
    _rtPollDebounce?.cancel();
    _pollTimer?.cancel();
    _listScroll.dispose();
    unawaited(_rtSub?.cancel());
    _rtSub = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// تحديث قائمة الطلبات المتاحة فقط دون إظهار مؤشر التحميل.
  /// ★ كان `if (_polling || _tabIndex != 0) return;` — أي أن الاستطلاع
  ///   يتوقف كلياً ما دام المندوب في تبويب غير الأول. فطلب جديد لا
  ///   يظهر إلا بعد رجوعه للتبويب الأول. الآن يعمل في كل التبويبات.
  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final pending = await SupabaseService.instance.fetchPendingOrders();
      if (!mounted) return;
      // ★ قراءة ساقطة ≠ «لا طلبات»: القائمة ما كانت معروضة تبقى كما هي
      //   ويظهر سطر الصراحة بدل أن تُمحى أمام المندوب فيسمع الرنّة ويرى
      //   شاشة فارغة.
      final failed = SupabaseService.instance.pendingOrdersReadFailed;
      if (failed) {
        if (!_availableReadFailed) setState(() => _availableReadFailed = true);
        return;
      }
      final current = _available;
      _available = pending;
      _pruneSettled(pending);
      if (listEqualsIds(current, pending) && !_availableReadFailed) return;
      setState(() => _availableReadFailed = false);
    } finally {
      _polling = false;
    }
  }

  /// ★ إعادة فتح طلب محسوم: إذا رجّعه الأدمن إلى «معلّق» أو أزال
  ///   إسناد المندوب، يعود ظاهراً في القائمة المجدولة — فيُرفع عنه
  ///   منع التكرار، وإلا بقي المندوب يقرأ «تم القبول من مندوب آخر»
  ///   على طلب متاح فعلاً.
  void _pruneSettled(List<Map<String, dynamic>> pending) {
    if (_settled.isEmpty) return;
    final open = pending.map((o) => o['id'].toString()).toSet();
    _settled.removeWhere(open.contains);
  }

  /// مقارنة خفيفة بمعرّفات الطلبات لتجنب إعادة الرسم المتكررة.
  static bool listEqualsIds(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i]['id'].toString() != b[i]['id'].toString()) return false;
    }
    return true;
  }

  /// يحدّث القوائم من السيرفر.
  ///
  /// [silent] = تحديث خلفي بعد ضغط زر: **لا** نوقف الشاشة ولا نخفي
  /// القائمة الأصلاً، لأن `_applyLocalUpdate` طبّق التغيير محلياً فوراً.
  /// بدون هذا كان كل ضغطة تُظهر سبينراً كاملاً بانتظار ٥ طلبات شبكة،
  /// فيبدو الزر «ثقيلاً» رغم أن العملية تمت في جزء من الثانية.
  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    final phone = _myPhone;
    final results = await Future.wait([
      // ★ الطلبات المتاحة = العادية + طلبات المندوب الحر.
      //  كانت تستدعي fetchFreeDriverRequests في تبويب خامس منفصل،
      //  فظهر الطلب مرتين واختفى عند تبديل التبويب.
      SupabaseService.instance.fetchPendingOrders(),
      SupabaseService.instance.fetchOrders(
        'status=in.(accepted,delivering)&assigned_driver_phone=eq.$phone',
      ),
      // ★ «كل مندوب وطلباته»: المنتهية تُقرأ مسندة لرقمه، لا عامة.
      //   كان «مكتمل» و«مرفوض» يُجلبان بلا فلتر، فيشتبك تبويبا المنتهي
      //   عند كل مندوب بطلبات بقية المندوبين وكل رفض في النظام —
      //   بما فيها إلغاءات الإدارة.
      SupabaseService.instance.fetchMyDeliveredOrders(phone),
      SupabaseService.instance.fetchMyRejectedOrders(phone),
    ]);
    if (!mounted) return;
    // ★ المتاحة وحدها تُحفَظ عند سقوط قراءتها: القائمة التي يراها المندوب
    //   الآن أثمن من أن تُمحى بردّ شبكة فاشل — والفارغ الكاذب هو «صوت بلا
    //   شيء» الذي شكا منه.
    final availableFailed = SupabaseService.instance.pendingOrdersReadFailed;
    setState(() {
      _availableReadFailed = availableFailed;
      if (!availableFailed) {
        _available = results[0];
        _pruneSettled(results[0]);
      }
      _inProgress = results[1];
      _completed = results[2];
      _rejected = results[3];
      if (!silent) _loading = false;
    });
  }

  /// ★ نقرة زرّ من القائمة السفلية للمندوب: تصعد لأول طلب في التبويب،
  ///   ثم تعمل جلباً حقيقياً **بصمت** — بلا سبينر يبتلع القائمة التي
  ///   يقرأها الآن — وتُسمع رنّة التحديث إذا نجح الجلب.
  void _onNavTap(int i) {
    setState(() => _tabIndex = i);
    if (_listScroll.hasClients) {
      try {
        if (_listScroll.position.pixels > 1) {
          _listScroll.animateTo(
            0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        }
      } catch (_) {
        // موضعٌ يُعاد بناؤه أو قائمة لا تمرّر: الصعود تجميلي.
      }
    }
    if (_navBusy) return;
    _navBusy = true;
    unawaited(
      AppRefresh.run(
        () => _load(silent: true),
      ).catchError((Object _) {}).whenComplete(() => _navBusy = false),
    );
  }

  /// ★ سبب الفشل بلغة يفهمها المندوب: «انتهت مهلة الاتصال» و«تحقّق
  ///   من الإنترنت» أفضل من Exception خام داخل رسالة للمستخدم.
  String _reason(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return 'تعذر الاتصال بالسيرفر — أعد المحاولة';
    if (s.contains('TimeoutException')) {
      return 'انتهت مهلة الاتصال — تحقق من الإنترنت وحاول';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup')) {
      return 'لا يوجد اتصال بالإنترنت — تحقق من الشبكة';
    }
    // ★★ رفض RLS (403) **ليس** انتهاء جلسة. كان كل 403 يُعرض
    //   «انتهت صلاحية الجلسة» فيُطلب من المندوب تسجيل دخول بلا
    //   سبب — والسبب الحقيقي هو: هذا الإجراء خارج صلاحياتك.
    if (s.contains('row-level security') ||
        s.contains('42501') ||
        s.contains('violates row-level')) {
      return 'لا تملك صلاحية لهذا الإجراء — راجع الإدارة';
    }
    if (s.contains('HTTP 401')) {
      return 'انتهت صلاحية الجلسة — سجّل الدخول من جديد';
    }
    if (s.contains('HTTP 403')) {
      return 'ممنوع من القاعدة لهذا الإجراء — راجع الإدارة';
    }
    if (s.startsWith('HTTP 4')) return 'رفض الخادم الطلب ($s)';
    if (s.startsWith('HTTP 5')) return 'خطأ في الخادم ($s)';
    return 'فشل الاتصال — $s';
  }

  void _showMessage(String msg, bool ok) {
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
        ),
      );
  }

  Future<void> _openMap(Map<String, dynamic> order) async {
    await MapLauncher.show(
      context,
      latitude: order['latitude'],
      longitude: order['longitude'],
      address: order['address']?.toString() ?? '',
    );
  }

  /// معرّف الطلب الجاري تنفيذ إجراء عليه.
  ///
  /// كان النقر يُرسل الطلب للشبكة أولاً بلا أي تغيير مرئي ولا تعطيل للزر،
  /// فيبدو معطّلاً من ٣٠٠ ملّي إلى ٣ ثوانٍ، والنقر المزدوج يطلق الطلب مرتين.
  String? _busyId;

  bool _isBusy(String id) => _busyId == id;

  Future<void> _reject(Map<String, dynamic> order) async {
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'سبب رفض الطلب',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: TextField(
          controller: reasonCtrl,
          maxLines: 3,
          textAlign: TextAlign.right,
          decoration: InputDecoration(
            hintText: 'اكتب سبب الرفض...',
            hintStyle: GoogleFonts.cairo(
              color: AppColors.textHint,
              fontWeight: FontWeight.w600,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              reasonCtrl.text.trim().isEmpty ? null : reasonCtrl.text.trim(),
            ),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'تأكيد الرفض',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (reason == null) return;
    if (!mounted) return;
    setState(() => _busyId = order['id'].toString());
    final res = await SupabaseService.instance.rejectOrder(
      order['id'].toString(),
      reason,
      driverName: _myDriverName,
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    _handleResult(
      res,
      order,
      ok: 'تم رفض الطلب',
      conflict: 'هذا الطلب قُبل من مندوب آخر قبل الرفض',
    );
  }

  Future<void> _accept(Map<String, dynamic> order) async {
    final id = order['id'].toString();
    // ★ منع تكرار القبول: بطاقة سبق وحُسمت (أخذها زميل) لا تُرسل
    //   مرة أخرى — يُسحب صفها وتُقال له الجملة الصريحة فوراً.
    if (_settled.contains(id)) {
      _dropFromList(_available, id);
      _showMessage('تم القبول من قبل مندوب آخر', false);
      return;
    }
    if (_isBusy(id)) return;
    // تعطيل فوري + إعادة بناء لعرض الانشغال قبل أول طلب شبكة.
    setState(() => _busyId = id);
    // ★ الأصناف تُجلب **بالتوازي** مع نداء القبول. لو تُرك جلبها لما بعد
    //   النجاح لأنتظر المندوب round-trip ثانياً قبل أن تظهر صفحة
    //   المنتجات، والمطلوب «افتحها فوراً بلا تأخير».
    final items = SupabaseService.instance.fetchOrderItems(id);
    final res = await SupabaseService.instance.acceptOrder(
      id,
      _myPhone,
      driverName: _myDriverName,
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    _handleResult(
      res,
      order,
      ok: 'تم قبول الطلب',
      conflict: 'تم القبول من قبل مندوب آخر',
    );
    if (res.result != OrderUpdateResult.success) return;
    // ★ صفحة المنتجات تُفتح من نفس البطاقة التي ضغطها، بلا نقرة ثانية.
    _showDetails(order, items: await items);
  }

  Future<void> _startDelivering(Map<String, dynamic> order) async {
    final id = order['id'].toString();
    if (_isBusy(id)) return;
    setState(() => _busyId = id);
    final res = await SupabaseService.instance.startDelivering(
      id,
      _myPhone,
      driverName: _myDriverName,
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    _handleResult(
      res,
      order,
      ok: 'بدأ التوصيل',
      conflict: 'تم الاستلام من قبل مندوب آخر',
    );
  }

  Future<void> _complete(Map<String, dynamic> order) async {
    final id = order['id'].toString();
    if (_isBusy(id)) return;
    setState(() => _busyId = id);
    final res = await SupabaseService.instance.completeOrder(id, _myPhone);
    if (!mounted) return;
    setState(() => _busyId = null);
    // ★ التسليم هو اللحظة التي يملأ فيها الترايجر المحفظة، فنجلبها
    //   فوراً — وإلا بقي الرقم القديم حتى تحديث الصفحة.
    if (res.isSuccess) _loadWallet();
    _handleResult(
      res,
      order,
      ok: 'تم إنهاء التوصيل',
      conflict: 'تم تسليم هذا الطلب من قبل مندوب آخر',
    );
  }

  /// يحدّث الصف فوراً بالوقت الحقيقي قبل جلب القائمة من السيرفر.
  void _applyLocalUpdate(Map<String, dynamic> order, OrderUpdate res) {
    if (!res.isSuccess || res.at == null) return;
    final id = order['id']?.toString();
    final status = res.status;
    final at = res.at;
    for (final list in [_available, _inProgress, _completed, _rejected]) {
      for (var i = 0; i < list.length; i++) {
        if (list[i]['id']?.toString() != id) continue;
        list[i]['status'] = status;
        list[i][switch (status) {
              'accepted' => 'accepted_at',
              'delivering' => 'delivering_at',
              'delivered' => 'delivered_at',
              _ => 'rejection_at',
            }] =
            at;
        if (status == 'accepted') {
          list[i]['assigned_driver_phone'] = _myPhone;
        }
        if (list[i]['accepted_at'] == null && status != 'rejected') {
          list[i]['accepted_at'] = at;
        }
      }
    }
  }

  void _handleResult(
    OrderUpdate res,
    Map<String, dynamic> order, {
    required String ok,
    required String conflict,
  }) {
    switch (res.result) {
      case OrderUpdateResult.success:
        _applyLocalUpdate(order, res);
        final affectedId = order['id']?.toString().trim() ?? '';
        // ★ القبول الناجح يُخرج البطاقة من «متاح» في نفس اللحظة:
        //   لا تبقى قابلة للضغط مرة ثانية قبل وصول التحديث الصامت.
        if (res.status == 'accepted') {
          if (affectedId.isNotEmpty) {
            _settled.add(affectedId);
            _dropFromList(_available, affectedId);
          }
        }
        // ★ الرفض يُخرج البطاقة من «متاح» و«قيد التنفيذ» معاً في نفس
        //   اللحظة: كانت تبقى ظاهرة في «قيد التنفيذ» حتى ينتهي التحديث
        //   الخلفي، فيعود ضغط زرّ عليها على طلب لم يعد له وجود.
        if (res.status == 'rejected') {
          if (affectedId.isNotEmpty) {
            _settled.add(affectedId);
            _dropFromList(_available, affectedId);
            _dropFromList(_inProgress, affectedId);
          }
        }
        _statusNotice(ok, order, res.status);
        break;
      case OrderUpdateResult.conflict:
        // ★ لم يعد الطلب متاحاً ولا مسنداً إليّ: يُسحب من «متاح»
        //   ويُعلَّم كمحسوم، فلا يُعاد إرسال الإجراء عليه من بطاقة
        //   قديمة معروضة على الشاشة.
        final takenId = order['id']?.toString().trim() ?? '';
        if (takenId.isNotEmpty) {
          _settled.add(takenId);
          _dropFromList(_available, takenId);
        }
        _showMessage(conflict, false);
        break;
      case OrderUpdateResult.failed:
        // ★ نُظهر السبب الحقيقي بدل «تعذر الاتصال بالسيرفر» التي
        //   كانت تُقال لكل شيء: ٤٠٠ و٤٠١ و٥٠٠ وتــ_Result والانتظار
        //   والتطبيق على بيانات متقطّعة — كلها نفس الجملة، فلا
        //   يستطيع المستخدم أن يفعل شيئاً ولا نحن أن نصلح.
        _showMessage(
          _reason(SupabaseService.instance.lastOrderUpdateError),
          false,
        );
        break;
    }
    if (mounted) setState(() {});
    // تحديث خلفي بلا سبينر — الواجهة تبقى حسّاسة للضغط فوراً.
    unawaited(_load(silent: true));
  }

  /// ★ إشعار داخلي ينزل من الأعلى بحالة الطلب، لحظة وقوعها على يديه.
  ///
  ///   النغمة القصيرة وحدها تبقى، وهي تختلف لكل حالة.
  void _statusNotice(
    String title,
    Map<String, dynamic> order,
    String? status,
  ) {
    final id = order['id']?.toString().trim() ?? '';
    StatusCenter.instance.broadcast(
      title: title,
      body: _statusLine(order, status),
      status: status,
      orderId: id.isEmpty ? null : id,
      dedupeKey: id.isEmpty ? null : 'driver-action:$id:$status',
      playSound: false,
    );
    unawaited(NotificationSound.instance.playRaw(status));
  }

  /// جملة الحالة بصيغة المندوب: الطلب صار **عنده**، لا «طلبك» عند الزبون.
  String _statusLine(Map<String, dynamic> order, String? status) {
    final which = 'الطلب ${OrderDisplay.serial(order)}';
    return switch ((status ?? '').trim()) {
      'accepted' => '$which صار عندك',
      'delivering' => '$which صار قيد التوصيل',
      'delivered' => '$which تم تسليمه',
      'rejected' => '$which تم رفضه',
      _ => 'تحديث حالة $which',
    };
  }

  /// ورقة تفاصيل الطلب بمنتجاته.
  ///
  /// [items] تُمرَّر جاهزة عند القبول (جُلبت بالتوازي مع نداء القبول)
  /// فيُفتح الشريط في نفس اللحظة بلا انتظار شبكة.
  Future<void> _showDetails(
    Map<String, dynamic> order, {
    List<Map<String, dynamic>>? items,
  }) async {
    final rows =
        items ??
        await SupabaseService.instance.fetchOrderItems(
          order['id'].toString(),
        );
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _OrderDetailsSheet(
        order: order,
        items: rows,
        onMap: () => _openMap(order),
        onAccept: () {
          Navigator.pop(ctx);
          _accept(order);
        },
        onReject: () {
          Navigator.pop(ctx);
          _reject(order);
        },
        onStartDelivering: () {
          Navigator.pop(ctx);
          _startDelivering(order);
        },
        onComplete: () {
          Navigator.pop(ctx);
          _complete(order);
        },
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تسجيل الخروج',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل تريد الخروج من التطبيق؟',
          style: GoogleFonts.cairo(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'خروج',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AuthService.instance.logout();
    // ★ بلا `pushAndRemoveUntil`: يحذف `home` معه فيصير
    //   `LoginScreen` مساراً لا يُعاد بناؤه بعد الدخول ⇒Restart
    //   إجباري. `logout()` وحده يكفي عبر `notifyListeners`.
  }

  Widget _body() {
    // ★ أربعة تبويبات فقط. كان الخامس «طلب مندوب» منفصلاً ومكرراً.
    final lists = [_available, _inProgress, _completed, _rejected];
    final current = lists[_tabIndex.clamp(0, lists.length - 1)];
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (current.isEmpty) {
      final messages = [
        // ★ الفاشل يقول نفسه: «لا توجد طلبات» كذبةٌ حين تكون القراءة
        //   قد سقطت — فالمندوب يصدّقها ويقعد بلا عمل وهو ينتظر.
        _availableReadFailed
            ? 'تعذّر جلب الطلبات — تحقّق من الاتصال، وسحبُ القائمة يُعيد المحاولة'
            : 'لا توجد طلبات متاحة حالياً',
        'لا توجد طلبات قيد التنفيذ',
        'لا توجد طلبات مكتملة',
        'لا توجد طلبات مرفوضة',
      ];
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          WelcomeBanner(name: AuthService.instance.name ?? '', isDriver: true),
          const SizedBox(height: 100),
          const Icon(Icons.inbox_rounded, size: 64, color: AppColors.textHint),
          const SizedBox(height: 12),
          Center(
            child: Text(
              messages[_tabIndex.clamp(0, messages.length - 1)],
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    }
    // ★ ListView.builder لا ListView: تبويبا «مكتمل» و«مرفوض» يجلبان
    //   الطلبات بلا حدّ (`supabase_service._fetchOrders` بلا limit)،
    //   فكان `children:` يبني **كل** بطاقة وبنودها وأزرارها وصورها
    //   دفعةً واحدة. مندوب بـ٥٠٠ طلب تاريخي كان يبني ٥٠٠ شجرة عند
    //   فتح التبويب. هنا يُبنى المرئي فقط.
    return ListView.builder(
      controller: _listScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: 1 + current.length,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Column(
            children: [
              WelcomeBanner(
                name: AuthService.instance.name ?? '',
                isDriver: true,
              ),
              // ★ قراءة المتاحة سقطت: سطر الصراحة لازم، وإلا بدت
              //   القائمة «قديمة» وهي في الحقيقة «لم نقرأ».
              if (_availableReadFailed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'تعذّر جلب الطلبات — تحقّق من الاتصال، وسحبُ القائمة يُعيد المحاولة',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.danger,
                    ),
                  ),
                ),
            ],
          );
        }
        final o = current[i - 1];
        return _OrderCard(
          key: ValueKey<String>(o['id'].toString()),
          order: o,
          tabIndex: _tabIndex,
          isFreeRequestTab: false,
          busy: _isBusy(o['id'].toString()),
          onDetails: () => _showDetails(o),
          // قبول فوري بضغطة واحدة دون فتح التفاصيل.
          onAccept: () => _accept(o),
          onReject: () => _reject(o),
          onStartDelivering: () => _startDelivering(o),
          onComplete: () => _complete(o),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ExitConfirm.guard(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            'طلبات المندوب',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
          ),
          centerTitle: true,
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          actions: [
            // ★ المحفظة في الشريط الأعلى، قبل زر الخروج: آخر ما
            //   يفكّر فيه المندوب بعد يوم توصيل.
            _DriverWalletButton(
              wallet: _wallet,
              error: _walletError,
              onRefresh: _loadWallet,
            ),
            IconButton(
              icon: const Icon(Icons.logout_rounded),
              onPressed: _confirmLogout,
              tooltip: 'تسجيل الخروج',
            ),
          ],
        ),
        body: AppRefreshIndicator(
          color: AppColors.primary,
          onRefresh: _load,
          child: _body(),
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: _onNavTap,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.textSecondary,
          backgroundColor: Colors.white,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.inbox_rounded),
              label: 'طلبات متاحة',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.delivery_dining_rounded),
              label: 'قيد التنفيذ',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.check_circle_outlined),
              label: 'مكتمل',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.cancel_outlined),
              label: 'مرفوض',
            ),
          ],
        ),
      ),
    );
  }
}

/// ساعة الوقت بصيغة المشروع. ★ صار التنسيق في `OrderElapsed.clock`
/// ليكون وقت الطلب ومضيه من مصدر واحد للّكل (هذه الشاشة وشاشة الأدمن
/// التي تستورد هذا الاسم)، والالتزام بالتوقيع القديم حتى لا تُلمس
/// مواضع استعماله.
String formatTime(String? iso) => OrderElapsed.clock(iso);

/// ورقة المعلومات الكاملة للطلب: الصيدليات، الأوقات، الموقع، القبول / الرفض.
/// قائمة إجراءات قطعة الطلب.
///
/// حالة الانشغال تعيش هنا لأن ورقة التفاصيل `StatelessWidget`: كان
/// فتح «استبدال المنتج» ينتظر جلب الكتالوج بلا أي إشارة مرئية.
class _ItemActionMenu extends StatefulWidget {
  const _ItemActionMenu({required this.onAction});

  final Future<void> Function(String action) onAction;

  @override
  State<_ItemActionMenu> createState() => _ItemActionMenuState();
}

class _ItemActionMenuState extends State<_ItemActionMenu> {
  bool _busy = false;

  Future<void> _run(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onAction(action);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Padding(
          padding: EdgeInsets.all(5),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      );
    }
    return PopupMenuButton<String>(
      icon: const Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: AppColors.primary,
      ),
      onSelected: _run,
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'price', child: Text('تعديل السعر')),
        PopupMenuItem(value: 'replace', child: Text('استبدال المنتج')),
        PopupMenuItem(value: 'delete', child: Text('حذف المنتج')),
      ],
    );
  }
}

class _OrderDetailsSheet extends StatelessWidget {
  const _OrderDetailsSheet({
    required this.order,
    required this.items,
    required this.onMap,
    required this.onAccept,
    required this.onReject,
    required this.onStartDelivering,
    required this.onComplete,
  });

  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> items;
  final VoidCallback onMap;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onStartDelivering;
  final VoidCallback onComplete;

  void _msg(BuildContext context, String m, bool ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            m,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
        ),
      );
  }

  /// إجراءات المندوب على قطعة الطلب (سعر/استبدال/حذف) — للمندوب فقط.
  Future<void> _driverItemAction(
    BuildContext context,
    String action,
    Map<String, dynamic> item,
    Map<String, dynamic> order,
  ) async {
    final itemId = item['id']?.toString() ?? '';
    final orderId = order['id']?.toString() ?? '';
    if (itemId.isEmpty) return;

    if (action == 'price') {
      final ctrl = TextEditingController(
        text: ((item['price'] as num?) ?? 0).toStringAsFixed(0),
      );
      final price = await showDialog<double>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'تعديل سعر: ${item['product_name'] ?? 'المنتج'}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'السعر الجديد'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
              child: const Text('حفظ'),
            ),
          ],
        ),
      );
      if (price == null || price <= 0) return;
      final ok = await SupabaseService.instance.updateOrderItemPrice(
        itemId,
        price,
        productName: item['product_name']?.toString(),
        driverName: _myDriverName,
      );
      if (!context.mounted) return;
      if (!ok) {
        _msg(context, 'تعذر تعديل السعر', false);
        return;
      }
      Navigator.pop(context);
      _msg(context, 'تم تعديل السعر', true);
      return;
    }

    if (action == 'replace') {
      final products = await SupabaseService.instance.fetchProducts();
      if (!context.mounted) return;
      final chosen = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: AppColors.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, ctl) => Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Text(
                  'اختر المنتج البديل',
                  style: GoogleFonts.cairo(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: ctl,
                  itemCount: products.length,
                  itemBuilder: (_, i) {
                    final p = products[i];
                    return ListTile(
                      // صورة المنتج الحقيقية: كان أيقونة ثابتة بلا صورة.
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: AppImage(
                            p['image_path']?.toString() ??
                                p['logo_image']?.toString() ??
                                '',
                            fit: BoxFit.cover,
                            cacheWidth: 120,
                            cacheHeight: 120,
                          ),
                        ),
                      ),
                      title: Text(
                        p['name']?.toString() ?? 'منتج',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        '${p['shop_name'] ?? ''} · '
                        '${CurrencyFormatter.format((p['price'] as num?)?.toDouble() ?? 0)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(
                        Icons.swap_horiz_rounded,
                        color: AppColors.primary,
                      ),
                      onTap: () => Navigator.pop(ctx, p),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
      if (chosen == null) return;
      final ok = await SupabaseService.instance.replaceOrderItem(
        itemId: itemId,
        orderId: orderId,
        productId: chosen['id']?.toString(),
        shopId: chosen['shop_id']?.toString(),
        productName: chosen['name']?.toString() ?? 'منتج',
        shopName:
            chosen['shop_name']?.toString() ??
            item['shop_name']?.toString() ??
            '',
        price: (chosen['price'] as num?)?.toDouble() ?? 0,
        image:
            chosen['image_path']?.toString() ??
            chosen['logo_image']?.toString(),
        driverName: _myDriverName,
      );
      if (!context.mounted) return;
      if (ok) {
        Navigator.pop(context);
        _msg(context, 'تم استبدال المنتج', true);
      } else {
        _msg(context, 'تعذر الاستبدال', false);
      }
      return;
    }

    if (action == 'delete') {
      // ★ كان يحذف فوراً بلا سؤال — نقرة واحدة تُنهي صنفاً من طلب
      //   زبون، وتُغيّر فاتورته ولا رجعة فيها. الآن تأكيد صريح
      //   يذكر اسم الصنف، ويوضّح أن الزبون سيُخطَر.
      final rawName =
          (item['product_name'] ?? item['name'])?.toString().trim() ?? '';
      final label = rawName.isNotEmpty ? rawName : 'هذا الصنف';
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.danger,
                size: 26,
              ),
              const SizedBox(width: 8),
              Text(
                'حذف المنتج؟',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'سيُحذف «$label» من الطلب نهائياً.',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '• تتغيّر فاتورة الطلب.\n'
                '• سيصل الزبون إشعار «أُزيل صنف من طلبك» بشعار الصيدلية.\n'
                '• لا يمكن التراجع.',
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('تراجع', style: GoogleFonts.cairo()),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: Text(
                'نعم، احذف',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      );
      if (yes != true) return;

      final ok = await SupabaseService.instance.deleteOrderItem(
        itemId,
        orderId,
        driverName: _myDriverName,
      );
      if (!context.mounted) return;
      if (ok) {
        Navigator.pop(context);
        _msg(context, 'تم حذف المنتج', true);
      } else {
        _msg(context, 'تعذر الحذف', false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = order['status']?.toString() ?? 'pending';
    final number = OrderDisplay.serial(order);
    final user = OrderDisplay.customerName(order);
    final phone = order['user_phone']?.toString() ?? '';
    final driverLabel = OrderDisplay.driverName(order);
    final address = order['address']?.toString() ?? '';
    final total = (order['total_amount'] as num?)?.toDouble() ?? 0;
    final deliveryFee = (order['delivery_fee'] as num?)?.toDouble() ?? 0;

    // تجميع البنود حسب الصيدلية لعرض تفصيل واضح لكل صيدلية.
    final shopGroups = <String, List<Map<String, dynamic>>>{};
    for (final it in items) {
      final s = it['shop_name']?.toString() ?? 'صيدلية';
      shopGroups.putIfAbsent(s, () => []).add(it);
    }

    double lineTotal(Map<String, dynamic> item) {
      final qty = (item['quantity'] as num?)?.toDouble() ?? 1;
      final price = (item['price'] as num?)?.toDouble() ?? 0;
      return qty * price;
    }

    double shopSubtotal(List<Map<String, dynamic>> group) =>
        group.fold(0.0, (sum, it) => sum + lineTotal(it));

    final isPending = status == 'pending';
    // ★★ طلب بوصفة لم تعتمده الصيدلية بعد: لا يظهر في قوائم المندوب
    //   أصلاً (الفلتر يستثنيه)، لكن الحماية تُكرَّر هنا حتى لو فُتح
    //   التفاصيل من إشعار قديم — فلا زرّ قبول قبل موافقة الصيدلية.
    final isPharmacyReview = status == 'pharmacy_review';
    final isInProgress = status == 'accepted' || status == 'delivering';
    // طلب المندوب الحر بلا زبون ولا منتج: مسار الرفض فيه غير مطلوب.
    final isFreeRequest = order['is_free_driver_request'] == true;
    // ★ وصفة العلاج: الطلب يحتوي دواءً بوصفة. الصورة نفسها تظهر لصاحب
    //   الصيدلية والأدمن فقط، فالمندوب يأخذ هنا **التنبيه النصي** لا الصورة.
    final hasPrescription =
        (order['prescription_path']?.toString() ?? '').trim().isNotEmpty;

    // ★ أدوات القطعة (سعر / استبدال / حذف) لكل طلب يفتحه المندوب — قرار
    //   الأدمن 2026-10-10: «اسمح للمندوبين بتعديل وحذف المنتج واستبدال
    //   كالسابق»، فرُفع القفل الذي كان يقيدها بالطلب المسنَد إليه.
    //   الخادم ينفّذ نفس القرار (SQL_DRIVER_ROLLBACK.sql).

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ★★ تنبيه وصفة العلاج أول شريط في النافذة — قبل الملاحظات
              //   وقبل كل شيء: الطلب الذي فيه دواء بوصفة لا يُسلَّم بلا
              //   وصفة، والمندوب لا يرى صورة الوصفة (للصيدلية والأدمن فقط)،
              //   فيلزم نصّ صريح يذكّره باستلامها مع الطلب والتحقق منها.
              //   (طلب الأدمن 2026-11-20: «اشر للمندوب ملاحظة واضحة بخصوص
              //   وصفة العلاج ضروري»)
              if (hasPrescription) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.medical_information_rounded,
                        size: 26,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'وصفة العلاج ضرورية لهذا الطلب',
                              style: GoogleFonts.cairo(
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              'هذا الطلب يتضمّن دواءً بوصفة طبية.\n'
                              '• تأكّد من الصيدلية أن الوصفة مرفقة مع الطلب '
                              'قبل الخروج.\n'
                              '• لا تسلّم الطلب للزبون قبل التحقق من الوصفة.\n'
                              '• صورة الوصفة تظهر للصيدلية فقط — '
                              'تُسلَّم الوصفة مع الطلب.',
                              style: GoogleFonts.cairo(
                                fontSize: 12.5,
                                height: 1.65,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (isPharmacyReview) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.lock_clock_rounded,
                        size: 22,
                        color: AppColors.warning,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'بانتظار موافقة الصيدلية على الوصفة — '
                          'أزرار القبول والرفض مقفلة حتى تتأكد الصيدلية.',
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
                const SizedBox(height: 14),
              ],
              //   المندوب (طريقة الاتصال، العنوان التفصيلي، وقت مفضّل)،
              //   وكانت في أسفل النافذة بعد التمرير ⇒ تُنسى أو تُقرأ ناقصة.
              if ((order['notes']?.toString() ?? '').trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.info.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.sticky_note_2_rounded,
                        size: 20,
                        color: AppColors.info,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ملاحظة الزبون',
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                color: AppColors.info,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              (order['notes']?.toString() ?? '').trim(),
                              style: GoogleFonts.cairo(
                                fontSize: 13,
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
                const SizedBox(height: 14),
              ],
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      number,
                      style: GoogleFonts.cairo(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  _StatusChip(status: status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'الزبون: $user${phone.isEmpty || phone == 'null' ? '' : ' · $phone'}',
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'المندوب: $driverLabel',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              // تواصل مباشر مع الزبون (المندوب فقط)
              if (phone.isNotEmpty && phone != 'null')
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            ContactTools.callCustomer(context, phone),
                        icon: const Icon(Icons.call_rounded, size: 18),
                        label: const Text(
                          'اتصال مباشر',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => ContactTools.whatsappCustomer(
                          context,
                          phone,
                          message:
                              'السلام عليكم، بخصوص طلبكم رقم $number في اطباء ذي قار.',
                        ),
                        icon: const Icon(Icons.chat_rounded, size: 18),
                        label: const Text(
                          'واتساب',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.success,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 18),

              // رسالة توضيحية للمندوب: التوصيل عند الاتفاق فقط.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.info_rounded,
                          color: AppColors.warning,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '(التوصيل عند الاتفاق فقط)',
                            style: GoogleFonts.cairo(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              _SectionTitle('تفاصيل الصيدليات والمنتجات'),
              if (shopGroups.isEmpty)
                // ★ «لا توجد منتجات» كان سطراً باهتاً ⇒ المندوب لا
                //   يفرّق بين طلب فعلاً بلا أصناف وطلب **فشلت** قراءة
                //   أصنافه، فيخرج وفيظنّ أن الزبون لم يطلب شيئاً.
                //   الرسالة الآن تقول ماذا يفعل: يتصل بالزبون.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.danger.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: AppColors.danger,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'لم تظهر منتجات هذا الطلب.\n'
                          'كل طلب يجب أن يحتوي أصنافاً — '
                          'اسحب للأسفل للتحديث، وإن استمرّ فاتصل بالزبون '
                          'قبل الانطلاق ولا تتوصّل بلا أصناف.',
                          style: GoogleFonts.cairo(
                            fontSize: 12,
                            height: 1.6,
                            fontWeight: FontWeight.w700,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final entry in shopGroups.entries) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    decoration: BoxDecoration(
                      // ★ كان لون البانر أزرق باهت مغمور (primaryLight
                      //   بشفافية ٠٫٤) مع حدّ أزرق خفيف ⇒ يبدو باهتاً
                      //   غير نظيف، خصوصاً على خلفية بيضاء.
                      //   البديل المحترف: سطح أبيض نقي + خط شعرية محايد
                      //   + ظل ناعم جداً، مع تمييز الصيدلية بلون الهوية
                      //   فقط. الألوان تأتي من النظام (surface/divider)
                      //   فتبقى متناسقة مع أي تعديل لاحق على الثيم.
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.divider),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.textPrimary.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ترويسة الصيدلية: أيقونة + اسم، موسّطة أفقياً.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.storefront_rounded,
                              color: AppColors.primary,
                              size: 17,
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                entry.key,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.cairo(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w900,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Divider(color: AppColors.divider, height: 1),
                        const SizedBox(height: 6),
                        for (final it in entry.value)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                _ItemThumb(
                                  image: it['product_image']?.toString(),
                                ),
                                const SizedBox(width: 10),
                                // الكلام موسّط: الاسم والسعر في المنتصف،
                                // والتسلسل يمين «صورة ← نص ← كمية/مبلغ».
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Text(
                                        it['product_name']?.toString() ??
                                            'منتج',
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.cairo(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'سعر القطعة: ${CurrencyFormatter.format((it['price'] as num?)?.toDouble() ?? 0)}',
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.cairo(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      'عدد ${(it['quantity'] as num?)?.toInt() ?? 1}',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.cairo(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w900,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      CurrencyFormatter.format(
                                        (it['total'] as num?)?.toDouble() ??
                                            ((it['price'] as num?)
                                                        ?.toDouble() ??
                                                    0) *
                                                ((it['quantity'] as num?)
                                                        ?.toInt() ??
                                                    1),
                                      ),
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.cairo(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w900,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),

                                // أدوات المندوب على القطعة — لكل طلب (رجوع كامل)
                                _ItemActionMenu(
                                  onAction: (v) =>
                                      _driverItemAction(context, v, it, order),
                                ),
                              ],
                            ),
                          ),
                        const Divider(height: 16, color: AppColors.divider),
                        Row(
                          children: [
                            Text(
                              'مجموع الصيدلية:',
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              CurrencyFormatter.format(
                                shopSubtotal(entry.value),
                              ),
                              style: GoogleFonts.cairo(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              const SizedBox(height: 16),

              const SizedBox(height: 16),

              _SectionTitle('عنوان التوصيل والموقع'),
              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    color: AppColors.textSecondary,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      address.isEmpty ? 'لا يوجد عنوان محدد' : address,
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: onMap,
                    icon: const Icon(Icons.map_rounded, size: 18),
                    label: Text(
                      'فتح في خرائط غوغل',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.info,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _SectionTitle('الأوقات'),
              // ★ أول سطرين = الطلب نفسه: متى أُرسل وكم مضى عليه. كان
              //   القسم يبدأ من «وقت الاستلام»، فلا يعرف المندوب أي
              //   الطلبات أقدم ولا كم انتظر الزبون قبله.
              _TimeRow(
                icon: Icons.receipt_long_rounded,
                label: 'وقت الطلب',
                value: formatTime(order['created_at'].toString()),
              ),
              if (OrderElapsed.passed(order).isNotEmpty)
                _TimeRow(
                  icon: Icons.hourglass_bottom_rounded,
                  label: OrderElapsed.counterLabel(order),
                  value: OrderElapsed.passed(order),
                  highlight: isPending,
                ),
              _TimeRow(
                icon: Icons.storefront_rounded,
                label: 'وقت الاستلام',
                value: isPending
                    ? 'فوراً عند القبول'
                    : formatTime(order['accepted_at'].toString()),
                highlight: isPending,
              ),
              // ★ «وقت التوصيل» محذوف قبل القبول: التقدير
              //   (٢٠-٣٠ دقيقة) كان يربك المندوب ويوهمه بوقت
              //   مؤكد لا يعرفه. يظهر بعد القبول فقط — وهو وقت
              //   حقيقي مُسجَّل في delivering_at.
              if (!isPending)
                _TimeRow(
                  icon: Icons.delivery_dining_rounded,
                  label: 'وقت التوصيل',
                  value: formatTime(order['delivering_at'].toString()),
                ),
              // وقت الاكتمال يبقى ظاهراً دائماً: قبل القبول يظهر
              // شرطة (لم يكتمل بعد) حتى لا يظن المندوب أنه مخفي.
              _TimeRow(
                icon: Icons.flag_rounded,
                label: 'وقت الاكتمال',
                value: formatTime(order['delivered_at'].toString()),
              ),
              const SizedBox(height: 20),

              // ★ المجموع الكلي نُزل إلى الأسفل: كان في الأعلى فوق
              //   ملاحظة الزبون، فينساه المندوب وهو يقرأ ملاحظته.
              //   الآن: ملاحظة في الأعلى، وتفاصيل في الوسط، ومبلغ في
              //   الأسفل قبل القرار مباشرة — حيث يُقارن المبلغ بالطلب.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: AppColors.buttonGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.receipt_long_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'المجموع الكلي للطلب',
                            style: GoogleFonts.cairo(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          if (deliveryFee > 0)
                            Text(
                              'شامل أجور التوصيل ${CurrencyFormatter.format(deliveryFee)}',
                              style: GoogleFonts.cairo(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white70,
                              ),
                            ),
                          // ★ الخصم: بدون هذا السطر يطلب المندوب مبلغاً
                          //   أقل من مجموع الأصناف بلا تفسير، فينشب
                          //   نزاع عند الباب. المبلغ المعروض = الصافي
                          //   المطلوب تحصيله فعلاً.
                          if (OrderDisplay.hasDiscount(order))
                            Text(
                              '${OrderDisplay.discountNote(order, showCode: false)}'
                              ' — المطلوب تحصيله ${CurrencyFormatter.format(total)}',
                              style: GoogleFonts.cairo(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      CurrencyFormatter.format(total),
                      style: GoogleFonts.cairo(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              if (isPending) ...[
                FilledButton.icon(
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.check_circle_rounded),
                  label: Text(
                    'قبول الطلب',
                    style: GoogleFonts.cairo(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.cancel_rounded),
                  label: Text(
                    'رفض الطلب',
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ] else if (isInProgress) ...[
                if (status == 'accepted')
                  FilledButton.icon(
                    onPressed: onStartDelivering,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.info,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.delivery_dining_rounded),
                    label: Text(
                      'بدء التوصيل',
                      style: GoogleFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: onComplete,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.success,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.flag_rounded),
                    label: Text(
                      'تم الاكتمال',
                      style: GoogleFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                // ★ الرفض متاح بعد القبول أيضاً — كان الزرّ يختفي لحظة
                //   acceptance فيُحبس المندوب على طلب لا يقدر عليه.
                if (!isFreeRequest) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.cancel_rounded),
                    label: Text(
                      'رفض الطلب',
                      style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: GoogleFonts.cairo(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: highlight ? AppColors.primary : AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: highlight ? AppColors.primary : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    switch (status) {
      case 'accepted':
        label = 'مقبول';
        color = AppColors.success;
        break;
      case 'delivering':
        label = 'قيد التوصيل';
        color = AppColors.info;
        break;
      case 'delivered':
        label = 'تم التوصيل';
        color = AppColors.textSecondary;
        break;
      case 'rejected':
      case 'cancelled':
        label = 'مرفوض';
        color = AppColors.danger;
        break;
      default:
        label = 'قيد الانتظار';
        color = AppColors.warning;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.cairo(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// ★ زرّ المحفظة في الشريط — أيقونة + الرصيد دائماً مرئيّان.
///
/// ★ `null` تعني «ما تأكّد بعد» لا «رصيدك صفر». نضع `…` بدل الرقم،
///   لأن عرض صفرٍ غير مؤكد كذبةٌ مالية: المندوب يظن أن له لا شيء.
///   أما الصفر **المؤكد** بعد وصول الردّ فيُعرض عادياً: «0 د.ع».
class _DriverWalletButton extends StatelessWidget {
  const _DriverWalletButton({
    required this.wallet,
    required this.onRefresh,
    this.error,
  });

  final Map<String, dynamic>? wallet;
  final String? error;
  final Future<void> Function() onRefresh;

  double _d(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  @override
  Widget build(BuildContext context) {
    final data = wallet;
    return InkWell(
      onTap: () => _open(context, data, error, onRefresh),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ★ العطل يُميَّز بلون التحذير لا برقم مخالف.
            Icon(
              error != null
                  ? Icons.error_outline_rounded
                  : Icons.account_balance_wallet_rounded,
              color: error != null ? Colors.amberAccent : Colors.white,
              size: 20,
            ),
            const SizedBox(width: 5),
            Text(
              data == null
                  ? (error == null ? '…' : '!')
                  : CurrencyFormatter.formatPlain(_d(data['balance'])),
              style: GoogleFonts.cairo(
                color: error != null ? Colors.amberAccent : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    Map<String, dynamic>? data,
    String? error,
    Future<void> Function() refresh,
  ) async {
    // تُقرأ مرة واحدة: الشريط والسطور معاً من نفس التحليل.
    final pending = DriverWalletPending.from(data);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'محفظتي',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                if (data == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      children: [
                        Text(
                          error ?? 'جارِ فتح المحفظة…',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.cairo(
                            fontSize: 14,
                            height: 1.7,
                            fontWeight: FontWeight.w800,
                            color: error != null
                                ? AppColors.danger
                                : AppColors.textSecondary,
                          ),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            'المحفظة تُملأ عند تسليم طلب بكود خصم.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.cairo(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                else ...[
                  Text(
                    'رصيدك الحالي ${CurrencyFormatter.format(_d(data['balance']))}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'خصم الأكواد فقط · '
                    '${_d(data['entries']).toStringAsFixed(0)} طلب',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  // ★ المعلَّق: خصم أكواد على طلبات قبَلها المندوب ولم
                  //   تُسلَّم بعد. يُعرض **تحت** الرصيد لا داخله — لأنه
                  //   ليس واجب الدفع بعد، ويصير رصيداً عند التسليم.
                  //   ولو أرسلته نسخة القاعدة القديمة صفراً بلا وجوده
                  //   لكان كذباً، فلا سطر إطلاقاً حينها.
                  if (pending.hasMoney) ..._pendingLine(pending),
                  // ★ الاعتماد على المعامل لا التوكن = الرقم غير مُثبَت.
                  //   نُعلم المندوب بدل أن نُخفي ضعف الحماية.
                  if ('${data['verified_by'] ?? ''}' == 'parameter') ...[
                    const SizedBox(height: 10),
                    Text(
                      'تنبيه: التحقق من الهوية غير مُفعَّل بعد — رصيدك '
                      'يُقرأ برقمك مباشرة دون توكن.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        height: 1.6,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warning,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _rows(data, pending),
                ],
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await AppRefresh.run(refresh);
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text(
                    'تحديث المحفظة',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// ★ سطر المعلَّق تحت الرصيد — مبلغه وعدد طلباته.
  List<Widget> _pendingLine(DriverWalletPending p) {
    return [
      const SizedBox(height: 6),
      Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'معلَّق ${CurrencyFormatter.format(p.amount)} ',
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
                color: AppColors.warning,
              ),
            ),
            TextSpan(
              text: '· ${p.orders} ${p.ordersWord} تُثبَّت عند التسليم',
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    ];
  }

  /// ★ سطر معلَّق واحد: رقم الطلب وكوده وحالته ومبلَّغه المنتظر.
  Widget _pendingRowTile(PendingRow r) {
    final extra = <String>[
      if (r.fromWheel) 'عجلة الحظ',
      if (r.status.isNotEmpty) r.status,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Icon(
            Icons.hourglass_top_rounded,
            size: 16,
            color: AppColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'طلب ${r.label}${r.code == null ? '' : ' · ${r.code}'}',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (extra.isNotEmpty)
                  Text(
                    extra.join(' · '),
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            CurrencyFormatter.format(r.amount),
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: AppColors.warning,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rows(Map<String, dynamic> data, DriverWalletPending pending) {
    final rows = (data['rows'] as List?) ?? const [];

    // ★ المعلَّق يُعرض **قبل** الثابت: المندوب يسأل أولاً عمّا هو في
    //   الطريق، ثم عمّا ثبت. والحصر هنا يمنع تكرار الرقم — فما ثبت
    //   في الدفتر لا يبقى معلَّقاً (القاعدة تحذفه من المعلَّق).
    final List<Widget> pendingBlock = pending.hasRows
        ? [
            Text(
              'في انتظار التسليم',
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(height: 4),
            for (final r in pending.rows)
              _pendingRowTile(DriverWalletPending.row(r)),
            const SizedBox(height: 14),
          ]
        : const <Widget>[];

    if (rows.isEmpty) {
      if (pendingBlock.isEmpty) {
        return Text(
          'لا يوجد خصم مُسجَّل بعد — المحفظة تملأ عند تسليم طلب بكود خصم.',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            fontSize: 13,
            height: 1.7,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...pendingBlock,
          Text(
            'لا شيء مُثبَّت بعد — كل معلَّق هنا يصبح رصيداً عند التسليم.',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 12,
              height: 1.7,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...pendingBlock,
        Text(
          'آخر العمليات',
          style: GoogleFonts.cairo(
            fontSize: 13,
            fontWeight: FontWeight.w900,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.local_offer_rounded,
                  size: 16,
                  color: AppColors.success,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ★ الرقم التسلسلي الحقيقي (#12) لا الوسم
                      //   القديم العشري. ترفض الواجهة عرض الوسم
                      //   لأنه لا يطابق ما رآه الزبون.
                      Text(
                        'طلب ${r['order_label'] ?? '—'}'
                        '${(r['coupon_code'] ?? '') == '' ? '' : ' · ${r['coupon_code']}'}',
                        style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      // ★ الملاحظة تُبني في القاعدة، فنصٌّ واحد لكل
                      //   الشاشات ولا يختلف بين جهاز وآخر.
                      Text(
                        '${r['note'] ?? ''}',
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          height: 1.5,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '+${CurrencyFormatter.format(_d(r['amount']))}',
                  style: GoogleFonts.cairo(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    super.key,
    required this.order,
    required this.tabIndex,
    required this.onDetails,
    required this.onAccept,
    required this.onReject,
    required this.onStartDelivering,
    required this.onComplete,
    this.isFreeRequestTab = false,
    this.busy = false,
  });

  final Map<String, dynamic> order;
  final int tabIndex;
  final bool isFreeRequestTab;
  final bool busy;
  final VoidCallback onDetails;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onStartDelivering;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final number = OrderDisplay.serial(order);
    final user = OrderDisplay.customerName(order);
    final phone = order['user_phone']?.toString() ?? '';
    final total = (order['total_amount'] is num)
        ? (order['total_amount'] as num).toDouble()
        : (double.tryParse(order['total_amount']?.toString() ?? '') ?? 0);
    final notes = order['notes']?.toString() ?? '';
    final reason = order['rejection_reason']?.toString() ?? '';
    final status = order['status']?.toString() ?? 'pending';
    // ★ طلب المندوب الحر صار داخل «طلبات متاحة»، فيلزم وسم واضح
    //   وإلا بدا طلب زبون عادي، والمندوب لا يميّز نوع الطلب.
    final isFreeRequest = order['is_free_driver_request'] == true;
    // ★ وصفة العلاج — يراها المندوب في البطاقة **قبل** فتح التفاصيل،
    //   فلا يقبل طلباً فيه دواء بوصفة وهو لا يعرف أن الوصفة لازمة.
    final hasPrescription =
        (order['prescription_path']?.toString() ?? '').trim().isNotEmpty;
    // ★ طلب وصفة لم تعتمده الصيدلية: أزرار القبول/الرفض مقفلة.
    final isPharmacyReview = status == 'pharmacy_review';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                            number,
                            style: GoogleFonts.cairo(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (isFreeRequest) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.success.withValues(
                                  alpha: 0.35,
                                ),
                              ),
                            ),
                            child: Text(
                              'طلب مندوب',
                              style: GoogleFonts.cairo(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _StatusChip(status: status),
                ],
              ),
              const SizedBox(height: 8),
              // اسم الزبون بارزاً مع أيقونة.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.22),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.person_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        user,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ),
                    // ★ الرقم أُزيل من أعلى البطاقة: كان يظهر
                    //   لكل زبون بلا داعٍ، ومعه زرّا «اتصال» و«واتساب»
                    //   أسفله ما يعني أن الرقم متاح مرتين على الشاشة.
                    //   الوصول لرقم الزبون يبقى من أزرار التواصل بالأسفل
                    //   ومن شاشة التفاصيل، وهذا أنظف وأأمن.
                    const SizedBox.shrink(),
                  ],
                ),
              ),
              // ★ شارة «وصفة علاج» على البطاقة نفسها: تظهر قبل القبول
              //   وقبل فتح التفاصيل، فلا يتفاجأ المندوب في الصيدلية.
              if (hasPrescription) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.medical_information_rounded,
                        size: 17,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'وصفة علاج مرفقة — مطلوبة مع هذا الطلب',
                          style: GoogleFonts.cairo(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // ★ «كم صارله الطلب»: وقت الإرسال + كم مضى عليه، في سطر
              //   واحد داخل البطاقة قبل أن يفتح المندوب التفاصيل. الوقت
              //   الحيّ يتقدّم وحده كل نصف دقيقة — فإفراز الانتظار على
              //   قائمة «متاح» كان يعتمد على إعادة الجلب فقط.
              if (OrderElapsed.placedAt(order) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    children: [
                      Flexible(
                        child: OrderElapsedText(
                          order: order,
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'أُرسل ${formatTime(order['created_at'].toString())}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textHint,
                        ),
                      ),
                    ],
                  ),
                ),
              // اتصال + واتساب للزبون (المندوب فقط)
              if (tabIndex == 1 && phone.isNotEmpty && phone != 'null') ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            ContactTools.callCustomer(context, phone),
                        icon: const Icon(Icons.call_rounded, size: 16),
                        label: const Text(
                          'اتصال',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          minimumSize: const Size(0, 36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => ContactTools.whatsappCustomer(
                          context,
                          phone,
                          message:
                              'السلام عليكم، بخصوص طلبكم رقم $number في اطباء ذي قار.',
                        ),
                        icon: const Icon(Icons.chat_rounded, size: 16),
                        label: const Text(
                          'واتساب',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.success,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          minimumSize: const Size(0, 36),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (tabIndex == 1)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  // ★ Wrap بدل Row: القطعتان تلتفّان إلى سطر ثانٍ على
                  //   الشاشات الضيقة بدل تجاوز العرض (كان يظهر شريط
                  //   «RIGHT OVERFLOWED» عمودياً على حد البطاقة).
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.storefront_rounded,
                            size: 15,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'الاستلام: ${formatTime(order['accepted_at'].toString())}',
                            style: GoogleFonts.cairo(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.delivery_dining_rounded,
                            size: 15,
                            color: AppColors.info,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'التوصيل: ${formatTime(order['delivering_at'].toString())}',
                            style: GoogleFonts.cairo(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppColors.info,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (tabIndex == 2)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.storefront_rounded,
                        size: 15,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 5),
                      // ★ مرونة إلزامية: النص غير المرن في صف يتمدد
                      //   بحرية فيتجاوز عرض البطاقة (كان يظهر شريط
                      //   «RIGHT OVERFLOWED BY 3.1 PIXELS» بنص عمودي
                      //   على حد البطاقة في مكتمل). مع Expanded يلتفّ
                      //   سطراً ثانياً بدل الشريط.
                      Expanded(
                        child: Text(
                          'استلام ${formatTime(order['accepted_at'].toString())} · '
                          'توصيل ${formatTime(order['delivering_at'].toString())} · '
                          'اكتمال ${formatTime(order['delivered_at'].toString())}',
                          style: GoogleFonts.cairo(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (tabIndex == 3 && reason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.block_rounded,
                        size: 15,
                        color: AppColors.danger,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'سبب الرفض: $reason',
                          style: GoogleFonts.cairo(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                // ملاحظة الزبون تظهر بوضوح وبلا قصّ — المندوب يحتاجها كاملة
                // (طريقة الاتصال، العنوان التفصيلي، وقت التسليم المفضّل…).
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.info.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.info.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.sticky_note_2_rounded,
                        size: 16,
                        color: AppColors.info,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ملاحظة الزبون',
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
              ],
              // ★ شارة الخصم في بطاقة الطلب نفسه — تظهر قبل أن يفتح
              //   المندوب التفاصيل، فيعرف أن المبلغ أقل من سبب.
              if (OrderDisplay.hasDiscount(order)) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      Icons.local_offer_rounded,
                      size: 15,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        OrderDisplay.discountNote(order, showCode: false),
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      CurrencyFormatter.format(total),
                      style: GoogleFonts.cairo(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  if ((tabIndex == 0 || isFreeRequestTab) && !isPharmacyReview)
                    FilledButton.icon(
                      onPressed: busy ? null : onAccept,
                      style: FilledButton.styleFrom(
                        backgroundColor: isFreeRequestTab
                            ? AppColors.info
                            : AppColors.primary,
                        disabledBackgroundColor: isFreeRequestTab
                            ? AppColors.info.withValues(alpha: 0.45)
                            : AppColors.primary.withValues(alpha: 0.45),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              isFreeRequestTab
                                  ? Icons.pan_tool_alt_rounded
                                  : Icons.check_circle_rounded,
                              size: 18,
                            ),
                      label: Text(
                        isFreeRequestTab ? 'استلام الطلب' : 'قبول الطلب',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  else if (tabIndex == 1 && status == 'accepted')
                    FilledButton.icon(
                      onPressed: busy ? null : onStartDelivering,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.info,
                        disabledBackgroundColor: AppColors.info.withValues(
                          alpha: 0.45,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.delivery_dining_rounded, size: 18),
                      label: Text(
                        'بدء التوصيل',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  else if (tabIndex == 1 && status == 'delivering')
                    FilledButton.icon(
                      onPressed: busy ? null : onComplete,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        disabledBackgroundColor: AppColors.success.withValues(
                          alpha: 0.45,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.flag_rounded, size: 18),
                      label: Text(
                        'تم الاكتمال',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  // ★ زرّ الرفض في «قيد التنفيذ» أيضاً: المندوب كان
                  //   يرفض وهو «متاح» فقط، فإذا قبِل طلباً وندم عليه —
                  //   أو وجد الزبون بعيداً — لا يملك سبيلاً غير اللوحة.
                  //   القاعدة تُوسَّع بملف SQL ليُقبل الرفض بعد القبول.
                  if (tabIndex == 1 && !isFreeRequest && !isPharmacyReview) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: busy ? null : onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: BorderSide(
                          color: AppColors.danger.withValues(alpha: 0.55),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.block_rounded, size: 16),
                      label: Text(
                        'رفض',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// صورة المنتج داخل تفاصيل الطلب — تظهر كاملة بخلفية موحّدة.
class _ItemThumb extends StatelessWidget {
  const _ItemThumb({this.image});

  final String? image;

  @override
  Widget build(BuildContext context) {
    final hasImage = image != null && image!.trim().isNotEmpty;
    return Container(
      // ★ صُغّرت من ٤٦px إلى ٣٨px: الصورة كانت تطغى على اسم المنتج
      //   وتزاحم الكلام في صف ضيق، والمندوب يقرأ الاسم لا الصورة.
      width: 38,
      height: 38,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.imageBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.imageBorder),
      ),
      child: hasImage
          ? TappableImage(
              url: image,
              title: 'تكبير صورة المنتج',
              child: AppImage(
                image!,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                // كان ٣٢٠ بكسل لصورة ٤٦px ⇒ ذاكرة هدرية بلا فائدة
                // مرئية. الآن ١٠٤ بكسل (٢× المقاس الفعلي) لأداء ناعم.
                cacheWidth: 104,
                cacheHeight: 104,
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
