import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/discount_service.dart';
import '../services/admin_password_session.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

// =====================================================================
//  ★ لحظة الانتهاء الحقيقية (طلب الأدمن 2026-10-23): «المدة بالأيام»
//    صارت تاريخاً وساعة.
//
//    القاعدة ما زالت تحفظ `valid_from` + `valid_days` وتقرأ منهما
//    الانتهاء في كل دوال الأكواد، فلا دالة أُعيدت كتابتها هنا:
//    `admin_set_discount_code_expiry` (في `SQL_COUPON_REAL_EXPIRY.sql`)
//    تحلّ تلك المعادلة على اللحظة التي يختارها الأدمن، فتصير نهاية
//    الكود **بالثانية** لا بالأيام. الدور الوحيد للتطبيق: أن يجمع
//    التاريخ والساعة من الأدمن ويرسلهما، ويعرض اللحظة التي ترجعها
//    القاعدة.
// =====================================================================

/// الافتراضي: بعد خمسة أيام عند ١١:٥٩ ليلاً — نفس المدة التي كان
/// يقدّمها سلايدر «٥ أيام»، لكن كلحظة ثابتة (٢٣:٥٩) لا «بعد خمسة أيام
/// من هذه الدقيقة»، فيعرف الأدمن بالضبط متى يسقط الكود.
DateTime _defaultExpiry() {
  final d = DateTime.now().add(const Duration(days: 5));
  return DateTime(d.year, d.month, d.day, 23, 59);
}

/// «٢٨/١٠/٢٠٢٦ · ١١:٥٩ م» — بصيغة الأرقام التي تستعملها بقية شاشات
/// الأدمن (`_fmtDay`) بلا إدخال `intl` على هذا المسار.
String _expiryLabel(DateTime d) {
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day}/${d.month}/${d.year} · $h12:$mm ${d.hour < 12 ? 'ص' : 'م'}';
}

/// `expires_at` كما ترجعه دوال الأكواد: سلسلة ISO بتوقيت القاعدة،
/// تُقرأ محلياً ليراها الأدمن بالساعة التي اختارها. و`null` يعني
/// «لا وقت محفوظ» (قاعدة لم تُشغّل عليها `SQL_COUPON_REAL_EXPIRY.sql`)
/// — لا صفر ولا تاريخ افتراضي، فالتاريخ الوهمي أخطر من الفراغ.
DateTime? _expiryOf(Object? v) {
  final s = '${v ?? ''}'.trim();
  if (s.isEmpty || s == 'null') return null;
  return DateTime.tryParse(s)?.toLocal();
}

/// كم يوماً كاملاً يلزم لتغطية المتبقي حتى اللحظة — يُرسل في
/// `p_valid_days` مع الإنشاء كسقف **مؤقت** قبل ضبط اللحظة: لو نجح
/// الإنشاء وفشل ضبط الوقت (انقطاع شبكة مثلاً) يبقى الكود سارياً أطول
/// قليلاً من المطلوب، ولا يسقط أبكر منه.
int _daysUpTo(DateTime d) {
  final secs = d.difference(DateTime.now()).inSeconds;
  if (secs <= 0) return 1;
  return ((secs + 86399) ~/ 86400).clamp(1, 3650);
}

/// منتقي التاريخ ثم الساعة — والساعة تفتح على **الإدخال المكتوب**
/// لا القرص، لأن الدقيقة هنا تعني شيئاً («١١:٥٩» لا «١٢ تقريباً»)
/// والقرص لا يضمنها. `null` إن ألغى الأدمن في أي من الخطوتين.
Future<DateTime?> _pickExpiry(BuildContext ctx, DateTime initial) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: ctx,
    initialDate: initial.isAfter(now)
        ? initial
        : now.add(const Duration(days: 1)),
    firstDate: now.subtract(const Duration(days: 365)),
    lastDate: now.add(const Duration(days: 365 * 3)),
    helpText: 'تاريخ انتهاء الكود',
  );
  if (date == null || !ctx.mounted) return null;
  final time = await showTimePicker(
    context: ctx,
    initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    helpText: 'ساعة انتهاء الكود',
    initialEntryMode: TimePickerEntryMode.input,
  );
  if (time == null || !ctx.mounted) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// ★ بطاقة اختيار اللحظة — تُستعمل في نافذة الإنشاء وفي نافذة التعديل،
