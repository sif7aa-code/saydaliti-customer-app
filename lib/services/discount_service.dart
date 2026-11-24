import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/supabase_service.dart';

/// ★ نظام أكواد الخصم — جانب الزبون.
///
/// النموذج:
///   1) الأدمن يصنع كوداً: نسبة + ما يخصمه (التوصيل/المجموع) + مدة
///      بالأيام + مستهدف (كل الزبائن أو رقم واحد).
///   2) الزبون يفتح «خصوماتي» من بروفايله فيرى أكواده وينسخها.
///   3) السلة تستدعي [applyCode] فيحسب **الخادم** مبلغ الخصم.
///
/// ★ كل التحقق والمبلغ على الخادم. التطبيق يعرض فقط — فلو حُسب
///   الخصم هنا لأمكن تعديله برمجياً.
class DiscountService {
  DiscountService._();
  static final DiscountService instance = DiscountService._();

  /// الكود المطبَّق حالياً في السلة.
  String? _appliedCode;
  double _discount = 0;

  String? get appliedCode => _appliedCode;

  /// مبلغ الخصم-current (0 إن لم يُطبَّق كود).
  double get discount => _discount;

  /// نسبة الخصم المعروضة في الواجهة.
  double _percent = 0;
  double get percent => _percent;

  /// ★ آخر فشل في **تسجيل** استعمال الكود (لا في الطلب). فارغة = نجح.
  ///   تُعرض للزبون ولا تُخفى: كودٌ لم يُسجَّل استعماله يعني أن العدّاد
  ///   لن يُقفل، والصمت هنا هو ما أبقى «٣/٣» مفتوحة.
  String? lastCommitError;

  /// ★ تطبيع ردّ الدوال: قد تأتي مصفوفة أو كائناً يحمل `list`.
  ///
  /// خطأ هنا كلّفني: دوال الأكواد ترجع `jsonb_agg(...)` أي **مصفوفة**،
  /// وPostgREST يعيدها مصفوفة لا كائناً. كنت أقرأ `res['list']` فكانت
  /// `null` دائماً، والنتائج «لا توجد أكواد» في كل مرة. نتقبّل الشكلين.
  static List<Map<String, dynamic>> asRows(Object? res) {
    if (res is List) {
      return List<Map<String, dynamic>>.from(
        res.whereType<Map>().map(Map<String, dynamic>.from),
      );
    }
    if (res is Map && res['list'] is List) {
      return List<Map<String, dynamic>>.from(
        (res['list'] as List).whereType<Map>().map(Map<String, dynamic>.from),
      );
    }
    return const [];
  }

  /// ★ حالة القفل الحيّة — يراقبها البروفايل.
  ///
  /// لا يكفي أن يجلب البروفايل الحالة مرة واحدة عند فتحه: الزبون
  /// يستعمل كوداً من السلة ثم يرجع لبروفايله، فيجد «خصوماتي» ما زالت
  /// مفتوحة وهي مقفولة على الخادم. لذلك تُحدَّث هنا عند كل جلب وعند
  /// كل استعمال كود، والشاشة تبنى عليها.
  final ValueNotifier<DiscountUnlockStatus> gate =
      ValueNotifier<DiscountUnlockStatus>(
          const DiscountUnlockStatus(delivered: 0));

  /// «خصوماتي» — الأكواد المتاحة لهذا الرقم.
  Future<List<Map<String, dynamic>>> fetchMine(String phone) async {
    if (phone.isEmpty) return const [];
    try {
      final res = await SupabaseService.instance.rpcCall(
        'my_discounts',
        {'p_phone': phone},
      );
      return asRows(res);
    } catch (_) {
      return const [];
    }
  }

