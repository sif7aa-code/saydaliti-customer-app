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

/// ★★ طلبات الوصفة بانتظار موافقة صاحب الصيدلية.
///
/// الطلب الذي يحمل دواءً بوصفة لا يصل المندوبين إطلاقاً قبل هذه
/// الشاشة: يُقيد بحالة `pharmacy_review`، ويظهر هنا **مع صورة
/// الوصفة**، وأزرار المندوبين مقفلة في القاعدة والتطبيق. «قبول»
/// يحوّله إلى `pending` ويُشعر المندوبين، و«رفض» يلغيه ويبلغ الزبون
/// بالسبب. (طلب الأدمن 2026-11-20)
class PharmacyReviewScreen extends StatefulWidget {
  const PharmacyReviewScreen({super.key});

  @override
  State<PharmacyReviewScreen> createState() => _PharmacyReviewScreenState();
}

class _PharmacyReviewScreenState extends State<PharmacyReviewScreen>
    with TabRefreshTarget<PharmacyReviewScreen> {
  @override
  String get tabId => 'owner_prescriptions';

  @override
  Future<void> Function() onTabRefresh() => _load;

  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;

  /// معرّف الطلب الذي تنفَّذ عليه عملية الآن — تبقى بطاقته وحدها
  /// بدوّارة، وبقية الطلبات تظل قابلة للقراءة.
  String? _busyId;

  StreamSubscription<RealtimeEvent>? _rtSub;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _listenRealtime();
    // ★ بثّ طلبات صاحب الصيدلية لا يصل من السيرفر (البثّ للمندوب
    //   والأدمن)، فيبقى الاستطلاع الهادئ هو ما يُظهر الطلب الجديد
    //   والشاشة مفتوحة. كل ٢٠ ثانية رحمة واحدة صغيرة.
    _poll = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_refreshQuiet()),
    );
  }

  void _listenRealtime() {
    _rtSub?.cancel();
    _rtSub = RealtimeService.instance.events.listen((e) {
      if (!mounted) return;
      if (e.topic == RtEvent.orderNew || e.topic == RtEvent.orderStatus) {
        unawaited(_refreshQuiet());
      }
    });
    RealtimeService.instance.start();
  }

  @override
  void dispose() {
    _rtSub?.cancel();
    _poll?.cancel();
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

  static String _label(Map<String, dynamic> o) {
    final s = o['serial_number'] ?? o['order_number'];
    final t = '${s ?? ''}'.trim();
    if (t.isEmpty) return '—';
    return t.replaceFirst(RegExp(r'^#'), '');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final phone = AuthService.instance.phone ?? '';
    final list = await SupabaseService.instance.fetchPharmacyReviewOrders(
      phone,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      // ★ `rpcRows` يرجع قائمة ثابتة الطول (`growable: false`)، و
      //   `removeWhere` عليها يرمي UnsupportedError صامتاً في الإصدار:
      //   كان القبول ينجح في القاعدة ولا تختفي البطاقة. النسخة
      //   المتزايدة ضرورية لا تجميلية.
      _orders = List<Map<String, dynamic>>.from(list ?? const []);
      _error = list == null
          ? (SupabaseService.instance.lastPharmacyReviewError ??
                'تعذّر جلب الطلبات')
          : null;
    });
  }

  bool _quietBusy = false;

  Future<void> _refreshQuiet() async {
    if (_quietBusy || _loading) return;
    _quietBusy = true;
    final phone = AuthService.instance.phone ?? '';
    final list = await SupabaseService.instance.fetchPharmacyReviewOrders(
      phone,
    );
    _quietBusy = false;
    if (!mounted || list == null) return;
    setState(() => _orders = List<Map<String, dynamic>>.from(list));
  }

  void _toast(String msg, bool ok) {
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
          duration: const Duration(seconds: 4),
        ),
      );
  }

  String _errorText(Map<String, dynamic>? res) => switch (res?['error']) {
    'NOT_OWNER' => 'هذا الطلب لا يخصّ صيدليتك',
    'NOT_IN_REVIEW' || 'ALREADY_HANDLED' => 'تمت معالجة الطلب من جهاز آخر',
    'NOT_FOUND' => 'الطلب غير موجود — ربما حُذف',
    _ => 'تعذّرت العملية — تحقّق من الاتصال وحاول مجدداً',
  };

  Future<void> _approve(Map<String, dynamic> o) async {
    final id = o['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final label = _label(o);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'قبول الطلب $label',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'بعد القبول يظهر الطلب للمندوبين وتُفتح أزرارهم، '
          'وتصلهم رسالة توصيله إلى الزبون.\n\n'
          'تأكّد أن الوصفة مطابقة وأن الدواء جاهز قبل القبول.',
          style: GoogleFonts.cairo(fontSize: 13, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text('قبول وإرسال', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busyId = id);
    final res = await SupabaseService.instance.approvePharmacyOrder(
      id,
      AuthService.instance.phone ?? '',
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    if (res?['ok'] == true) {
      setState(() => _orders.removeWhere((e) => e['id']?.toString() == id));
      _toast('تم قبول الطلب $label — ظهر للمندوبين الآن', true);
      unawaited(_refreshQuiet());
    } else {
      _toast(_errorText(res), false);
      unawaited(_refreshQuiet());
    }
  }

  Future<void> _reject(Map<String, dynamic> o) async {
    final id = o['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final label = _label(o);
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'رفض الطلب $label',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'يُلغى الطلب ويصل الزبون سبب الرفض. '
              'مثال: الوصفة غير واضحة أو الدواء غير متوفر.',
              style: GoogleFonts.cairo(fontSize: 12.5, height: 1.6),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              style: GoogleFonts.cairo(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'سبب الرفض (يظهر للزبون)',
                labelStyle: GoogleFonts.cairo(fontSize: 12.5),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, reasonCtrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text('رفض الطلب', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    setState(() => _busyId = id);
    final res = await SupabaseService.instance.rejectPharmacyOrder(
      id,
      AuthService.instance.phone ?? '',
      reason.isEmpty ? 'رفضت الصيدلية الطلب' : reason,
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    if (res?['ok'] == true) {
      setState(() => _orders.removeWhere((e) => e['id']?.toString() == id));
      _toast('تم رفض الطلب $label وإبلاغ الزبون', true);
      unawaited(_refreshQuiet());
    } else {
      _toast(_errorText(res), false);
      unawaited(_refreshQuiet());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'الطلبات والوصفات',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        // ★ في البداية (يمين RTL) لا `actions` — زر الخروج العائم
        //   في ShopOwnerShell يبتلع لمس الحافة اليسرى.
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
                padding: const EdgeInsets.all(14),
                children: [
                  if (_error != null)
                    _message(_error!, warn: true)
                  else ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _orders.isEmpty
                            ? 'لا توجد طلبات بانتظار موافقتك'
                            : '${_orders.length} طلب وصفة بانتظار موافقتك',
                        style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    if (_orders.isEmpty)
                      _message(
                        'طلبات الوصفة تظهر هنا أولاً —\n'
                        'لا يراها المندوبون ولا تُفتح أزرارهم إلا بعد موافقتك.',
                      )
                    else
                      for (final o in _orders) _card(o),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> o) {
    final id = o['id']?.toString() ?? '';
    final label = _label(o);
    final customer = AccountName.withPhone(
      name: o['user_name'],
      phone: o['user_phone'],
    );
    final address = '${o['address'] ?? ''}'.trim();
    final notes = '${o['notes'] ?? ''}'.trim();
    final rx = '${o['prescription_path'] ?? ''}'.trim();
    final items = (o['items'] as List?) ?? const [];
    final busy = _busyId == id;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.medical_information_rounded,
                  color: AppColors.warning,
                  size: 23,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'طلب وصفة $label',
                      style: GoogleFonts.cairo(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '${_when(o['created_at'])} · بانتظار موافقتك',
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                CurrencyFormatter.format(_d(o['total_amount'])),
                style: GoogleFonts.cairo(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _line(Icons.person_rounded, customer),
          if (address.isNotEmpty) _line(Icons.location_on_rounded, address),
          if (notes.isNotEmpty)
            _line(Icons.sticky_note_2_rounded, 'ملاحظة الزبون: $notes'),

          // ★ صورة الوصفة نفسها — هي سبب وجود هذه الشاشة: القرار
          //   (قبول/رفض) يُبنى على قراءتها. تُفتح بالحجم الكامل.
          if (rx.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => ImageViewerScreen.open(
                context,
                url: rx,
                title: 'الوصفة الطبية · طلب $label',
              ),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 58,
                        height: 58,
                        child: AppImage(
                          rx,
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                          cacheWidth: 116,
                          cacheHeight: 116,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: AppColors.surfaceTint,
                            child: Icon(
                              Icons.medical_information_rounded,
                              color: AppColors.warning,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'صورة الوصفة المرفقة',
                            style: GoogleFonts.cairo(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: AppColors.warning,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'اضغط للعرض بالحجم الكامل قبل القرار',
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.open_in_full_rounded,
                      size: 18,
                      color: AppColors.warning,
                    ),
                  ],
                ),
              ),
            ),
          ],

          if (items.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final it in items) _chip(it)],
            ),
          ],

          const SizedBox(height: 12),
          if (busy)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _approve(o),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.check_circle_rounded, size: 18),
                    label: Text(
                      'قبول وإرسال للمندوبين',
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _reject(o),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: BorderSide(
                      color: AppColors.danger.withValues(alpha: 0.55),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.block_rounded, size: 16),
                  label: Text(
                    'رفض',
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.cairo(
              fontSize: 12,
              height: 1.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _chip(Map<String, dynamic> it) {
    final img = '${it['product_image'] ?? ''}'.trim();
    final qty = (it['quantity'] as num?)?.toInt() ?? 1;
    final name = '${it['product_name'] ?? 'منتج'}';
    return Container(
      width: 172,
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
              child: AppImage(
                img,
                width: 38,
                height: 38,
                fit: BoxFit.cover,
                cacheWidth: 76,
                cacheHeight: 76,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.surfaceTint,
                  child: Icon(Icons.medication_rounded, size: 16),
                ),
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
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '$qty × ${CurrencyFormatter.format(_d(it['price']))}',
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

  Widget _message(String text, {bool warn = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 12),
    child: Column(
      children: [
        Icon(
          warn ? Icons.error_outline_rounded : Icons.receipt_long_outlined,
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