///   فموضع «ينتهي في» واحد في المكانين ولا نسختين منه.
class _ExpiryTile extends StatelessWidget {
  const _ExpiryTile({required this.value, required this.onTap});

  final DateTime value;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'ينتهي في',
          style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.iconContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.schedule_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _expiryLabel(value),
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  'تغيير',
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// ★ إدارة أكواد الخصم (الأدمن).
///
/// يصنع الكود ويحدّد: النسبة، ما يخصمه (التوصيل/المجموع)، **لحظة
/// انتهائه الحقيقية — تاريخ وساعة**، والمستهدف (كل الزبائن أو رقم
/// واحد). والوقت قابل للتعديل بعد الإنشاء من زر «تغيير وقت الانتهاء»
/// على كل بطاقة.
/// الحساب كله على الخادم — الشاشة تعرض وتطلب فقط.
class AdminDiscountsScreen extends StatefulWidget {
  const AdminDiscountsScreen({super.key});

  @override
  State<AdminDiscountsScreen> createState() => _AdminDiscountsScreenState();
}

class _AdminDiscountsScreenState extends State<AdminDiscountsScreen> {
  List<Map<String, dynamic>> _codes = const [];
  bool _loading = true;
  String? _note;

  // ★ حالة «الإنشاء التلقائي» (نسبة ثابتة ٥٪ كل ٣ طلبات مكتملة، والعدّ
  //   يبدأ من الصفر بعد كل استعمال): null = لم تُقرأ بعد من الخادم.
  bool? _autoEnabled;
  int _autoPercent = 5;
  int _autoEvery = 3;
  int _autoDays = 3;
  bool _autoSaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _note = null;
    });
    final res = await SupabaseService.instance.rpcCall(
      'admin_list_discount_codes',
      {},
    );
    // ★ حالة الزر تُقرأ مع القائمة وبلا credential: `discount_auto_state()`
    //   دالة قارئة قيمتها تظهر لكل زبون في «خصوماتي»، فطلب كلمة اللوحة
    //   عليها كان يجبر الأدمن على كتابتها كل فتح للصفحة.
    final auto = await SupabaseService.instance.rpcCall(
      'discount_auto_state',
      {},
    );
    if (!mounted) return;
    final rows = DiscountService.asRows(res);
    final a = auto is Map ? Map<String, dynamic>.from(auto) : null;
    setState(() {
      _codes = rows;
      _loading = false;
      if (a != null && a['ok'] == true) {
        _autoEnabled = a['enabled'] == true;
        _autoPercent = (a['percent'] as num?)?.toInt() ?? 5;
        _autoEvery = (a['every_orders'] as num?)?.toInt() ?? 3;
        _autoDays = (a['valid_days'] as num?)?.toInt() ?? 3;
      }
      // ★ أظهر سبب الفشل بدل «لا توجد أكواد»: الفارغ قد يكون خطأ
      //   في الخادم، و«لا يوجد» جملة تكذب في تلك الحالة.
      _note = rows.isEmpty
          ? (SupabaseService.instance.lastRpcError ??
                'لا توجد أكواد بعد — اضغط «كود جديد»')
          : null;
    });
  }

  /// ★ زر الأدمن: تشغيل / إيقاف إنشاء الأكواد التلقائية.
  ///
  /// عند الإيقاف **لا يُنشأ أي كود لأي زبون** — مشغّل القاعدة يسأل هذه
  /// الحالة قبل أي شيء. أما الأكواد التي أُنشئت قبل الإيقاف ولم تُستعمل
  /// فتبقى تعمل حتى تنتهي مدتها: قراره حرفيًا «إيقاف الإنشاء وحده».
  /// عند التشغيل تُنشأ أكواد فورًا لكل من اكتمل له ثلاثة طلبات ولم
  /// يستعمل كوده
  /// (يردّ الخادم عددها في `issued`)، فتكون استحقاقات ما قبل الإيقاف
  /// محفوظة لا ضائعة.
  Future<void> _setAuto(bool want) async {
    if (_autoSaving) return;
    final pw = await _askPassword(
      want ? 'تشغيل إنشاء الأكواد' : 'إيقاف إنشاء الأكواد',
    );
    if (pw == null || pw.isEmpty || !mounted) return;
    setState(() => _autoSaving = true);
    final res = await SupabaseService.instance.rpcCall(
      'admin_set_discount_auto',
      {'p_enabled': want, 'p_admin_password': pw},
    );
    if (!mounted) return;
    setState(() => _autoSaving = false);
    if (res is! Map || res['ok'] != true) {
      _toast(_reasonOf(res), false);
      return;
    }
    final m = Map<String, dynamic>.from(res);
    final issued = (m['issued'] as num?)?.toInt() ?? 0;
    _autoEnabled = m['enabled'] == true;
    _toast(
      want
          ? (issued == 1
                ? 'تم تشغيل الإنشاء — أُنشئ كود واحد'
                : issued > 1
                ? 'تم تشغيل الإنشاء — أُنشئت $issued أكواد'
                : 'تم تشغيل الإنشاء — لا أحد مستوفٍ ل$_autoEvery طلبات '
                      'مكتملة الآن')
          : 'تم إيقاف إنشاء الأكواد — لا يُنشأ كود لأي زبون',
      true,
    );
    // ★ القائمة تُجَلَّب من جديد: التشغيل يولّد أكوادًا الآن، فلو بقيت
    //   القائمة القديمة يظن الأدمن أن الزر لم يعمل.
    await _load();
  }

  /// ★ بطاقة الزر — أعلى قائمة الأكواد.
  ///
  /// النسبة وعدد الطلبات والمدة **مثبّتة في القاعدة** (٥٪ / ٣ طلبات / ٣
  /// أيام) كما قرّر المستخدم، فاللوحة تعرضها ولا تعدّلها: التحكم المطلوب
  /// هو التشغيل والإيقاف فقط. مسطّحة بحدود — بلا ظل ولا شريط رمادي.
  Widget _buildAutoCard() {
    final on = _autoEnabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: on == false ? AppColors.warning : AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'إنشاء الأكواد التلقائي',
                  style: GoogleFonts.cairo(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (_autoSaving)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  value: on ?? true,
                  activeThumbColor: AppColors.primary,
                  onChanged: (v) => _setAuto(v),
                ),
            ],
          ),
          Text(
            'كود خاص لكل زبون عند كل $_autoEvery طلبات مكتملة · '
            'نسبة $_autoPercent٪ · صالح $_autoDays أيام من لحظة إنشائه · '
            'يستعمل مرة واحدة، ووقت انتهائه الحقيقي يظهر على بطاقته',
            style: GoogleFonts.cairo(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            on == null
                ? 'لم تُقرأ الحالة من القاعدة — شغّل '
                      'SQL_DISCOUNT_AUTO_5PERCENT.sql'
                : on
                ? 'شغّال: يُنشأ كود لكل من أكمل $_autoEvery طلبات '
                      'مكتملة — والعدّاد يبدأ من الصفر بعد كل استعمال.'
                : 'موقوف: لا يُنشأ أي كود لأي زبون، و«خصوماتي» تُظهر '
                      'رسالة انتهاء العروض. الأكواد التي لم تُستعمل تبقى '
                      'تعمل حتى تنتهي.',
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: on == false ? AppColors.warning : AppColors.success,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  /// نافذة كلمة مرور الأدمن — ترجع-null عند الإلغاء.
  ///
  /// ★ تطلب مرة واحدة لكل فتح: إن حُفظت كلمة المرور في هذه الجلسة
  ///   تُعاد تلقائياً، فلا تُكتب مرة أخرى. ولا تُحفَظ في القرص أبداً.
  Future<String?> _askPassword(String action) async {
    // ★ محاولة أولى بكلمة المرور المحفوظة — بلا إزعاج المستخدم.
    String? resolved;
    final alreadyHandled = await AdminPasswordSession.tryUseCached((pw) async {
      resolved = pw;
      return true; // نستخدمها؛ الفشل الحقيقي يظهر عند الاستدعاء
    });
    if (alreadyHandled && resolved != null) return resolved;

    final ctrl = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          action,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'كلمة مرور الأدمن',
            labelStyle: GoogleFonts.cairo(),
            border: const OutlineInputBorder(),
          ),
          style: GoogleFonts.cairo(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text('تأكيد', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final typed = pw?.trim();
    // ★ الحفظ في الذاكرة فقط — لا القرص، تضيع بإغلاق التطبيق.
    if (typed != null && typed.isNotEmpty) {
      AdminPasswordSession.remember(typed);
    }
    return pw;
  }

  Future<void> _createDialog() async {
    final codeCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    // ★ الثقة بالأدمن: إن كانت كلمة المرور محفوظة لهذه الجلسة لا نعرض
    //   حقلها من الأصل — تُكتب مرة واحدة لكل فتح للتطبيق.
    final cachedPw = AdminPasswordSession.cached;
    final hasCachedPw = (cachedPw ?? '').isNotEmpty;
    double percent = 40;
    // ★ الافتراضي 'total' لا 'delivery': التوصيل مجاني عندنا
    //   (`CartService.deliveryFee => 0.0`)، فالخصم على التوصيل
    //   كان يُحسب من صفر ويرفضه الخادم: «لا يوجد ما يُخصم».
    String appliesTo = 'total';
    // ★ لم يعد «عدد أيام» — لحظة انتهاء حقيقية (تاريخ + ساعة) يراها
    //   الأدمن قبل الضغط على «إنشاء» وتُحفظ في القاعدة كما هي.
    DateTime endAt = _defaultExpiry();

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'كود خصم جديد',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field(
                  codeCtrl,
                  'نص الكود (مثال: SHATERA40)',
                  hint: 'حروف إنجليزية وأرقام',
                ),
                const SizedBox(height: 10),
                _field(
                  labelCtrl,
                  'وصف للزبون (اختياري)',
                  hint: 'خصم على التوصيل — أسبوع',
                ),
                const SizedBox(height: 16),
                Text(
                  'نسبة الخصم: ${percent.toStringAsFixed(0)}٪',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Slider(
                  value: percent,
                  min: 5,
                  max: 100,
                  divisions: 19,
                  activeColor: AppColors.primary,
                  label: '${percent.toStringAsFixed(0)}٪',
                  onChanged: (v) => setLocal(() => percent = v),
                ),
                const SizedBox(height: 6),
                // ★ بدل سلايدر «مدة الصلاحية بالأيام»: لحظة انتهاء
                //   حقيقية — تاريخ وساعة، هي نفسها ما تحفظه القاعدة.
                _ExpiryTile(
                  value: endAt,
                  onTap: () async {
                    final picked = await _pickExpiry(ctx, endAt);
                    if (picked != null && ctx.mounted) {
                      setLocal(() => endAt = picked);
                    }
                  },
                ),
                const SizedBox(height: 6),
                Text(
                  'الخصم يُطبَّق على',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _choice(
                        'مجموع الأصناف',
                        appliesTo == 'total',
                        () => setLocal(() => appliesTo = 'total'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _choice(
                        'رسوم التوصيل',
                        appliesTo == 'delivery',
                        () => setLocal(() => appliesTo = 'delivery'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _field(
                  phoneCtrl,
                  'رقم زبون محدّد (اختياري)',
                  hint: 'اتركه فارغاً لكل الزبائن',
                  keyboard: TextInputType.phone,
                ),
                // ★ الحقل يظهر فقط إن لم تكن الكلمة محفوظة لهذه الجلسة.
                if (!hasCachedPw) ...[
                  const SizedBox(height: 10),
                  _field(pwCtrl, 'كلمة مرور الأدمن', obscure: true),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء', style: GoogleFonts.cairo()),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('إنشاء', style: GoogleFonts.cairo()),
            ),
          ],
        ),
      ),
    );

    if (created != true || !mounted) return;
    // ★ الكلمة المحفوظة لهذه الجلسة تُستخدم مباشرة — وإلا فنأخذ ما كُتب.
    final pw = hasCachedPw ? cachedPw! : pwCtrl.text.trim();
    if (pw.isEmpty) {
      _toast('كلمة مرور الأدمن مطلوبة', false);
      return;
    }
    if (!hasCachedPw) AdminPasswordSession.remember(pw);

    // ★ وقت في الماضي يعني كوداً ميتاً لحظة إنشائه — لا نفرض رأيه،
    //   لكنه غالباً سهو في المنتقي (يوم قديم أو «ص» بدل «م»).
    if (!endAt.isAfter(DateTime.now())) {
      _toast('اختر وقت انتهاء في المستقبل', false);
      return;
    }

    final res = await SupabaseService.instance.rpcCall(
      'admin_create_discount_code',
      {
        'p_code': codeCtrl.text.trim().toUpperCase(),
        'p_percent': percent,
        'p_applies_to': appliesTo,
        // ★ السقف المؤقت (أيام كاملة) — لا يسقط الكود أبكر من اللحظة
        //   المطلوبة ولو تعذّر ضبطها في الخطوة التالية.
        'p_valid_days': _daysUpTo(endAt),
        'p_label': labelCtrl.text.trim(),
        'p_owner_phone': phoneCtrl.text.trim(),
        'p_max_uses': 0,
        'p_admin_password': pw,
      },
    );
    if (!mounted) return;

    if (res is! Map || res['ok'] != true) {
      _toast(
        res is Map
            ? '${res['error'] ?? 'تعذّر الإنشاء'}'
            : SupabaseService.instance.lastRpcError ?? 'تعذّر الاتصال',
        false,
      );
      return;
    }

    // ★ اللحظة الحقيقية الآن: بنفس المعرّف الذي رجّعه الإنشاء، بلا
    //   جولة ثانية على القائمة.
    final expiryErr = await _applyExpiry(res['id'], endAt, pw);
    if (!mounted) return;
    _toast(
      expiryErr == null
          ? 'تم إنشاء ${res['code']} — ينتهي ${_expiryLabel(endAt)}'
          : 'أُنشئ الكود ${res['code']} لكنه ينتهي بعد '
                '${_daysUpTo(endAt)} يوم: $expiryErr',
      expiryErr == null,
    );
    await _load();
  }

  /// ★ اضبط لحظة انتهاء كود على الخادم (`admin_set_discount_code_expiry`).
  ///
  /// تُستعمل مرتين: بعد الإنشاء (تحوّل السقف المؤقت بالأيام إلى اللحظة
  /// التي اختارها الأدمن بالضبط)، ومن زر «تغيير الانتهاء» على أي كود
  /// موجود — فتعديل المدة لم يعد يعني حذف الكود وإعادة صنعته.
  /// ترجع `null` عند النجاح، ونصّ السبب الحقيقية عند الفشل.
  Future<String?> _applyExpiry(Object? id, DateTime when, String pw) async {
    final nid = id is num ? id.toInt() : int.tryParse('$id');
    if (nid == null) return 'لم يصل معرّف الكود من الخادم';
    final res = await SupabaseService.instance.rpcCall(
      'admin_set_discount_code_expiry',
      {
        // ★ اللحظة بـUTC المكتوب بالميلّي: القاعدة عمودها
        //   `timestamptz`، فترجعها لنفس الثانية التي رآها الأدمن.
        'p_id': nid,
        'p_expires_at': when.toUtc().toIso8601String(),
        'p_admin_password': pw,
      },
    );
    if (res is! Map || res['ok'] != true) return _reasonOf(res);
    return null;
  }

  /// ★ زر الأدمن على كود موجود: غيّر لحظة انتهائه بوقت حقيقي.
  ///
  /// الكود الذي استعمله زبون يبقى مستعملاً مهما مدّد الأدمن انتهاءه
  /// (قيد «لمرة واحدة لكل زبون» في القاعدة)، فالتعديل يمدّد للمتبقّين
  /// ولا يعطي أحداً كوداً استهلكه.
  Future<void> _editExpiry(Map<String, dynamic> c) async {
    final when = _expiryOf(c['expires_at']) ?? _defaultExpiry();
    final picked = await _pickExpiry(context, when);
    if (picked == null || !mounted) return;
    final pw = await _askPassword('تغيير وقت الانتهاء');
    if (pw == null || pw.isEmpty || !mounted) return;
    final err = await _applyExpiry(c['id'], picked, pw);
    if (!mounted) return;
    _toast(err ?? 'ينتهي ${_expiryLabel(picked)}', err == null);
    await _load();
  }

  /// ★ سبب الفشل الحقيقي: رسالة الدالة إن ردّت، وإلا `lastRpcError`.
  ///
  /// كان الرمز يطبع «تعذّر الاتصال» متى لم ترد الدالة بخريطة — وهي
  /// جملة لا تميّز بين انتهاء المهلة و401 ودالة غير مثبّتة، فلا
  /// يستطيع الأدمن أن يعرف آخر ما جرى.
  String _reasonOf(Object? res) {
    if (res is Map) {
      final e = '${res['error'] ?? ''}'.trim();
      if (e.isNotEmpty) return e;
    }
    final rpc = '${SupabaseService.instance.lastRpcError ?? ''}'.trim();
    if (rpc.isNotEmpty) return rpc;
    return 'تعذّر تنفيذ العملية — أعد المحاولة';
  }

  Future<void> _toggle(Map<String, dynamic> c) async {
    final id = c['id'];
    final want = !(c['is_active'] == true);
    final pw = await _askPassword(want ? 'تفعيل الكود' : 'إيقاف الكود');
    if (pw == null || pw.isEmpty || !mounted) return;
    final res = await SupabaseService.instance.rpcCall(
      'admin_set_discount_code_active',
      {'p_id': id, 'p_active': want, 'p_admin_password': pw},
    );
    if (!mounted) return;
    if (res is! Map || res['ok'] != true) {
      // ★ كان يُطبع «تعذّر الاتصال» لكل سبب — وRPC يوثّق سببه في
      //   `lastRpcError` (انتهاء مهلة، 401، PGRST202…). الجملة العامة
      //   كانت تقول «اتصال» والمشكلة ليست اتصالاً أصلاً.
      _toast(_reasonOf(res), false);
      return;
    }
    _toast(want ? 'تم تفعيل الكود' : 'تم إيقاف الكود', true);
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final code = '${c['code'] ?? ''}';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف الكود $code',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'يُحذف الكود مع كل سجلات استعماله. الزبائن الذين استعملوه لن\n'
          'يستفيدوا منه مجدداً. لا يمكن التراجع.',
          style: GoogleFonts.cairo(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text('حذف', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final pw = await _askPassword('تأكيد الحذف');
    if (pw == null || pw.isEmpty || !mounted) return;
    final res = await SupabaseService.instance.rpcCall(
      'admin_delete_discount_code',
      {'p_id': c['id'], 'p_admin_password': pw},
    );
    if (!mounted) return;
    if (res is! Map || res['ok'] != true) {
      _toast(_reasonOf(res), false);
      return;
    }
    _toast('تم حذف الكود', true);
    await _load();
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: GoogleFonts.cairo(fontSize: 13),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      style: GoogleFonts.cairo(fontSize: 13),
    );
  }

  Widget _choice(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.cairo(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'أكواد الخصم',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createDialog,
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'كود جديد',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_codes.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _buildAutoCard(),
                        ),
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.18,
                        ),
                        Center(
                          child: Column(
                            children: [
                              const Icon(
                                Icons.local_offer_outlined,
                                size: 58,
                                color: AppColors.textHint,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _note ?? 'لا توجد أكواد بعد — اضغط «كود جديد»',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.cairo(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                      children: [
                        _buildAutoCard(),
                        const SizedBox(height: 10),
                        for (final c in _codes) ...[
                          _CodeRow(
                            code: c,
                            onToggle: () => _toggle(c),
                            onDelete: () => _delete(c),
                            onEditExpiry: () => _editExpiry(c),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    )),
      ),
    );
  }
}

class _CodeRow extends StatelessWidget {
  const _CodeRow({
    required this.code,
    required this.onToggle,
    required this.onDelete,
    required this.onEditExpiry,
  });

  final Map<String, dynamic> code;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  /// ★ تغيير لحظة انتهاء الكود — تاريخ وساعة حقيقيان بدل «عدد أيام».
  final VoidCallback onEditExpiry;

  double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  @override
  Widget build(BuildContext context) {
    final text = '${code['code'] ?? ''}';
    final active = code['is_active'] == true;
    final expired = code['is_expired'] == true;
    // ★ لحظة الانتهاء الحقيقية (تاريخ + ساعة) كما يحفظها الخادم.
    final ends = _expiryOf(code['expires_at']);
    final onDelivery = '${code['applies_to'] ?? 'delivery'}' == 'delivery';
    final percent = _d(code['percent']);
    final used = _d(code['used_count']);
    final max = _d(code['max_uses']);

    // حالة العرض: منتهٍ، موقوف، أم يعمل.
    final stateColor = expired
        ? AppColors.textHint
        : active
        ? AppColors.success
        : AppColors.warning;
    final stateLabel = expired
        ? 'منتهٍ'
        : active
        ? 'يعمل'
        : 'موقوف';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: expired
              ? AppColors.divider
              : stateColor.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: GoogleFonts.cairo(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    color: expired ? AppColors.textHint : AppColors.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  stateLabel,
                  style: GoogleFonts.cairo(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: stateColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'خصم ${percent.toStringAsFixed(0)}٪ على '
            '${onDelivery ? 'رسوم التوصيل' : 'مجموع الأصناف'}'
            ' • استعمله ${used.toStringAsFixed(0)}'
            '${max > 0 ? ' من ${max.toStringAsFixed(0)}' : ''}',
            style: GoogleFonts.cairo(
              fontSize: 12,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          // ★ سطر الوقت وحده: «٥ أيام» لم تعد تكفي — الأدمن يريد أن
          //   يعرف متى يسقط الكود بالضبط، وأن يغيّره متى شاء.
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 14,
                color: expired ? AppColors.textHint : AppColors.textSecondary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  ends != null
                      ? (expired
                            ? 'انتهى ${_expiryLabel(ends)}'
                            : 'ينتهي ${_expiryLabel(ends)}')
                      // قاعدة بلا `SQL_COUPON_REAL_EXPIRY.sql`: لا وقت
                      // محفوظ — نعرض المدة بالأيام كما هي، ولا نخترع
                      // تاريخاً.
                      : 'صالح ${code['valid_days'] ?? '—'} يومًا '
                            '(شغّل ملف الوقت الحقيقي)',
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    color: expired ? AppColors.textHint : AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (code['owner_phone'] != null &&
              '${code['owner_phone']}'.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'لزبون محدّد: ${code['owner_phone']}',
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: expired ? null : onToggle,
                  icon: Icon(
                    active ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 17,
                  ),
                  label: Text(
                    active ? 'إيقاف' : 'تفعيل',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // ★ تغيير لحظة الانتهاء — للأكواد المنتهية أيضاً: مدّ
              //   كودٍ انتهى طلبٌ طبيعي من الأدمن، وحذفه وإعادته
              //   خسارة لسجل استعماله.
              IconButton(
                onPressed: onEditExpiry,
                icon: const Icon(Icons.edit_calendar_rounded),
                color: AppColors.primary,
                tooltip: 'تغيير وقت الانتهاء',
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                color: AppColors.danger,
                tooltip: 'حذف',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