  /// ★ حالة قفل «خصوماتي» — كم طلباً مكتملاً ومتى يُفتح.
  ///
  /// ★ الجواب نهائي من الخادم: القفل نفسه مفروض هناك، وهذا
  ///   الاستدعاء للعرض فقط (نصّ الزر). الاعتماد على `unlocked`
  ///   في الواجهة كحاجز أمني خطأ — يُتجاوز بـPostgREST مباشرة.
  Future<DiscountUnlockStatus> fetchUnlockStatus(String phone) async {
    if (phone.isEmpty) return const DiscountUnlockStatus(delivered: 0);
    DiscountUnlockStatus st;
    try {
      final res = await SupabaseService.instance.rpcCall(
        'discount_unlock_status',
        {'p_phone': phone},
      );
      if (res is! Map) {
        st = DiscountUnlockStatus.unavailable();
      } else {
        st = DiscountUnlockStatus.fromJson(Map<String, dynamic>.from(res));
      }
    } catch (_) {
      st = DiscountUnlockStatus.unavailable();
    }
    gate.value = st;
    return st;
  }

  /// فحص الكود في السلة. **لا يسجّل الاستعمال** — التسجيل عند تأكيد
  /// الطلب فقط، وإلا فقد الزبون كوده لمجرد فتح السلة ثم إغلاقها.
  Future<DiscountApplyResult> applyCode({
    required String code,
    required String phone,
    required double subtotal,
    required double deliveryFee,
  }) async {
    final clean = code.trim();
    if (clean.isEmpty) {
      return const DiscountApplyResult(false, 'أدخل الكود');
    }
    if (phone.isEmpty) {
      return const DiscountApplyResult(false, 'سجّل الدخول أولاً');
    }
    try {
      final res = await SupabaseService.instance.rpcCall(
        'check_discount_code',
        {
          'p_code': clean,
          'p_phone': phone,
          'p_subtotal': subtotal,
          'p_delivery_fee': deliveryFee,
        },
      );
      if (res is! Map) {
        // ★ نُظهر سبب الخادم الحقيقي لا جملة عامة: «تعذّر الاتصال»
        //   كانت تختفي خلفها أخطاء الاسمية والتحقق والمبلغ.
        return DiscountApplyResult(
          false,
          SupabaseService.instance.lastRpcError ?? 'تعذّر الاتصال',
        );
      }
      final m = Map<String, dynamic>.from(res);
      if (m['ok'] != true) {
        _clear();
        return DiscountApplyResult(
          false,
          '${m['error'] ?? 'الكود غير صالح'}',
        );
      }
      _appliedCode = '${m['code'] ?? clean}'.trim().toUpperCase();
      _discount = (m['discount'] as num?)?.toDouble() ?? 0;
      _percent = (m['percent'] as num?)?.toDouble() ?? 0;
      // ★ نوع الكود من ردّ الخادم (`check_discount_code` يُرجعهما منذ
      //   `SQL_DELIVERY_FEE.sql`). أكواد الدورة نسبةٌ، وأكواد عجلة الحظ
      //   مبلغٌ ثابت — فرسالة «خُفِض ٠٪» على كودٍ يخصم ٥٠٠ ديناراً
      //   كذبةٌ في وجه الزبون، والمبلغ المحسوب نفسه صحيح.
      final fixed = (m['fixed_amount'] as num?)?.toDouble() ?? 0;
      final isFixed = '${m['discount_type'] ?? 'percent'}'.trim() == 'fixed'
          && fixed > 0;
      final onDelivery = '${m['applies_to'] ?? 'delivery'}' == 'delivery';
      return DiscountApplyResult(
        true,
        isFixed
            ? 'وفّرت ${_discount.toStringAsFixed(0)} د.ع على '
              '${onDelivery ? 'رسوم التوصيل' : 'مجموع الأصناف'}'
            : 'خُفِض ${_percent.toStringAsFixed(0)}٪ — '
              'وفّرت ${_discount.toStringAsFixed(0)}',
        code: _appliedCode,
        discount: _discount,
        percent: _percent,
        fixedAmount: isFixed ? fixed : 0,
        appliesTo: '${m['applies_to'] ?? 'delivery'}',
      );
    } catch (_) {
      return const DiscountApplyResult(false, 'تعذّر الاتصال');
    }
  }

/// تسجيل استعمال الكود — يُستدعى بعد نجاح إنشاء الطلب.
///
/// ★ الفشل هنا **لا يُفشل الطلب**: الكود ميزة ثانوية، والزبون دفع
///   ثمن بضاعته. لكنّه **لا يُبتلع** — يُحفظ في [lastCommitError]
///   وتُعاد المحاولة، لأن الصمت كان يترك العدّاد مفتوحاً على `٣/٣`.
///   ★ الخطأ الحقيقي صار مستحيلاً في القاعدة: `trg_discount_order_record`
///     يسجّل الاستعمال مع الطلب نفسه في نفس اللحظة، فتصبح هذه الدعوة
///     تأكيداً لا شرطاً.
///
/// ★ «الكود لمرة واحدة لكل زبون» مفروض في القاعدة على مرحلتين:
///   `check_discount_code` يرفض الكود المستعمل، و
///   `discount_redemptions` فيه `unique (code_id, phone)`.
///
/// ★★ وهنا يُقفل «خصوماتي»: `commit_discount_code` يسجّل عدد الطلبات
///   المكتملة لحظة الاستعمال (`delivered_at_use`) فهو **أساس الدورة
///   الجديدة** — تُغلق النافذة ويُرجَع العدّاد إلى `٠/٣` ولا يعود يفتح
///   حتى تكتمل ثلاثة طلبات بعد ذلك الأساس.
///   لذلك نجلب الحالة من جديد بعد التسجيل: يبقى البروفايل صادقاً
///   فوراً لا عند إعادة فتح التطبيق.
Future<void> commit({
    required String orderId,
    required String phone,
  }) async {
    final code = _appliedCode;
    if (code == null || code.isEmpty || phone.isEmpty) return;
    // ★ معرّف فارغ لا يُمرَّر: العمود `uuid`، والسلسلة الفارغة ترمي
    //   خطأ تحويل فيتوقف التسجيل كله — أي كودٌ يُخصم ولا يُقفل.
    final oid = orderId.trim();
    final body = <String, dynamic>{
      'p_code': code,
      'p_phone': phone,
      'p_order_id': oid.isEmpty ? null : oid,
    };
    // ★ محاولة ثانية: أول نداء بعد إنشاء الطلب يقع أحياناً على شبكة
    //   باردة. كان الخطأ يبتلع بصمت، فلا يُسجَّل الاستعمال — وهذا أحد
    //   أبواب الثغرة. (الباب الأصلي أغلقته القاعدة بتسجيل الاستعمال مع
    //   الطلب نفسه في `trg_discount_order_record`؛ هذا يبقى تأكيداً.)
    Object? res;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        res = await SupabaseService.instance.rpcCall(
          'commit_discount_code',
          body,
        );
        if (res is Map) break;
      } catch (_) {
        res = null;
      }
    }
    lastCommitError = res is Map
        ? null
        : (SupabaseService.instance.lastRpcError ?? 'تعذّر تسجيل الكود');
    _clear();
    // ★ الكود استُعمل ⇒ النافذة أُغلقت على الخادم. نُحدّث الحالة
    //   فوراً فيُصبح البروفايل صادقاً بلا إعادة تشغيل التطبيق.
    await fetchUnlockStatus(phone);
  }

  /// تحرير الكود من السلة.
  void clear() => _clear();

  void _clear() {
    _appliedCode = null;
    _discount = 0;
    _percent = 0;
  }

  /// نسخ كود إلى الحافظة مع رسالة تأكيد.
  static Future<bool> copyCode(String code) async {
    final c = code.trim();
    if (c.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: c));
    return true;
  }
}

