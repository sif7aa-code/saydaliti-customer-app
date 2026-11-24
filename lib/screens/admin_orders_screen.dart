import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/account_name.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/order_display.dart';
import '../core/utils/order_duplicates.dart';
import '../core/utils/order_elapsed.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import '../services/admin_password_session.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/duplicate_orders_panel.dart';
import '../widgets/image_viewer.dart';
import '../widgets/order_elapsed_text.dart';
import '../widgets/tap_to_dismiss_keyboard.dart';
import 'driver_orders_screen.dart' show formatTime;

/// مراقبة الطلبات من الأدمن: كل الطلبات مع فلاتر الحالة،
/// وزر "إعادة فتح للتحويل" لنقل الطلب لمندوب آخر برقم الطلب.
class AdminOrdersScreen extends StatefulWidget {
  const AdminOrdersScreen({super.key});

  @override
  State<AdminOrdersScreen> createState() => _AdminOrdersScreenState();
}

class _AdminOrdersScreenState extends State<AdminOrdersScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _orders = [];
  String _filter = 'all';
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _searching = false;

  /// ★ ملخّص أكواد الخصم لكل مندوب — يُحمَّل عند فتح المراقبة فقط.
  Map<String, dynamic>? _couponSummary;
  String? _couponError;

  /// ★ هل الملخّص يجري الآن؟ المسار بطيء بطبيعته: تحقّق من التذكرة في
  ///   الخادم ثم تقرير المحفظة — ندائان متتابعان، لكل واحد مهلة طويلة.
  ///   بلا هذه الحالة كان الزرّ يبقى «عرض» ولا شيء يتغيّر، فيحسبها الأدمن
  ///   شاشة معلقة ويعاود الضغط.
  bool _couponBusy = false;

  /// ★ الطلبات التي تكرّرت عند أكثر من مندوب — تُحسب من القائمة التي
  ///   تُحمَّل أصلاً (`fetchAllOrders`)، فلا نداء شبكة زائداً ولا
  ///   انتظار إضافي في فتح الشاشة. تُترك فارغة لغير حساب الأدمن.
  List<DuplicateGroup> _duplicates = const [];
  bool _showAllDuplicates = false;

  /// ★ النسخة الكاملة المحمَّلة. تُحتفظ وحدها لأن `_orders` يبدّلها
  ///   البحثُ برقم تسلسلي إلى سطر واحد؛ ولولاها لاختفى من أمام الأدمن
  ///   طلبٌ ما زال مكرّراً، ولما استطاع فتح بطاقته من لوحة التحذير.
  List<Map<String, dynamic>> _allOrders = const [];

  static const _tabs = [
    ('all', 'الكل'),
    ('pending', 'قيد الانتظار'),
    ('pharmacy_review', 'بانتظار الصيدلية'),
    ('accepted', 'مقبول'),
    ('delivering', 'قيد التوصيل'),
    ('delivered', 'مكتمل'),
    ('rejected', 'مرفوض'),
    ('cancelled', 'ملغي'),
  ];

  /// ★ الحالات التي ينقلها الأدمن الطلب إليها من بطاقة التفاصيل.
  ///
  /// «ملغي» و«مرفوض» الاثنان يُكتبان في العمود نفسه الذي تقرأه
  /// القاعدة (`status`)، فالإلغاء ليس حقلاً جديدًا ولا حالة مخترعة —
  /// `advance_order` أصلاً تقبل `cancelled`، ومشغّل الدفتر يعتبر أي
  /// شيء غير `delivered` بلا مستحق.
  static const _statusActions = <(String, String, IconData)>[
    ('pending', 'يعود للمندوبين', Icons.replay_rounded),
    ('accepted', 'مقبول', Icons.done_rounded),
    ('delivering', 'قيد التوصيل', Icons.delivery_dining_rounded),
    ('delivered', 'مكتمل', Icons.verified_rounded),
    ('cancelled', 'ملغي', Icons.cancel_rounded),
    ('rejected', 'مرفوض', Icons.block_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final orders = await SupabaseService.instance.fetchAllOrders();
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _allOrders = orders;
      _duplicates = _findDuplicates(orders);
      _loading = false;
    });
  }

  /// ★ طلب بمعرفه من القائمة المعروضة أولاً ثم من النسخة الكاملة، أو
  ///   null حين لا يكون محمَّلاً. بلا استيراد حزمة خارجية.
  Map<String, dynamic>? _orderById(String id) {
    if (id.isEmpty) return null;
    for (final o in _orders) {
      if ('${o['id'] ?? ''}'.trim() == id) return o;
    }
    for (final o in _allOrders) {
      if ('${o['id'] ?? ''}'.trim() == id) return o;
    }
    return null;
  }

  /// ★ الكشف للأدمن فقط: حساب غير الأدمن لا يرى التحذير ولو افتُتحت
  ///   هذه الشاشة من بناء تجريبي. القائمة كلها في الذاكرة أصلاً،
  ///   فالتصفية هنا هي الموضع الوحيد الذي يحتاج شرط الصلاحية.
  List<DuplicateGroup> _findDuplicates(List<Map<String, dynamic>> orders) {
    if (!AuthService.instance.isAdmin) return const [];
    return OrderDuplicates.find(orders);
  }

  /// ★ أي كود استلمه كل مندوب، نسبته، والمستحق — بلا تكرار.
  Future<void> _loadCoupons() async {
    // ★ ضغطتان لا تُطلقان مساريْن: كل مسار يتحقّق في الخادم ثم يجلب
    //   التقرير، والتراكيم يضاعف الانتظار ويُربك الأرقام الظاهرة.
    if (_couponBusy) return;
    setState(() => _couponBusy = true);
    final cred = await _couponCredential();
    if (cred == null || cred.isEmpty || !mounted) {
      if (mounted) setState(() => _couponBusy = false);
      return;
    }
    final res = await SupabaseService.instance.fetchDriverCouponSummary(cred);
    if (!mounted) return;
    setState(() {
      _couponBusy = false;
      _couponSummary = res;
      _couponError = SupabaseService.instance.lastAdminCouponError;
    });
  }

  /// ★ **التذكرة قبل الكلمة** — لماذا هذا هو الإصلاح لا مجرد تجميل؟
  ///
  ///   لوحة «أكواد الخصم التي استلمها المندوبون» كانت تُرسل **كلمة فتح
  ///   اللوحة نفسها** في جسم الطلب إلى `admin_driver_coupon_summary`.
  ///   الكلمة تحتوي غالباً على رموز خاصة (`'` و`--` وأمثالها)، والطلب
  ///   يمرّ عبر طبقة الحماية أمام القاعدة التي ترفض بعض هذه الأجسام
  ///   **بطريقة الطلب نفسها** ⇒ `HTTP 405` «تعذّر جلب الملخّص» بلا أي
  ///   علاقة بالمنطق أو بصلاحية الأدمن.
  ///
  ///   التذكرة 64 محرفاً ستاتياً، فلا شيء فيها يُشبه الحقن، والقاعدة
  ///   تقبلها في `require_admin_password` منذ `SQL_ADMIN_PANEL_LOCKDOWN`.
  ///   فالجهاز لا يبعث سرّاً على الشبكة، والزر يعمل — وهذا يخدم حماية
  ///   اللوحة لا يغيّر شيئاً من منطقها.
  ///
  ///   تراجع مضمون: لو لم تُنفَّذ SQL بعد، أو انقطع الاتصال، تُبعث
  ///   الكلمة كما كان يحدث دائماً ⇒ لا انكسار على أي قاعدة.
  Future<String?> _couponCredential() async {
    final ticket = AdminPasswordSession.cachedTicket;
    if (ticket != null && ticket.isNotEmpty) return ticket;

    final typed = (await _askPassword())?.trim();
    if (typed == null || typed.isEmpty || !mounted) return null;

    // لا تذكرة على الجهاز: نحوّل الكلمة إلى تذكرة عبر بوابة اللوحة نفسها
    // (هي التي تتحقق منها أصلاً)، فلا تُرسَل الكلمة لهذه الشاشة مرتين.
    final exchanged = await SupabaseService.instance.unlockAdminPanel(
      AuthService.instance.phone ?? '',
      typed,
    );
    if (!mounted) return null;

    if (exchanged['ok'] == true) {
      final t = exchanged['ticket'];
      if (t is String && AdminPasswordSession.isTicket(t)) {
        AdminPasswordSession.promoteToTicket(t);
        AdminPasswordSession.markVerified();
        return t;
      }
      // بوابة قديمة بلا تذاكر (لم تُشغَّل SQL): الكلمة هي الجواب الصحيح.
      return typed;
    }
    if (exchanged['offline'] == true) {
      // انقطاع شبكة: لا نُعاقِب الأدمن بمحاولة ثانية على الخادم.
      return typed;
    }
    // كلمة خاطئة أو محاولات مقفولة: رسالتها تكفي، ولا نُحمّل الخادم
    // طلباً ثانياً يُحسب محاولة إضافية في سجلّه.
    setState(() {
      _couponSummary = null;
      _couponError = '${exchanged['message'] ?? 'كلمة فتح اللوحة غير صحيحة'}';
    });
    return null;
  }

  /// ★ نافذة كلمة مرور الأدمن — تُعيد null عند الإلغاء.
  ///
  /// ★ تُطلب مرة واحدة لكل فتح: إن كانت كلمة المرور محفوظة في الذاكرة
  ///   (من أي شاشة إدارية في هذه الجلسة) تُعاد مباشرةً بلا حوار.
  ///   ولا تُحفَظ في القرص، فتضيع بإغلاق التطبيق.
  Future<String?> _askPassword() {
    final remembered = AdminPasswordSession.cached;
    if (remembered != null && remembered.isNotEmpty) {
      return Future<String?>.value(remembered);
    }
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AdminCredentialDialog(
        title: 'ملخّص أكواد المندوبين',
        actionLabel: 'عرض',
      ),
    ).then((pw) {
      // ★ حفظ في الذاكرة فقط — تبقى لهذه الجلسة، تضيع بالإغلاق.
      final typed = pw?.trim();
      if (typed != null && typed.isNotEmpty) {
        AdminPasswordSession.remember(typed);
      }
      return pw;
    });
  }

  List<Map<String, dynamic>> get _filtered {
    var list = _orders;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((o) {
        final serial = OrderDisplay.serial(o).toLowerCase();
        final legacy = (o['order_number']?.toString() ?? '').toLowerCase();
        return serial.contains(q) || legacy.contains(q);
      }).toList();
    }
    if (_filter == 'all') return list;
    return list.where((o) => o['status']?.toString() == _filter).toList();
  }

  /// عدد طلبات كل حالة — من النسخة الكاملة حتى لا يغيّره البحث.
  int _countFor(String key) {
    if (key == 'all') return _allOrders.length;
    var n = 0;
    for (final o in _allOrders) {
      if (o['status']?.toString() == key) n++;
    }
    return n;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// بحث من السيرفر بالرقم التسلسلي (أدمن فقط) مع فشل آمن للبحث المحلي.
  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() => _searchQuery = '');
      return;
    }
    setState(() {
      _searching = true;
      _searchQuery = q;
    });
    final found = await SupabaseService.instance.searchOrdersBySerial(q);
    if (!mounted) return;
    if (found.isNotEmpty) {
      setState(() => _orders = found);
    } else {
      _showMessage('لا يوجد طلب بهذا الرقم', false);
      await _load();
    }
    if (mounted) setState(() => _searching = false);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() {
      _searchQuery = '';
      _searching = false;
    });
    _load();
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

  String _label(Map<String, dynamic> o) {
    switch (o['status']?.toString()) {
      case 'accepted':
        return 'مقبول';
      case 'delivering':
        return 'قيد التوصيل';
      case 'delivered':
        return 'مكتمل';
      case 'cancelled':
        return 'ملغي';
      case 'rejected':
        return 'مرفوض';
      // ★ طلب بوصفة لم توافق عليه الصيدلية بعد — لا يظهر للمندوبين.
      case 'pharmacy_review':
        return 'بانتظار الصيدلية';
      default:
        return 'قيد الانتظار';
    }
  }

  /// ★ لون الحالة وحدها — تستخدمه الشارة وصفّ الأزرار معاً، فلا يختلف
  ///   لون «مكتمل» بين البطاقة ونافذة التفاصيل.
  Color _colorOf(String status) {
    switch (status) {
      case 'accepted':
        return AppColors.success;
      case 'delivering':
        return AppColors.info;
      case 'delivered':
        return AppColors.textSecondary;
      case 'rejected':
      case 'cancelled':
        return AppColors.danger;
      default:
        return AppColors.warning;
    }
  }

  Color _color(Map<String, dynamic> o) =>
      _colorOf(o['status']?.toString() ?? '');

  /// ★ **مَن رفض الطلب** — تُعرض في هذه الشاشة فقط: لا الزبون يراها ولا
  ///   المندوب في قائمته، فالطلب هنا «من رفض» للمحاسبة.
  ///
  /// الاسم يكتبه **الخادم** من جلسة المندوب (`reject_order` يقرأ
  /// `app.current_phone()`)، فلا قدرة لأحد على انتحال اسم رافض؛ وحين
  /// ترفض اللوحة بنفسها يُكتب «الإدارة» نصّاً لا رقماً، فلا يُنسب رفض
  /// لمندوب بريء.
  ///
  /// ★ فارغ = لا شيء يُعرض (الأفضل من سطر «غير معروف» في كل بطاقة).
  ///
  /// [hideUnknown] للبطاقات: الطلبات القديمة المرفوضة قبل ختم الرافض
  ///   تُترك بلا سطر، فالبطاقة قائمة على ما يُعرف لا على ما يُشتبه.
  String _rejecterLabel(Map<String, dynamic> o, {bool hideUnknown = false}) {
    final status = o['status']?.toString() ?? '';
    if (status != 'rejected' && status != 'cancelled') return '';

    final name = '${o['rejected_by_name'] ?? ''}'.trim();
    final phone = '${o['rejected_by_phone'] ?? ''}'.trim();
    // ★ الاسم الحقيقي + رقمه، ولا يتكرر الرقم حين لا اسم.
    final stamp = AccountName.withPhone(name: name, phone: phone);
    if (stamp.isNotEmpty) return stamp;

    // إلغاء ما بعد القبول يمرّ بـ`advance_order` التي لا تختم الرافض —
    // وشرطها أن يكون الطلب مسنَداً للسائل، فمسنَدُه هو من بيده وحده.
    final driver = '${o['assigned_driver_phone'] ?? ''}'.trim();
    if (status == 'cancelled' && driver.isNotEmpty) {
      return 'مندوب الطلب: $driver';
    }

    if (status != 'rejected' || hideUnknown) return '';
    return 'غير مسجَّل — الطلب أقدم من ختم الرافض (SQL_REJECTER_STAMP.sql)';
  }

  /// ★ زر حالة واحدة في نافذة التفاصيل — الحالية غير قابلة للضغط.
  Widget _statusChip(
    Map<String, dynamic> order,
    String key,
    String label,
    IconData icon,
    BuildContext sheetCtx,
  ) {
    final current = order['status']?.toString() ?? 'pending';
    final selected = current == key;
    final color = _colorOf(key);
    return Material(
      color: selected
          ? color.withValues(alpha: 0.16)
          : AppColors.surfaceTint.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: selected
            ? null
            : () => _changeStatus(order, key, label, sheetCtx),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? color : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                selected ? '$label — الحالية' : label,
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: selected ? color : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ★ نقل الطلب إلى حالة أخرى (أو إلغاؤه) — بأمر مباشر من الأدمن.
  ///
  /// ★ لا تُكتب الحالة بلا تأكيد، ولا يُلغى طلب بلا سبب يُخزَّن:
  ///   `rejection_reason` هو ما يقرأه الزبون والمندوب، فبقي فضفاضاً
  ///   لكنه غير إجباري — الإدارة أحياناً تلغي بضغطة واحدة.
  Future<void> _changeStatus(
    Map<String, dynamic> order,
    String status,
    String label,
    BuildContext sheetCtx,
  ) async {
    final needsReason = status == 'rejected' || status == 'cancelled';
    // ★ السبب يُلتقط من الحقل أثناء الكتابة ويُرسَل مع Pop: ما عاد هناك
    //   محرّر خارجي يُتحرَّر بـ`whenComplete` بينما الحقل لا زال في الشجرة
    //   وأنيميشن الإغلاق لم ينتهِ — ذلك يرمي استثناء في كل إغلاق.
    String reason = '';
    final result = await showDialog<String>(
      context: sheetCtx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'نقل الطلب إلى «$label»',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'الطلب ${OrderDisplay.serial(order)} · '
              '${OrderDisplay.customerName(order)}',
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
            if (status == 'pending') ...[
              const SizedBox(height: 8),
              Text(
                'يخرج المندوب الحالي من الطلب ويعود متاحاً للجميع.',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.warning,
                ),
              ),
            ],
            if (status == 'delivered') ...[
              const SizedBox(height: 8),
              Text(
                'يُحسب مستحق كود الخصم في محفظة المندوب كما لو سلّمه هو.',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  color: AppColors.textHint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (needsReason) ...[
              const SizedBox(height: 12),
              AdminReasonField(onChanged: (v) => reason = v),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text('تراجع', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, reason),
            style: FilledButton.styleFrom(
              backgroundColor: _colorOf(status),
              foregroundColor: Colors.white,
            ),
            child: Text('تأكيد', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );

    if (result == null) return;
    final done = await SupabaseService.instance.adminSetOrderStatus(
      order['id'].toString(),
      status,
      reason: result,
    );
    if (!mounted) return;
    _showMessage(
      done
          ? 'أصبح الطلب: $label'
          : (SupabaseService.instance.lastAdminStatusError ??
                'تعذّر تغيير الحالة'),
      done,
    );
    if (!done) return;
    // النافذة تعرض الحالة القديمة — تُغلق ثم يُعاد الجلب فتظهر الجديدة.
    // ★ `sheetCtx` سياق النافذة السفلية وحده: `mounted` الخاصة بالشاشة
    //   لا تضمن أنها ما زالت مفتوحة بعد انتظار الشبكة.
    if (sheetCtx.mounted && Navigator.of(sheetCtx).canPop()) {
      Navigator.of(sheetCtx).pop();
    }
    await SupabaseService.instance.broadcastUpdate(
      title: 'تغيّرت حالة الطلب',
      body: 'الطلب ${OrderDisplay.serial(order)} صار «$label».',
      status: status,
      orderId: order['id']?.toString(),
    );
    _load();
  }

  Future<void> _showDetails(Map<String, dynamic> order) async {
    final items = await SupabaseService.instance.fetchOrderItems(
      order['id'].toString(),
    );
    if (!mounted) return;
    final status = order['status']?.toString() ?? '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final canReopen = status != 'delivered';
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
                          OrderDisplay.serial(order),
                          style: GoogleFonts.cairo(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _color(order).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _label(order),
                          style: GoogleFonts.cairo(
                            color: _color(order),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${order['user_name']?.toString() ?? ''} · ${order['user_phone']?.toString() ?? ''}'
                    '${order['assigned_driver_phone']?.toString().isNotEmpty == true ? '  ·  المندوب: ${order['assigned_driver_phone']}' : ''}',
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    order['address']?.toString() ?? '',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      color: AppColors.textHint,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'المنتجات',
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (items.isEmpty)
                    Text(
                      'لا توجد بنود',
                      style: GoogleFonts.cairo(color: AppColors.textHint),
                    )
                  else
                    for (final it in items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${it['product_name']?.toString() ?? 'منتج'} × ${(it['quantity'] as num?)?.toInt() ?? 1}',
                                style: GoogleFonts.cairo(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            Text(
                              CurrencyFormatter.format(
                                (it['total'] as num?)?.toDouble() ?? 0,
                              ),
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceTint.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.schedule_rounded,
                          color: AppColors.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'طلب ${formatTime(order['created_at'])} · '
                                'استلام ${formatTime(order['accepted_at']?.toString())} · '
                                'توصيل ${formatTime(order['delivering_at']?.toString())} · '
                                'اكتمال ${formatTime(order['delivered_at']?.toString())}',
                                style: GoogleFonts.cairo(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              // ★ المدة بالساعة والدقيقة، حيّة: الشيت لا يجلب
                              //   نفسه، وبلا هذا الويجت يتجمّد الوقت على لحظة
                              //   فتحه ويظن الأدمن أن الطلب تقدّم وهو لا يتحرّك.
                              OrderElapsedText(
                                order: order,
                                precise: true,
                                style: GoogleFonts.cairo(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (order['rejection_reason']?.toString().isNotEmpty ==
                      true) ...[
                    const SizedBox(height: 8),
                    Text(
                      'سبب الرفض: ${order['rejection_reason']}',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                  // ★ مَن رفض/ألغى — للوحة الأدمن وحدها.
                  if (_rejecterLabel(order).isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.person_off_rounded,
                          size: 15,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'مَن رفض: ${_rejecterLabel(order)}',
                            style: GoogleFonts.cairo(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // ★ الوصفة الطبية المرفقة عند الطلب (دواء يتطلب وصفة) —
                  //   تظهر للأدمن وصاحب الصيدلية فقط. لا سطر إن لم تكن.
                  if ('${order['prescription_path'] ?? ''}'.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => ImageViewerScreen.open(
                        context,
                        url: order['prescription_path']?.toString(),
                        title: 'الوصفة الطبية · طلب ${order['order_number'] ?? order['serial_number'] ?? ''}',
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.medical_information_rounded,
                              size: 16, color: AppColors.warning),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'الوصفة الطبية المرفقة — اضغط لعرضها',
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: AppColors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'المجموع: ${CurrencyFormatter.format((order['total_amount'] is num ? (order['total_amount'] as num) : 0).toDouble())}',
                    style: GoogleFonts.cairo(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  // ★ تحكم الأدمن بحالة الطلب: ينقله بين الحالات أو يلغيه.
                  const SizedBox(height: 18),
                  Text(
                    'تغيير حالة الطلب',
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'تُحفَظ الأوقات مع الحالة ويصل الخبر للزبون والمندوب.',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      color: AppColors.textHint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (key, label, icon) in _statusActions)
                        _statusChip(order, key, label, icon, ctx),
                    ],
                  ),
                  if (canReopen) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final ok = await SupabaseService.instance.reopenOrder(
                          order['id'].toString(),
                        );
                        if (!mounted) return;
                        if (ok) {
                          await SupabaseService.instance.broadcastUpdate(
                            title: 'أُعيد فتح الطلب',
                            body:
                                'الطلب ${OrderDisplay.serial(order)} عاد متاحاً للمندوبين.',
                            status: 'pending',
                            orderId: order['id']?.toString(),
                          );
                        }
                        _showMessage(
                          ok
                              ? 'أُعيد فتح الطلب ليأخذه مندوب آخر'
                              : 'تعذر إعادة الفتح',
                          ok,
                        );
                        if (ok) _load();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.replay_rounded),
                      label: Text(
                        'إعادة فتح الطلب للتحويل لمندوب آخر',
                        style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'مراقبة الطلبات',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: TapToDismissKeyboard(
        child: Column(
          children: [
            // ★ تحذير المكررات — أعلى الشاشة، ولا يظهر إطلاقاً حين لا
            //     تكرار، ولا يظهر لغير حساب الأدمن.
            DuplicateOrdersPanel(
              groups: _duplicates,
              expanded: _showAllDuplicates,
              onToggle: (v) => setState(() => _showAllDuplicates = v),
              onOpenReceipt: _openDuplicateReceipt,
              statusLabel: (status) => _label({'status': status}),
            ),
            // بحث إداري بالرقم التسلسلي (مثال: #12 أو 12).
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      textAlign: TextAlign.right,
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: 'ابحث برقم الطلب التسلسلي…',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _searchCtrl.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: _clearSearch,
                              ),
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.surfaceTint.withValues(alpha: 0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _searching ? null : _search,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _searching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search_rounded, size: 20),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: _tabs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final (key, label) = _tabs[i];
                  final selected = _filter == key;
                  return ChoiceChip(
                    label: Text(
                      '$label (${_countFor(key)})',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: selected
                            ? Colors.white
                            : AppColors.textSecondary,
                      ),
                    ),
                    selected: selected,
                    selectedColor: AppColors.primary,
                    backgroundColor: AppColors.surfaceTint,
                    onSelected: (_) => setState(() => _filter = key),
                  );
                },
              ),
            ),
            // ★ ملخّص أكواد الخصم للمندوبين — يُفتح بكلمة المرور ولا يُحمَّل
            //     تلقائياً: تقرير مالي، والأدمن وحده يطلبه.
            _couponPanel(),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : AppRefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: _load,
                      child: filtered.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                const SizedBox(height: 120),
                                const Icon(
                                  Icons.assignment_outlined,
                                  size: 64,
                                  color: AppColors.textHint,
                                ),
                                const SizedBox(height: 12),
                                Center(
                                  child: Text(
                                    'لا توجد طلبات',
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
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final o = filtered[i];
                                return Card(
                                  elevation: 1.5,
                                  margin: const EdgeInsets.only(bottom: 10),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () => _showDetails(o),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.receipt_long_rounded,
                                                size: 20,
                                                color: AppColors.primary,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  OrderDisplay.serial(o),
                                                  style: GoogleFonts.cairo(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w900,
                                                    color:
                                                        AppColors.textPrimary,
                                                  ),
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: _color(
                                                    o,
                                                  ).withValues(alpha: 0.12),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                                child: Text(
                                                  _label(o),
                                                  style: GoogleFonts.cairo(
                                                    color: _color(o),
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            'الزبون: ${AccountName.withPhone(name: o['user_name'], phone: o['user_phone'])}',
                                            style: GoogleFonts.cairo(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.textPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'المندوب: ${OrderDisplay.driverName(o)}',
                                            style: GoogleFonts.cairo(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                          if (o['assigned_driver_phone']
                                                  ?.toString()
                                                  .isNotEmpty ==
                                              true)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons
                                                        .delivery_dining_rounded,
                                                    size: 14,
                                                    color: AppColors.success,
                                                  ),
                                                  const SizedBox(width: 5),
                                                  Expanded(
                                                    child: Text(
                                                      'المندوب الذي استلم الطلب: ${o['assigned_driver_phone']}',
                                                      style: GoogleFonts.cairo(
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color:
                                                            AppColors.success,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          if ((o['status']?.toString() ==
                                                      'rejected' ||
                                                  o['status']?.toString() ==
                                                      'cancelled') &&
                                              o['rejection_reason']
                                                      ?.toString()
                                                      .isNotEmpty ==
                                                  true)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.block_rounded,
                                                    size: 14,
                                                    color: AppColors.danger,
                                                  ),
                                                  const SizedBox(width: 5),
                                                  Expanded(
                                                    child: Text(
                                                      'سبب الرفض: ${o['rejection_reason']}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: GoogleFonts.cairo(
                                                        fontSize: 11.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: AppColors.danger,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          // ★ «مَن رفض» — للأدمن وحده، وبلا
                                          //   سطر حين لا يكون الاسم معروفاً.
                                          if (_rejecterLabel(
                                            o,
                                            hideUnknown: true,
                                          ).isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 2,
                                              ),
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.person_off_rounded,
                                                    size: 14,
                                                    color:
                                                        AppColors.textSecondary,
                                                  ),
                                                  const SizedBox(width: 5),
                                                  Expanded(
                                                    child: Text(
                                                      'مَن رفض: ${_rejecterLabel(o, hideUnknown: true)}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: GoogleFonts.cairo(
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: AppColors
                                                            .textSecondary,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  CurrencyFormatter.format(
                                                    (o['total_amount'] is num
                                                            ? (o['total_amount']
                                                                  as num)
                                                            : 0)
                                                        .toDouble(),
                                                  ),
                                                  style: GoogleFonts.cairo(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w900,
                                                    color: AppColors.primary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          // ★ وقت الطلب الحقيقي: ساعة الإرسال
                                          //   بالتوقيت المحلي مع المدة الحيّة
                                          //   بالساعة والدقيقة. كان هذا السطر نص
                                          //   القاعدة الخام (`created_at` مقطوعاً
                                          //   على ١٦ حرفاً) — UTC بلا منطقة ولا
                                          //   معنى، وطلبان «منذ ٣ ساعات» يبدوان
                                          //   للأدمن في لحظة واحدة. السطر يتقدّم
                                          //   وحده كما عند المندوب والزبون، من
                                          //   `OrderElapsed` نفسها.
                                          if (OrderElapsed.placedAt(o) != null)
                                            ...[
                                              const SizedBox(height: 2),
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.schedule_rounded,
                                                    size: 13,
                                                    color: AppColors.textHint,
                                                  ),
                                                  const SizedBox(width: 5),
                                                  Flexible(
                                                    child: OrderElapsedText(
                                                      order: o,
                                                      withClock: true,
                                                      precise: true,
                                                      showIcon: false,
                                                      style: GoogleFonts.cairo(
                                                        fontSize: 10.5,
                                                        color:
                                                            AppColors.textHint,
                                                        fontWeight:
                                                            FontWeight.w700,
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
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// ★ يفتح تفاصيل طلب من لوحة التحذير: البحث عنه في القائمة المحمّلة
  ///   أصلا، فلا نداء شبكة زائداً ولا شاشة فارغة لطلب حُذف بعدها.
  void _openDuplicateReceipt(DuplicateReceipt r) {
    final order = _orderById(r.orderId);
    if (order != null) _showDetails(order);
  }

  /// ★ لوحة أكواد الخصم التي استلمها كل مندوب.

  ///
  /// ★ «بلا تكرار» مضمونة في القاعدة لا هنا: التجميع على
  ///   (المندوب + الكود)، والقيد `unique (order_id)` في دفتر المحفظة.
  ///   فلا يمكن للطلب أن يُحسب مرتين ولا أن يظهر الكود مرتين.
  Widget _couponPanel() {
    final data = _couponSummary;
    final items = (data?['items'] as List?) ?? const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.local_offer_rounded,
                  size: 20,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'أكواد الخصم التي استلمها المندوبون',
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                // ★ الزر يبقى ظاهراً دائماً. كان `if (data == null)` فيختفي بعد
                //   أول ضغطة — فإن فشل الطلب لأوّل مرة لم يجرّب ثانية،
                //   وظنّ المستخدم أنّ الزر «معطّل». إعادة المحاولة
                //   بعد تصحيح كلمة السر أو تشغيل SQL يجب أن تكون مكافأة.
                TextButton(
                  onPressed: _couponBusy ? null : _loadCoupons,
                  // ★ أثناء الجلب: دائرة صغيرة مكان الكلمة والزّر معطّل.
                  //   المسار ندائان متتابعان في الخادم، فبدل أن يبقى
                  //   «عرض» ولا يتغيّر شيء — وهو ما يوحي بالشاشة المعلقة —
                  //   يرى الأدمن أنه يعمل ولا يركّم محاولة فوقها.
                  child: _couponBusy
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              'يُحمَّل',
                              style: GoogleFonts.cairo(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        )
                      : Text(
                          data == null ? 'عرض' : 'تحديث',
                          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                        ),
                ),
              ],
            ),
            if (_couponBusy) ...[
              const SizedBox(height: 6),
              Text(
                'يتحقّق من الصلاحية في الخادم ثم يجلب التقرير — ثوانٍ على شبكة ضعيفة.',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
            if (_couponError != null) ...[
              const SizedBox(height: 6),
              Text(
                _couponError!,
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.danger,
                ),
              ),
            ],
            if (data != null) ...[
              const SizedBox(height: 8),
              Text(
                'المستحق الكلي ${CurrencyFormatter.format((data['total_due'] is num ? (data['total_due'] as num) : 0).toDouble())}'
                ' · ${data['drivers'] ?? 0} مندوب · ${data['rows'] ?? 0} طلب',
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 10),
              if (items.isEmpty)
                Text(
                  'لا يوجد مندوب استلم كود خصم بعد.',
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                for (final d in items) _driverRow(d),
            ],
          ],
        ),
      ),
    );
  }

  /// صفّ مندوب واحد: اسمه، عدد طلباته، مستحقّه، وأكواده بنسبها.
  Widget _driverRow(Map<String, dynamic> d) {
    final codes = (d['codes'] as List?) ?? const [];
    final name = '${d['driver_name'] ?? ''}'.trim();
    final phone = '${d['driver_phone'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  AccountName.withPhone(name: name, phone: phone),
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '${(d['orders'] is num ? (d['orders'] as num) : 0).toString()} طلب'
                ' · ${CurrencyFormatter.format((d['total_due'] is num ? (d['total_due'] as num) : 0).toDouble())}',
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          // ★ كل كود مرة واحدة بنسبته الحقيقية — لا نجمع نسبتين.
          for (final c in codes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Text(
                    '${c['code'] ?? '—'}',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // ★ نسبة الكود كما في قاعدة البيانات، لا محسوبة.
                  if ((c['percent'] is num ? (c['percent'] as num) : 0) > 0)
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
                        '${(c['percent'] as num).toStringAsFixed(0)}٪',
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Text(
                    CurrencyFormatter.format(
                      (c['amount'] is num ? (c['amount'] as num) : 0)
                          .toDouble(),
                    ),
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// ★ نافذة كلمة فتح اللوحة — تُدير محرّرها بنفسها.
///
///   **لماذا مكوّن لا حوار مبنيّ في الشاشة؟** المحرّر كان يُنشأ خارج
///   `showDialog` ويُتحرَّر لحظة `pop`. لكن الـ`pop` يُكمل الأنيميشن
///   العكسي، والحقل ما زال في الشجرة يستمع إلى محرّره: تحريره هناك
///   يُسقط استثناء في إطار الإغلاق (وهو ما كان يُوحي أنّ النافذة «ما
///   انغلقت»). هنا المحرّر ملك الحالة الداخليّة للنافذة، فيتحرّر معها
///   حين تُزال فعلاً — لا لحظة الضغط.
///
///   اسمها عام لا خاص: ليصل إليها الاختبار `admin_credential_dialog_test.dart`
///   ويُغلِقها كما يُغلقها الأدمن بلمسته، فيُثبت أن لا استثناء في الإغلاق.
class AdminCredentialDialog extends StatefulWidget {
  const AdminCredentialDialog({
    super.key,
    required this.title,
    required this.actionLabel,
  });

  final String title;
  final String actionLabel;

  @override
  State<AdminCredentialDialog> createState() => _AdminCredentialDialogState();
}

class _AdminCredentialDialogState extends State<AdminCredentialDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        widget.title,
        style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
      ),
      content: TextField(
        controller: _ctrl,
        obscureText: true,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
        decoration: InputDecoration(
          labelText: 'كلمة مرور الأدمن',
          labelStyle: GoogleFonts.cairo(),
          border: const OutlineInputBorder(),
        ),
        style: GoogleFonts.cairo(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('إلغاء', style: GoogleFonts.cairo()),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(widget.actionLabel, style: GoogleFonts.cairo()),
        ),
      ],
    );
  }
}

/// ★ حقل سبب الإلغاء/الرفض — ملكه ومحرّره في مكان واحد، للسبب نفسه الذي
///   جعل نافذة الكلمة مكوّناً: لا محرّر خارجي يُتحرَّر قبل زوال الحقل.
class AdminReasonField extends StatefulWidget {
  const AdminReasonField({super.key, required this.onChanged});

  final void Function(String) onChanged;

  @override
  State<AdminReasonField> createState() => _AdminReasonFieldState();
}

class _AdminReasonFieldState extends State<AdminReasonField> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      autofocus: true,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: 'سبب الإلغاء/الرفض (اختياري)',
        labelStyle: GoogleFonts.cairo(),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      style: GoogleFonts.cairo(),
    );
  }
}
