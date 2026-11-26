import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';
import 'admin_discounts_screen.dart';
import 'admin_banners_screen.dart';
import 'admin_categories_screen.dart';
import 'admin_devices_screen.dart';
import 'admin_doctor_categories_screen.dart';
import 'admin_doctors_screen.dart';
import 'admin_doctor_wallets_screen.dart';
import 'admin_deductions_screen.dart';
import 'admin_driver_wallets_screen.dart';
import 'admin_orders_screen.dart';
import 'admin_products_screen.dart';
import 'admin_provider_applications_screen.dart';
import 'admin_shop_owners_screen.dart';
import 'admin_users_screen.dart';
import 'secretary_appointments_screen.dart';
import 'wallet_screen.dart';
import '../widgets/app_refresh_indicator.dart';

/// لوحة تحكم الأدمن
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Map<String, dynamic> _stats = const {};
  bool _loadingStats = true;
  bool _statsFailed = false;

  // ===== الإحصائيات بالفترة المختارة (الجديدة) =====
  DateTimeRange _range = _lastDays(30);
  Map<String, dynamic> _rangeStats = const {};
  bool _rangeLoading = false;
  String? _rangeError;
  bool _rangeFromFallback = false;

  /// آخر [n] يوماً شاملاً اليوم.
  static DateTimeRange _lastDays(int n) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTimeRange(
      start: today.subtract(Duration(days: n - 1)),
      end: today,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadRange();
  }

  Future<void> _loadRange() async {
    if (!mounted) return;
    setState(() {
      _rangeLoading = true;
      _rangeError = null;
    });
    final s = await SupabaseService.instance.fetchOrderStatsRange(
      _range.start,
      _range.end,
    );
    if (!mounted) return;
    setState(() {
      _rangeStats = s;
      _rangeLoading = false;
      _rangeError = SupabaseService.instance.lastOrderStatsError;
      _rangeFromFallback = s['local_fallback'] == true;
    });
  }

  /// اختيار فترة يدوية عبر نافذتَي تاريخ (من / إلى).
  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
      helpText: 'اختر الفترة',
      saveText: 'اعتماد',
      cancelText: 'إلغاء',
      builder: (ctx, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: Colors.white,
              onSurface: AppColors.textPrimary,
              surface: Colors.white,
            ),
          ),
          child: child!,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
    await _loadRange();
  }

  /// اختيار سريع: اليوم / ٧ أيام / ٣٠ يوم / هذا الشهر.
  void _preset(DateTimeRange r) {
    setState(() => _range = r);
    _loadRange();
  }

  String _fmtDay(DateTime d) => '${d.day}/${d.month}/${d.year}';

  int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  /// تحميل الإحصائيات مع إعادة المحاولة عند الفشل.
  Future<void> _loadStats() async {
    if (mounted) {
      setState(() => _loadingStats = true);
    }
    try {
      final s = await SupabaseService.instance.fetchOrderStats();
      if (!mounted) return;
      setState(() {
        _stats = s;
        _loadingStats = false;
        // ★ الفشل يعني **ردّاً غير صالح أو استثناءً**، لا «صفر طلبات».
        //   الخلط بينهما كان يعرض «تعذّر التحميل — تحقق من الإنترنت»
        //   على صيدلية جديدة لا طلبات فيها، فيبدو التطبيق معطّلاً.
        _statsFailed = s.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingStats = false;
        _statsFailed = true;
      });
    }
  }

  int _count(dynamic node) {
    if (node is Map) {
      final v = node['count'];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
    }
    return 0;
  }

  /// تسميات حالات الطلب كما في شاشة المراقبة.
  static const Map<String, String> _statusLabels = {
    'pending': 'قيد الانتظار',
    'pharmacy_review': 'بانتظار الصيدلية',
    'accepted': 'مقبول',
    'delivering': 'قيد التوصيل',
    'delivered': 'مكتمل',
    'rejected': 'مرفوض',
    'cancelled': 'ملغي',
  };

  double _amount(dynamic node) {
    if (node is Map) {
      final v = node['amount'];
      if (v is num) return v.toDouble();
    }
    return 0;
  }

  /// إرسال شعار (إشعار) للجميع مع رابط انتقال عند الضغط.
  Future<void> _sendBroadcast() async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final linkCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(
          Icons.campaign_rounded,
          color: AppColors.primary,
          size: 34,
        ),
        title: const Text('إرسال شعار للجميع', textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(
                  labelText: 'عنوان الشعار',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bodyCtrl,
                textAlign: TextAlign.right,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'نص الشعار',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: linkCtrl,
                textAlign: TextAlign.right,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'رابط عند الضغط (اختياري)',
                  hintText: 'https://example.com',
                  prefixIcon: Icon(Icons.link_rounded, size: 20),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إرسال للجميع'),
          ),
        ],
      ),
    );

    if (ok != true) {
      titleCtrl.dispose();
      bodyCtrl.dispose();
      linkCtrl.dispose();
      return;
    }
    final title = titleCtrl.text.trim();
    final body = bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'اكتب عنوان الشعار ونصه قبل الإرسال',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      titleCtrl.dispose();
      bodyCtrl.dispose();
      linkCtrl.dispose();
      return;
    }
    // الشعار لا يُخزَّن: دالة notify_broadcast في Supabase تتكفّل به.
    //  • إن كان مُرسِل Supabase مفعّلاً ⇒ ترسل FCM لكل من له توكن.
    //  • وإلا ⇒ تكتب صفاً مؤقتاً لكل حساب يُحذف فور عرضه.
    final result = await SupabaseService.instance.sendBroadcast(
      title: title,
      body: body,
      link: linkCtrl.text.trim(),
    );
    if (!mounted) return;
    final pushedNote = result.pushed > 0 ? ' (مع إشعار خارج التطبيق)' : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'تم إرسال الشعار إلى ${result.targets} مستخدم$pushedNote.'
              : 'تعذر الإرسال: '
                    '${result.error ?? 'دالة notify_broadcast غير موجودة'}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: result.ok ? AppColors.success : AppColors.danger,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
    titleCtrl.dispose();
    bodyCtrl.dispose();
    linkCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'لوحة تحكم الأدمن',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
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
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        'خروج',
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              await AuthService.instance.logout();
              // ★ بلا `pushAndRemoveUntil`: يحذف `home` معه فيصير
              //   `LoginScreen` مساراً ثابتاً لا يُعاد بناؤه بعد
              //   الدخول ⇒ إعادة تشغيل إجبارية. `logout()` وحده
              //   كافٍ عبر `notifyListeners`.
            },
          ),
        ],
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _loadStats,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // ===== إحصائيات الفترة المختارة يدوياً (الجديدة) =====
            _buildRangeStats(),
            const SizedBox(height: 14),
            // ===== إحصائيات الطلبات السريعة =====
            _buildStats(),
            // ===== محفظة الصيدليات: للأدمن الذي هو صاحب صيدلية =====
            //   الأدمن يُستثنى من واجهة صاحب الصيدلية في app.dart، فبلا هذه
            //   البطاقة لا يجد «المحفظة» الكاملة (سجل الطلبات) في أي مكان.
            if (AuthService.instance.isShopOwner) ...[
              const SizedBox(height: 14),
              _buildCard(
                context,
                title: 'محفظة اطباء ذي قار',
                subtitle: 'رصيد صيدليتك وسجل الطلبات المسلَّمة بعد الاستقطاع',
                icon: Icons.account_balance_wallet_rounded,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          const ShopWalletScreen(title: 'محفظة اطباء ذي قار'),
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 14),
            // ===== إرسال شعار للجميع =====
            _buildCard(
              context,
              title: 'إرسال شعار للجميع',
              subtitle: 'إشعار عام لكل المستخدمين مع رابط انتقال عند الضغط',
              icon: Icons.campaign_rounded,
              onTap: _sendBroadcast,
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'أكواد الخصم',
              subtitle: 'أنشئ كوداً: نسبة الخصم، مدته بالأيام، ومن يستحقه',
              icon: Icons.local_offer_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminDiscountsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'إدارة الأقسام',
              subtitle: 'إضافة أقسام مع صورة، حذف قسم',
              icon: Icons.category_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminCategoriesScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ★ نشر الأقسام بسهولة: الزر يعرض منتجات كل الصيدليات مباشرة،
            //   ولكل منتج سطر «نقل» إلى أقسام الرئيسية أو إنشاء قسم جديد.
            //   إدارة الصيدليات نفسها (إضافة/حذف) من زر «الصيدليات» أعلى
            //   شاشة المنتجات.
            _buildCard(
              context,
              title: 'الصيدليات والمنتجات',
              subtitle:
                  'كل المنتجات لكل صيدلية مع نقل مباشر إلى أقسام الرئيسية '
                  'أو إنشاء قسم جديد — وإدارة الصيدليات من زر أعلى الشاشة',
              icon: Icons.storefront_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminProductsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'الأجهزة والإشعارات',
              subtitle: 'أي هاتف يستقبل إشعاراً حتى والتطبيق مغلق',
              icon: Icons.devices_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminDevicesScreen()),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'إدارة المستخدمين',
              subtitle: 'تعيين أو إلغاء مندوبية، حذف مستخدم',
              icon: Icons.people_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminUsersScreen()),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'محافظ الصيدليات وأصحابها',
              subtitle:
                  'مبلغ كل صيدلية بعد الاستقطاع (السعر الكلي والاستقطاع) '
                  'مع تصفير الرصيد',
              icon: Icons.store_mall_directory_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminShopOwnersScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'محفظة المندوبين',
              subtitle:
                  'رصيد كل مندوب وسجل التصفيرات — تصفير حقيقي يسجّل دفعة في الدفتر',
              icon: Icons.delivery_dining_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminDriverWalletsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'إدارة الأطباء',
              subtitle: 'إضافة طبيب أو مجمع أو مختبر بصورته، تعديل، حذف',
              icon: Icons.medical_services_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminDoctorsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ★ طلبات الانضمام: حسابات الطبيب/الممرض/الصيدلاني من التسجيل
            //   لا تظهر رسمياً إلا بعد اعتمادها هنا.
            _buildCard(
              context,
              title: 'طلبات الانضمام',
              subtitle:
                  'طلبات الأطباء والممرضين والصيدلانيين: اعتماد ينشر الحساب '
                  'ويضبط الكشفية أو النسبة، أو رفض بسبب',
              icon: Icons.how_to_reg_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminProviderApplicationsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ★ أقسام الدليل: الأدمن يضيف زرّاً جديداً مثل «الأطباء
            //   والمجمعات والمختبرات» فيظهر أعلى الرئيسية فوراً.
            _buildCard(
              context,
              title: 'أقسام دليل الأطباء',
              subtitle:
                  'أضف زرّاً جديداً أعلى الرئيسية (مثل المجمعات والمختبرات) '
                  'ويظهر للمستخدمين فوراً',
              icon: Icons.category_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminDoctorCategoriesScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ★ موافقات حجوزات العيادات (11-19): الأدمن يعتمد أو يرفض
            //   حجزاً بانتظار السكرتير، تماماً كما يفعل السكرتير.
            _buildCard(
              context,
              title: 'موافقات حجوزات الأطباء',
              subtitle:
                  'الحجوزات المنتظرة: اعتماد أو رفض، وكشفية 15,000 في محفظة الطبيب',
              icon: Icons.fact_check_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SecretaryAppointmentsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ★ محافظ الأطباء (11-19): صافي الكشفيات بعد الاستقطاع
            //   الذي يحدده الأدمن لكل عيادة، والتصفير يدوي من هنا بكلمة
            //   مرور الأدمن — لا يحذف قيداً.
            _buildCard(
              context,
              title: 'محافظ الأطباء',
              subtitle:
                  'الكشفية، الاستقطاع، الصافي، والتصفير اليدوي '
                  'بكلمة مرور الأدمن',
              icon: Icons.account_balance_wallet_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminDoctorWalletsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ★ الاستقطاعات: المكان الوحيد الذي يقرأ منه كل مسار مالي.
            _buildCard(
              context,
              title: 'الاستقطاعات',
              subtitle:
                  'حدد لكل عيادة وصيدلية: مبلغ ثابت أو نسبة — '
                  'يسري على كل حسابات التطبيق',
              icon: Icons.percent_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminDeductionsScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'إدارة البانرات',
              subtitle: 'إضافة بانر مع صورة من المعرض، ضبط سرعة التقليب، حذف',
              icon: Icons.view_carousel_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminBannersScreen()),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildCard(
              context,
              title: 'مراقبة الطلبات',
              subtitle:
                  'كل الطلبات مع فلاتر الحالة، مفاتيح إعادة فتح الطلبات للتحويل لمندوب آخر',
              icon: Icons.assignment_rounded,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminOrdersScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// ★ لوحة إحصائيات الفترة المختارة يدوياً.
  ///
  /// الأرقام كلها من `order_stats_range` على الخادم: تجميع حقيقي في
  /// الاستعلام، لا تنزيل آلاف الصفوف إلى الهاتف. والحالة القديمة
  /// (اليوم/الأسبوع/٣٠) لم تكن قابلة للاختيار ولا تغطي يوماً بعينه.
  Widget _buildRangeStats() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final monthStart = DateTime(now.year, now.month, 1);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppColors.buttonGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ----- الترويسة + اختيار التاريخ -----
          Row(
            children: [
              const Icon(
                Icons.date_range_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'إحصائيات الفترة',
                style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => AppRefresh.run(_loadRange),
                child: const Icon(
                  Icons.refresh_rounded,
                  color: Colors.white,
                  size: 19,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // الفترة المختارة + زر التقويم
          InkWell(
            onTap: _pickRange,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_fmtDay(_range.start)}  ←  ${_fmtDay(_range.end)}',
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    'اختيار تاريخ',
                    style: GoogleFonts.cairo(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.edit_calendar_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // اختصارات
          Row(
            children: [
              _presetChip('اليوم', _lastDays(1)),
              _presetChip('٧ أيام', _lastDays(7)),
              _presetChip('٣٠ يوماً', _lastDays(30)),
              _presetChip(
                'هذا الشهر',
                DateTimeRange(start: monthStart, end: today),
              ),
            ],
          ),

          const SizedBox(height: 14),

          if (_rangeLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            )
          else ...[
            if (_rangeError != null)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: Colors.white,
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'أرقام احتياطية محسوبة في الجهاز'
                        '${_rangeFromFallback ? '' : ''}: $_rangeError',
                        style: GoogleFonts.cairo(
                          color: Colors.white,
                          fontSize: 10.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ..._rangeBody(),
          ],
        ],
      ),
    );
  }

  Widget _presetChip(String label, DateTimeRange r) {
    final active = r.start == _range.start && r.end == _range.end;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          onTap: () => _preset(r),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              style: GoogleFonts.cairo(
                color: active ? AppColors.primary : Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// الأرقام التفصيلية + الأعمدة البيانية + أفضل الصيدليات.
  ///
  /// ★ المكتمل وحده يدخل هذه الأرقام: المرفوض والملغي — وكل ما لم
  ///   يكتمل — لا يظهران هنا إطلاقاً.
  List<Widget> _rangeBody() {
    final count = _i(_rangeStats['count']);
    final amount = _d(_rangeStats['amount']);
    final customers = _i(_rangeStats['customers']);
    final avg = _d(_rangeStats['avg']);
    final daily = (_rangeStats['daily'] as List?) ?? const [];
    final topShops = (_rangeStats['top_shops'] as List?) ?? const [];

    if (count == 0 && !_rangeLoading) {
      return [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22),
          alignment: Alignment.center,
          child: Text(
            'لا توجد طلبات مكتملة في هذه الفترة',
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ];
    }

    final widgets = <Widget>[
      // مبيعات المكتملة وحدها
      Text(
        CurrencyFormatter.format(amount),
        style: GoogleFonts.cairo(
          color: Colors.white,
          fontSize: 27,
          fontWeight: FontWeight.w900,
        ),
      ),
      Text(
        'مبيعات الطلبات المكتملة ($count طلب)',
        style: GoogleFonts.cairo(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 12),
      Divider(color: Colors.white.withValues(alpha: 0.22), height: 1),
      const SizedBox(height: 12),
      _rangeRow(Icons.people_rounded, 'زبائن مختلفون', '$customers'),
      const SizedBox(height: 6),
      _rangeRow(
        Icons.receipt_rounded,
        'متوسط الطلب المكتمل',
        CurrencyFormatter.format(avg),
      ),
    ];

    // ----- الأعمدة البيانية اليومية -----
    if (daily.isNotEmpty) {
      widgets
        ..add(const SizedBox(height: 16))
        ..add(
          Text(
            'الطلبات المكتملة يومياً',
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        )
        ..add(const SizedBox(height: 8))
        ..add(_dailyBars(daily));
    }

    // ----- أفضل الصيدليات -----
    if (topShops.isNotEmpty) {
      widgets
        ..add(const SizedBox(height: 16))
        ..add(
          Text(
            'أفضل الصيدليات في الفترة (طلبات مكتملة)',
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        )
        ..add(const SizedBox(height: 8));
      for (final s in topShops) {
        final name = (s as Map)['shop_name']?.toString() ?? '';
        if (name.isEmpty) continue;
        widgets
          ..add(
            _rangeRow(
              Icons.storefront_rounded,
              name,
              CurrencyFormatter.format(_d(s['gross'])),
            ),
          )
          ..add(const SizedBox(height: 6));
      }
    }

    return widgets;
  }

  Widget _rangeRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.85), size: 15),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.cairo(
              color: Colors.white.withValues(alpha: 0.92),
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

  /// أعمدة يومية: أطول عمود = أعلى عدد طلبات.
  ///
  /// نبنيها بـContainer لا بمكتبة رسم: أخف بـkilobytes، ولا خطر
  /// إضافة حزمة جديدة على بناء مُختبَر.
  Widget _dailyBars(List daily) {
    var maxCount = 1;
    for (final d in daily) {
      final c = _i((d as Map)['count']);
      if (c > maxCount) maxCount = c;
    }
    // نُبقي آخر ١٤ يوماً حتى لا تصبح الواجهة غير مقروءة.
    final shown = daily.length > 14 ? daily.sublist(daily.length - 14) : daily;

    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final d in shown)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '${_i((d as Map)['count'])}',
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      height: (46 * (_i(d['count']) / maxCount)).clamp(
                        3.0,
                        46.0,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      (d['day'] as String).length >= 10
                          ? (d['day'] as String).substring(8, 10)
                          : '',
                      style: GoogleFonts.cairo(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 7.5,
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

  /// لوحة إحصائيات الطلبات: اليوم / الشهر / الكل (أرقام حقيقية).
  Widget _buildStats() {
    if (_loadingStats) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    // فشل الجلب أو لا توجد بيانات: نوضّح ذلك مع زر إعادة المحاولة.
    if (_statsFailed) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: AppColors.danger,
              size: 22,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'تعذّر تحميل الإحصائيات — تحقق من الإنترنت',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
            TextButton(
              onPressed: _loadStats,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppColors.buttonGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                'إحصائيات الطلبات',
                style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => AppRefresh.run(_loadStats),
                child: const Icon(
                  Icons.refresh_rounded,
                  color: Colors.white,
                  size: 19,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // ★ «عدد الطلبات» كان لا يظهر للأدمن: البطاقات الخمس تحسب
          //   المكتمل فقط، فتبدو كلها أصفاراً ولو كانت هناك طلبات
          //   مرفوضة/قيد التنفيذ. هذا الصندوق يعرض إجمالي كل الحالات،
          //   وتحته توزيعها، فالأرقام المكتملة تبقى كما هي بلا مساس.
          Builder(
            builder: (_) {
              final byStatus = (_stats['by_status'] as Map?) ?? const {};
              var total = 0;
              for (final v in byStatus.values) {
                total += _i(v);
              }
              final chips = <Widget>[
                for (final e in _statusLabels.entries)
                  if (_i(byStatus[e.key]) > 0)
                    _statusPill(e.value, _i(byStatus[e.key])),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatBox(
                    label: 'إجمالي الطلبات (كل الحالات)',
                    count: total,
                    amount: 0,
                    icon: Icons.receipt_long_rounded,
                    wide: true,
                  ),
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: chips),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: 'مكتملة اليوم',
                  count: _count(_stats['today']),
                  amount: _amount(_stats['today']),
                  icon: Icons.today_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatBox(
                  label: 'مكتملة الشهر',
                  count: _count(_stats['month']),
                  amount: _amount(_stats['month']),
                  icon: Icons.calendar_today_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: 'مكتملة آخر ٧ أيام',
                  count: _count(_stats['week']),
                  amount: _amount(_stats['week']),
                  icon: Icons.date_range_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatBox(
                  label: 'مكتملة آخر ٣٠ يوماً',
                  count: _count(_stats['last_30_days']),
                  amount: _amount(_stats['last_30_days']),
                  icon: Icons.calendar_month_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _StatBox(
            label: 'إجمالي المكتملة (الكل)',
            count: _count(_stats['all_time']),
            amount: _amount(_stats['all_time']),
            icon: Icons.inventory_2_rounded,
            wide: true,
          ),
          // ★ الصفر هنا صحيح لا خلل: لا مكتمل بعد. نوضّح السبب حتى
          //   لا يظن الأدمن أن الإحصائيات تعطّلت.
          if (_count(_stats['all_time']) == 0) ...[
            const SizedBox(height: 8),
            Text(
              'لا طلب مكتمل بعد — المرفوض والملغي وقيد التنفيذ لا يُحتسبون؛ '
              'تتحرّك الأرقام عند أول طلب يصل «مكتمل».',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: Colors.white,
                fontSize: 10.5,
                height: 1.40,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'المبالغ والأرقام الزمنية تُحسب للطلبات المكتملة فقط',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// شريحة صغيرة: عدد طلبات حالة واحدة (مرفوض ٢ مثلاً).
  Widget _statusPill(String label, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$label · $count',
        style: GoogleFonts.cairo(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      // بدون clipBehavior كان أثر الضغط (InkWell) يتسرّب خارج الزوايا
      // المدوّرة فيظهر خطأ بصري فوق حدّ البطاقة ——including «إدارة الصيدليات».
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.primary, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      // بلا maxLines كان السطر الطويل (72 حرفاً) يتمدّد
                      // بلا حدّ فيكبر ارتفاع البطاقة ويصطفّ الكوم مرتجفاً.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        height: 1.35,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_ios_rounded, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// مربع إحصائي واحد داخل لوحة الأدمن.
class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.label,
    required this.count,
    required this.amount,
    required this.icon,
    this.wide = false,
  });

  final String label;
  final int count;
  final double amount;
  final IconData icon;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: wide ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisAlignment: wide
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: wide
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (amount > 0)
                  Text(
                    CurrencyFormatter.format(amount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 10,
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