/// نتيجة محاولة تطبيق كود.
class DiscountApplyResult {
  const DiscountApplyResult(
    this.ok,
    this.message, {
    this.code,
    this.discount = 0,
    this.percent = 0,
    this.fixedAmount = 0,
    this.appliesTo = 'delivery',
  });

  final bool ok;
  final String message;
  final String? code;
  final double discount;
  final double percent;

  /// ★ المبلغ الثابت بالدينار (جوائز العجلة) — صفر في أكواد النسبة.
  final double fixedAmount;

  /// 'delivery' أو 'total'.
  final String appliesTo;
}

/// ★★ دورة الخصم كما ينطقها التطبيق: **٣ طلبات مكتملة**.
///
/// ★ لماذا في الكود وقد كانت في القاعدة؟ لأن الجملة التي يقرأها الزبون
///   تأتي من القاعدة حرفياً (`message` و`progress` من `discount_gate`)،
///   وبقي أثرٌ واحد يُكذّبها: `discount_redemptions.delivered_at_use`
///   يحمل رصيداً من زمن الدورة الطويلة، فيحسب «المتبقّي» عدداً أكبر من
///   طول الدورة نفسها («تُفتح بعد ٩ طلبات»). هذا ليس قراراً بل نصّاً،
///   فهو يُصحَّح في موضعين:
///     · القاعدة: `SQL_DISCOUNT_BASE_CLAMP.sql` — الأساس لا يتجاوز
///       رصيد الزبون، فلا يُكتب ٩ من أصل.
///     · هنا: أي عدد يطلبه نصّ قادم من القاعدة يُردّ إلى طول الدورة،
///       فلا تصل كلمة «١٠ طلبات» — ولا أي عدد فوق الدورة — إلى عين
///       الزبون من أي نسخة قديمة مركّبة على هاتفه.
///
/// ★★ **القرار لا يُمسّ**: `unlocked` يبقى قرار الخادم وحده. هذا الطبقة
///   تعرض فقط، فلا تفتح خصماً ولا تغلقه — ومن هنا لا يُعطى أحد كوداً
///   لم يكمله، ولا يُطلب من أحد أكثر من ٣.
///
/// ★ إن قررت يوماً أن تجعل الدورة خمسة: غيّر `orders` هنا **مع**
///   `discount_required_orders()` في القاعدة — لا هنا وحدها.
class DiscountCycle {
  DiscountCycle._();

  /// عدد الطلبات المكتملة التي تُفتح عندها الدورة.
  static const int orders = 3;

  /// رقم (لاتيني أو هندي-عربي) متبوعاً بكلمة طلب/طلبات/طلبين.
  static final RegExp _digitsThenOrder = RegExp(
    r'([0-9\u0660-\u0669]+)\s*(طلبين|طلبات|طلب)',
  );

  /// عدد مكتوب بالحروف وهو فوق الدورة: «عشرة طلبات»، «تسعة طلبات»…
  static final RegExp _wordsThenOrder = RegExp(
    r'(عشرون|عشرة|عشر|تسعة|ثمانية|سبعة|ستة|خمسة|أربعة|اربعة)\s*'
    r'(طلبين|طلبات|طلب)',
  );

  /// عدّاد الدورة: «٢/١٠» أو «2/10».
  static final RegExp _counter = RegExp(
    r'([0-9\u0660-\u0669]+)\s*/\s*([0-9\u0660-\u0669]+)',
  );

  static final RegExp _arabicIndic = RegExp(r'[\u0660-\u0669]');

  /// هل كتب النصّ أرقامه بالهندية-العربية؟ يُردّ بنفس رسمه.
  static bool _isHindi(String s) => _arabicIndic.hasMatch(s);

  /// «12» → «١٢» عند الحاجة.
  static String _asHindi(int n) => n
      .toString()
      .split('')
      .map((d) => String.fromCharCode(0x0660 + int.parse(d)))
      .join();

  /// أي رقم → بصيغة لاتينية للتحليل.
  static int _num(String s) {
    final latin = s.split('').map((ch) {
      final c = ch.codeUnitAt(0);
      return (c >= 0x0660 && c <= 0x0669) ? (c - 0x0660).toString() : ch;
    }).join();
    return int.tryParse(latin) ?? 0;
  }

  /// ★ عدد لا يتجاوز طول الدورة أبداً.
  static int clamp(int n) => n < 0 ? 0 : (n > orders ? orders : n);

  /// ★ نصّ الدورة: كل «N طلبات» فوق ٣ يصير «٣ طلبات» بأسلوب النصّ نفسه.
  static String text(String input) {
    var out = input;
    out = out.replaceAllMapped(_digitsThenOrder, (m) {
      final n = _num(m.group(1)!);
      if (n <= orders) return m.group(0)!;
      final shown = _isHindi(m.group(1)!) ? _asHindi(orders) : '$orders';
      return '$shown ${m.group(2)}';
    });
    out = out.replaceAllMapped(_wordsThenOrder, (m) {
      // «ثلاثة طلبات» هي الدورة نفسها — تُترك كما كتبتها.
      if (m.group(1) == 'ثلاثة') return m.group(0)!;
      return '٣ ${m.group(2)}';
    });
    return out;
  }

  /// ★ عدّاد الدورة: البسط مقفول عند ٣ والمقام طول الدورة دائماً.
  static String counter(String input) {
    final m = _counter.firstMatch(input);
    if (m == null) return input;
    final done = clamp(_num(m.group(1)!));
    if (!_isHindi(input)) return '$done/$orders';
    return '${_asHindi(done)}/${_asHindi(orders)}';
  }
}

/// ★ حالة «خصوماتي» — يقرؤها البروفايل والسلة لتفهيم الزبون.
///
/// ★★ القاعدة الحيّة (`SQL_DISCOUNT_LOCK_HARDENING.sql` — دورة ٣):
///   تُفتح الأكواد عند **٣ طلبات حقيقية مكتملة** (`delivered`) **منذ آخر
///   كود استعمله**، وما إن يستعمل كوداً حتى **يبدأ العدّ من الصفر**:
///   `٠/٣` مقفول، ثم `١/٣` و`٢/٣` مع كل طلب يكتمل، و**`٣/٣`** تنفتح
///   وتُنشأ له أكواد. الأساس تُحصيه القاعدة من سجلّ الاستعمال نفسه —
///   لا من رقم يكتبه التطبيق.
///   ★ لذلك `delivered >= required` **لا تعني فتحاً أبداً** (كانت هي
///     الثغرة: عدد مطلق من أول التاريخ ⇒ `٣/٣` عند كل دخول)، والقرار
///     كله يجيء من الخادم في `unlocked`. العدّاد المعروض (`progress`)
///     يُؤخذ من الخادم متى أرسله، والحساب المحلي هنا للعرض فقط ولا
///     يفتح باباً.
///   ★ الاستثناء الوحيد قرارٌ في القاعدة لا في الهاتف: كود يدوي يصنعه
///     الأدمن لزبيه (`auto_generated = false`) يُعرض ويُقبل مهما كانت
///     حالته — فهو هبة الأدمن لا جائزة الدورة.
class DiscountUnlockStatus {
  const DiscountUnlockStatus({
    required this.delivered,
    this.required = 3,
    this.remaining = 0,
    this.cycleDone,
    this.used = false,
    this.message = '',
    this.known = true,
    this.serverUnlocked,
    this.serverProgress = '',
    // ★ `null` = الخادم لم يرسل الحقل بعد (قاعدة قبل
    //   `SQL_DISCOUNT_AUTO_5PERCENT.sql`) ⇒ نتصرّف كأن العروض شغّالة،
    //   فلا نكذب على زبون برسالة «انتهت» بلا سبب.
    this.autoEnabled,
    this.endMessage = '',
  });

  /// تعذّر قراءة الحالة ⇒ نعرض كأنها مقفلة بدل فتح زر بلا أساس.
  const DiscountUnlockStatus.unavailable()
      : delivered = 0,
        required = 3,
        remaining = 0,
        cycleDone = null,
        used = false,
        message = '',
        known = false,
        serverUnlocked = null,
        serverProgress = '',
        autoEnabled = null,
        endMessage = '';

  factory DiscountUnlockStatus.fromJson(Map<String, dynamic> m) {
    int n(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
    final delivered = n(m['delivered']);
    // ★ طول الدورة المعروض = ٣ دائماً (`DiscountCycle`)، مهما حمل نصّ
    //   القاعدة من بقايا دورة أطول. القرار لم يُمسّ: `unlocked` ما زال
    //   ما يقوله الخادم حرفياً.
    final required = DiscountCycle.orders;
    return DiscountUnlockStatus(
      delivered: delivered,
      required: required,
      // ★ مقفول عند طول الدورة: «٩ طلبات متبقّية» من بقايا نظام قديم
      //   لا يصل إلى الزبون أبداً.
      remaining: DiscountCycle.clamp(n(m['remaining'])),
      // ★ رقم الخادم إن أرسله: «كم طلباً اكتمل **منذ آخر كود**».
      cycleDone: m['cycle_done'] is num
          ? DiscountCycle.clamp((m['cycle_done'] as num).toInt())
          : (int.tryParse('${m['cycle_done']}')),
      used: m['used'] == true,
      message: DiscountCycle.text('${m['message'] ?? ''}'.trim()),
      // ★ `null` إن لم يرسل الخادم الحقل (قاعدة قديمة) — عندها
      //   فقط نحسب محلياً.
      serverUnlocked: m['unlocked'] is bool ? m['unlocked'] as bool : null,
      // ★ عدّاد جاهز من الخادم (`progress`) — عرضه أولى من حسابنا.
      serverProgress: DiscountCycle.counter('${m['progress'] ?? ''}'.trim()),
      // ★ حقول «الإنشاء التلقائي» — يرسلها `discount_gate` بعد
      //   `SQL_DISCOUNT_AUTO_5PERCENT.sql`.
      autoEnabled: m['auto_enabled'] is bool ? m['auto_enabled'] as bool : null,
      endMessage: DiscountCycle.text('${m['end_message'] ?? ''}'.trim()),
      known: true,
    );
  }

  final int delivered;
  final int required;

  /// كم طلباً مكتملاً ينقص حتى تُفتح الدورة القادمة (من الخادم).
  final int remaining;

  /// ★ كم اكتمل من الدورة الحالية — أي منذ آخر كود استُعمل (`null` لو
  ///   لم يرسله الخادم، فتُحسب محلياً من `remaining`).
  final int? cycleDone;

  /// هل استعمل كوداً في هذه الدورة؟ (هو سبب الإغلاق هذه المرة)
  final bool used;

  /// نصّ الخادم الجاهز — لا ينفصل شرح الزر عن شرط القاعدة.
  final String message;

  /// هل جاء الردّ من الخادم أصلاً؟
  final bool known;

  /// قرار الخادم، أو `null` لو لم يُرسل.
  final bool? serverUnlocked;

  /// نص العدّاد كما أحضره الخادم (`progress`) — فارغ إن لم يرسله.
  final String serverProgress;

  /// ★ قرار الأدمن: هل إنشاء الأكواد التلقائية شغّال؟ `null` = الخادم
  ///   لا يعرف بعد (قاعدة قديمة) ⇒ يُعامل كـ«شغّال».
  final bool? autoEnabled;

  /// نص رسالة «انتهت العروض» كما كتبه الأدمن في القاعدة — الشاشة تعرضه
  /// حرفياً فلا ينفصل ما يقرره الخادم عمّا يقرؤه الزبون.
  final String endMessage;

  /// العروض موقوفة فعلاً (لا مجرد غياب للحقل).
  bool get autoStopped => autoEnabled == false;

  /// النص الذي يُعرض عند الإيقاف: نص القاعدة أولاً، وهذا الاحتياط
  /// مطابق لحرفيّ رسالة المستخدم في `SQL_DISCOUNT_AUTO_5PERCENT.sql`.
  String get stoppedMessage => endMessage.isNotEmpty
      ? DiscountCycle.text(endMessage)
      : 'انتهت عروض كودات الخصم. انتظر قريبًا — ننشر الأكواد على صفحتنا '
          'في إنستغرام. شكرًا لتجربتكم تطبيقنا.';

  /// ★ **قرار الخادم وحده — لا فتح محلياً إطلاقاً.**
  ///
  /// كان الاحتياط القديم `delivered >= required`، و`delivered` هو العدد
  /// **من أول التاريخ**: أي زبون اكتمل له ثلاثة طلبات مرة واحدة في عمره
  /// يراه التطبيق مفتوحاً `٣/٣` عند كل تسجيل دخول — وهو الباب الذي
  /// شكا منه الأدمن. القرار الآن لا يُتَّخذ في الهاتف أبداً:
  ///   · الخادم قال `unlocked: true` ⇒ مفتوح.
  ///   · قال false، أو لم يرسل الحقل، أو تعذّر الاتصال ⇒ **مقفول**.
  /// الفشل مغلق عمداً: رسالة «تعذّر التحقق» أصدق من خصم لا يستحقه
  /// الزبون ثم يُسقطه الطلب عند الدفع.
  bool get unlocked => known && serverUnlocked == true;

  /// كم ينقص للفتح — رقم الخادم أولاً، ثم الحساب المحلي احتياطاً.
  /// ★ لا يتجاوز طول الدورة (`DiscountCycle.orders`) أبداً: ما زاد عليه
  ///   فهو بقية أساس قديم، وطلبُ أكثر من ٣ بعد دورة من ٣ كذبٌ على الزبون.
  int get left {
    if (unlocked) return 0;
    if (remaining > 0) return DiscountCycle.clamp(remaining);
    final local = DiscountCycle.orders - (cycleDone ?? 0);
    return DiscountCycle.clamp(local);
  }

  /// ★ كم مضى من الدورة: رقم الخادم، وإلا ما بقي مطروحاً من المطلوب.
  int get done {
    if (unlocked) return DiscountCycle.orders;
    final d = cycleDone ?? (DiscountCycle.orders - left);
    return DiscountCycle.clamp(d);
  }

  /// عدّاد الزر: **`٠/٣` لحظة أخذ الكود … `٣/٣` لحظة الفتح**.
  /// نصّ الخادم (`progress`) يُعرض كما هو متى وصل — فالحساب هنا
  /// احتياط للقاعدة القديمة فقط.
  String get progress {
    if (serverProgress.isNotEmpty) return DiscountCycle.counter(serverProgress);
    if (!known) return '';
    return '$done/${DiscountCycle.orders}';
  }

  /// نصّ الزر: سبب الإغلاق أو دعوة للفتح.
  String get label {
    if (!known) return 'تعذّر التحقق — أعد فتح البروفايل';
    if (unlocked) return 'أكواد الخصم المتاحة لك — اضغط لنسخها';
    // ★ الخادم يعرف السبب الحقيقي (لم يكمل بعد / استعمل كوده)،
    //   فنأخذ نصّه متى وصل — بعد ردّ أي عددٍ فيه إلى طول الدورة.
    if (message.isNotEmpty) return DiscountCycle.text(message);
    final tail = left == 1 ? 'طلب واحد' : '$left طلبات';
    return used
        ? 'استعملت كوداً — يبدأ العدّ من جديد: تُفتح بعد $tail مكتملة'
        : 'تُفتح بعد $tail مكتملة بنجاح';
  }
}
