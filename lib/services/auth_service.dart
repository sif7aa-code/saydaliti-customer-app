import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_cache.dart';
import 'doctor_service.dart';
import 'notification_dedup.dart';
import 'notification_center.dart';
import 'notification_sound.dart';
import 'presence_service.dart';
import 'push_service.dart';
import 'supabase_service.dart';
import 'admin_password_session.dart';

/// يحفظ بيانات تسجيل الدخول محلياً حتى لا يُطلب من المستخدم
/// تسجيل الدخول مرة أخرى في كل مرة يفتح فيها التطبيق أو السلة.
///
/// كما يراقب حالة الحساب من السيرفر كل 20 ثانية أثناء الجلسة،
/// فيُطبَّق فوراً أي تغيير من الأدمن: تعيين مندوب، صاحب صيدلية،
/// تفعيل/تعطيل الحساب، أو حذفه نهائياً — دون إعادة تسجيل دخول.
class AuthService extends ChangeNotifier {
  AuthService._();

  static final AuthService instance = AuthService._();

  /// ★ مفتاح «هل هناك حساب داخل التطبيق» على القرص. عام لأنه يُقرأ
  ///   من **عزل الخلفية** (`fcm_background_handler`) الذي لا يرى هذه
  ///   النسخة من `AuthService` — isolate جديد يبدأ من الصفر.
  static const String loggedInPrefKey = 'auth_logged_in';

  static const _kLoggedIn = loggedInPrefKey;

  /// ★ مفتاح حفظ توكن الجلسة الموقّع.
  ///
  ///   التوكن ليس سرّاً: لا يمنح حق الكتابة، والتحقق من توقيعه يتم في
  ///   القاعدة، وصلاحيته ٣٠ يوماً. بدون حفظه كان أي إغلاق للتطبيق
  ///   يعني خروجاً قسرياً للمندوب وصاحب الصيدلية.
  static const _kSessionToken = 'auth_session_token';
  static const _kName = 'auth_name';
  static const _kPhone = 'auth_phone';
  static const _kAvatar = 'auth_avatar';
  static const _kIsAdmin = 'auth_is_admin';
  static const _kIsDriver = 'auth_is_driver';
  static const _kIsShopOwner = 'auth_is_shop_owner';
  static const _kIsDoctor = 'auth_is_doctor';
  static const _kIsSecretary = 'auth_is_secretary';
  static const _kShopId = 'auth_shop_id';
  static const _kShopName = 'auth_shop_name';

  // ★ كانت هنا ثلاثة ثوابت: adminPhone وadminPassword وdriverPhone
  //   وdriverPassword. كانت **أيّها** تعني أن من يفكّ الـAPK بـjadx
  //   (أقل من دقيقة) يحصل على حساب أدمن كامل — باب خلفي حقيقي.
  //   حُذفت كلها: التحقق يتم في القاعدة على bcrypt عبر verify_login،
  //   والدور يُقرأ من الخادم. لا سرّ في الكود.
  //   `driverPassword` لم يكن مستخدماً أصلاً.

  /// فترة مراقبة الحساب أثناء الجلسة بحيث تطبق تغييرات الأدمن فوراً.
  ///
  /// ★ 2026-11-19: خُفّضت من ٢٠ إلى ١٠ ثوانٍ بطلب الأدمن — تغيير
  ///   الحالة أو الاسم من اللوحة يجب أن يظهر في «حسابي» قريباً من
  ///   الفوري. النداء نفسه دالة واحدة خفيفة (`app_read_own_user`)،
  ///   والقراءات الأثقل (الصيدلية/العيادة) تحتفظ بمهَلها الخاصة.
  /// ★ 2026-11-25: «تغيير اسم الحساب من اللوحة لم يتغيّر فوراً» —
  ///   صار المسار الأساسي حدثَ بثّ `profile` (أقل من ثانية، انظر
  ///   `notification_center.dart`)، وهذه الدورة **احتياط** حين ينقطع
  ///   البثّ أو لم يُشغَّل مشغّل القاعدة بعد ⇒ خُفّضت إلى ٣ ثوانٍ.
  ///   لا تعمل إلا والتطبيق أمام المستخدم (`pauseRoleWatch` في الخلفية).
  static const Duration roleWatchInterval = Duration(seconds: 3);

  bool _isLoggedIn = false;
  String? _name;
  String? _phone;
  String? _avatarUrl;
  bool _isAdmin = false;
  bool _isDriver = false;
  bool _isShopOwner = false;
  // ★ دور العيادة يأتي من `doctors.phone` / `doctors.secretary_phone`
  //   عبر `my_doctor_roles` — يُفحص مرة كل دقيقة، لا في كل دورة ٢٠
  //   ثانية، لأن كل المستخدمين يمرّون على دورة المراقبة.
  bool _isDoctor = false;
  bool _isSecretary = false;
  String? _clinicLookupPhone;
  DateTime _clinicLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _clinicLookupTtl = Duration(seconds: 60);
  /// ★ جيل دور العيادة: قراءة بدأت **قبل** إبطال الكاش من إشارة
  ///   `profile` قد تعود بالدور القديم؛ بلا هذا الحارس تُخزَّن
  ///   دقيقة كاملة فيبدو التغيير متأخراً.
  int _clinicGeneration = 0;
  // ★ لقطة الأدوار السابقة — تُقارن بالدورية لكشف تبديل الدور من
  //   الأدمن أثناء تشغيل التطبيق (بلا إعادة دخول).
  bool _prevIsDriver = false;
  bool _prevIsAdmin = false;
  bool _prevIsShopOwner = false;
  bool _prevIsDoctor = false;
  bool _prevIsSecretary = false;
  String? _shopId;
  String? _shopName;
  bool _accountRemoved = false;
  Timer? _roleWatchTimer;
  bool _refreshing = false;

  /// ★ كاش بحث صيدلية صاحب الصيدلية.
  ///
  ///   كان `refreshFromServer` يطلب `fetchShopByOwnerPhone` مع **كل** دورة
  ///   مراقبة (كل ٢٠ ثانية) رغم أن ارتباط الصيدلية بالمالك لا يتغيّر إلا
  ///   نادراً. الآن يُعاد البحث مرة كل خمس دقائق، أو فوراً إن كان
  ///   `_shopId` مفقوداً (أول دخول، أو أُنشئ الصيدلية بعد الحساب).
  ///   لا يمسّ هذا أي بيانات — مجرد طلب قراءة لم نعد نكرّره.
  String? _shopLookupPhone;
  DateTime _shopLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _shopLookupTtl = Duration(minutes: 5);

  /// التوكن الموقّع للجلسة الحالية — يُعاد حقنه قبل كل قراءة دورية.
  String? _sessionToken;

  /// هل المستخدم مسجّل دخوله (بياناته محفوظة).
  bool get isLoggedIn => _isLoggedIn;

  String? get name => _name;

  String? get phone => _phone;

  String? get avatarUrl => _avatarUrl;

  bool get isAdmin => _isAdmin;

  /// هل الحساب مندوب توصيل يقبل الطلبات.
  bool get isDriver => _isDriver;

  /// هل الحساب صاحب صيدلية يرى صيدليته وطلباته وأرباحه.
  bool get isShopOwner => _isShopOwner;

  /// هل الحساب طبيب في العيادة (`doctors.phone`).
  bool get isDoctor => _isDoctor;

  /// هل الحساب سكرتير عيادة (`doctors.secretary_phone`).
  bool get isSecretary => _isSecretary;

  /// ★ هل يرى الحساب واجهة العيادة المختصرة؟
  ///
  /// الأدمن يُستثنى (لوحته شغل لا عمل)، وصاحب الصيدلية له واجهته.
  bool get isClinicAccount =>
      (_isDoctor || _isSecretary) && !_isAdmin && !_isShopOwner;

  /// ★★ هل لهذا الحساب محفظة تُعرض في «حسابي»؟
  ///
  /// طلب الأدمن 2026-11-19: المحفظة للأدمن وصاحب الصيدلية والطبيب
  /// (وسكرتير العيادة، فالمحفظة محفظة العيادة نفسها) — **والزبون لا
  /// محفظة له إطلاقاً**. تُقرأ من `AuthService` لا من حالة محفوظة عند
  /// بناء الشاشة: الشاشات داخلة في `IndexedStack` ولا تُبنى من تلقاء
  /// نفسها عند تغيير الدور، فحسابٌ جرَّده الأدمن من صيدليته كان يبقى
  /// يرى بطاقة الرصيد حتى إعادة التشغيل.
  bool get canSeeWallet => _isAdmin || _isShopOwner || _isDoctor || _isSecretary;

  /// معرف صيدلية صاحب الصيدلية (إن وُجد).
  String? get shopId => _shopId;

  /// اسم صيدلية صاحب الصيدلية.
  String? get shopName => _shopName;

  /// صفة الحساب كما يعرضها للمستخدم في صفحة حسابي.
  String get roleLabel {
    if (_isAdmin) return 'مدير النظام';
    if (_isShopOwner) return 'صاحب صيدلية';
    if (_isDoctor) return 'طبيب';
    if (_isSecretary) return 'سكرتير عيادة';
    if (_isDriver) return 'مندوب توصيل';
    return 'زبون';
  }

  /// أيقونة الصفة.
  String get roleIcon {
    if (_isAdmin) return '🛡️';
    if (_isShopOwner) return '🏪';
    if (_isDoctor) return '🩺';
    if (_isSecretary) return '📋';
    if (_isDriver) return '🛵';
    return '🧑';
  }

  /// يحدّث صورة الحساب محلياً بعد رفع صورة جديدة.
  Future<void> updateAvatar(String url) async {
    _avatarUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAvatar, url);
    notifyListeners();
  }

  /// حُذف الحساب أو عُطّل من الأدمن: يجب توجيه المستخدم لشاشة تسجيل الدخول.
  bool get accountRemoved => _accountRemoved;

  /// يُحمَّل في بداية تشغيل التطبيق من الذاكرة المحلية.
  ///
  /// ★ بعد إخراج التوكن من التخزين المحل: عند فتح التطبيق لا يوجد
  ///   session ⇒ الطلبات بلا `x-app-token` ⇒ القاعدة تعاملها كزائر.
  ///   `refreshFromServer` يفشل 403 فيمسح الجلسة ويُخرج المستخدم لشاشة
  ///   الدخول، وهو أفضل من تركه في حالة "مسجّل بلا صلاحيات" غامضة.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isLoggedIn = prefs.getBool(_kLoggedIn) ?? false;
    _name = prefs.getString(_kName);
    _phone = prefs.getString(_kPhone);
    _avatarUrl = prefs.getString(_kAvatar);
    _isAdmin = prefs.getBool(_kIsAdmin) ?? false;
    _isDriver = prefs.getBool(_kIsDriver) ?? false;
    _isShopOwner = prefs.getBool(_kIsShopOwner) ?? false;
    _isDoctor = prefs.getBool(_kIsDoctor) ?? false;
    _isSecretary = prefs.getBool(_kIsSecretary) ?? false;
    _shopId = prefs.getString(_kShopId);
    _shopName = prefs.getString(_kShopName);

    // ★★★ استعادة جلسة بعد إعادة تشغيل التطبيق
    //
    // ★ ما كان يحدث: `setSessionToken(null)` في كل إقلاع. التوكن كان
    //   قد أُخرج من التخزين عمداً (قرار أمني سابق)، فلا يبقى بعد
    //   إغلاق التطبيق ⇒ الطلبات بلا `x-app-token` ⇒ القاعدة تعاملها
    //   كزائر ⇒ `notFound` ⇒ خروج قسري.
    //   وهكذا كان المندوب وصاحب الصيدلية يُخرَجان عند كل إغلاق.
    //
    //   ★ الحل: نحفظ التوكن الموقّع ونستعيده. هو **ليس** كلمة سر:
    //   لا يمنح حق الكتابة، ويُتحقق من توقيعه، وصلاحيته ٣٠ يوماً،
    //   وقابل للإبطال بإعادة ضبط الدخول أو حذف الحساب.
    //   كلمتا السر وكلمة التحقق لا تُحفَظان إطلاقاً.
    _sessionToken = prefs.getString(_kSessionToken);
    SupabaseService.instance.setSessionToken(_sessionToken);
    notifyListeners();
    // تحديث الدور من السيرفر فوراً: إذا غيّر الأدمن الحساب إلى مندوب
    // يظهر التطبيق للمندوب مباشرة عند فتحه (بلا إعادة تسجيل دخول).
    // ★★ تحديث الدور صار **بلا انتظار**. كان `await refreshFromServer()`
    //   هنا، وهو استدعاء شبكة بمهلة ١٢ ثانية — أي أن `runApp` في main
    //   كان يتأخّر رحلة ذهاب وإياب واحدة أو اثنتين قبل أول إطار،
    //   فيرى المستخدم شاشة فارغة على بيانات الجوال.
    //   الأدوار تُقرأ من SharedPreferences أعلاه، فيُعرض التطبيق فوراً
    //   والتحديث يصحّحها بعد وصوله.
    if (_isLoggedIn) {
      unawaited(refreshThenWatch());
    }
  }

  /// تحديث الدور ثم بدء المرورية — بعد أول إطار لا قبله.
  Future<void> refreshThenWatch() async {
    await refreshFromServer();
    // لا جلسة ⇒ لا مراقبة دورية: كل نداءاتها سترتدّ 403 بلا فائدة.
    if (_isLoggedIn && SupabaseService.instance.hasSession) _startRoleWatch();
    // ★★ ملاحظة: `refreshFromServer` لا يُخرج عند فشل الشبكة ولا عند
    //   انتهاء التوكن — يتطلّب ثلاث غيابات متتالية. لو انتهت صلاحية
    //   التوكن فقط، يبقى المستخدم داخل التطبيق ويعود للعمل عند أول
    //   تسجيل دخول. هذا مقصود: الخروج عند كل فتح كان العطل.
  }

  /// يبدأ مراقبة دور/حالة الحساب فترة الجلسة (مرة كل 10 ثوانٍ).
  void _startRoleWatch() {
    _stopRoleWatch();
    _roleWatchTimer = Timer.periodic(roleWatchInterval, (_) {
      refreshFromServer();
    });
  }

  void _stopRoleWatch() {
    _roleWatchTimer?.cancel();
    _roleWatchTimer = null;
  }

  /// ★ يوقف مراقبة الدور حين يخرج التطبيق للخلفية.
  ///
  ///   كان المؤقّت يستمر كل ٢٠ ثانية والتطبيق مطويّ: `app_read_own_user`
  ///   (ولصاحب الصيدلية طلب صيدلية إضافي) بلا أن يرى أحد نتيجته. عند العودة
  ///   نستدعي [refreshFromServer] فوراً (من `app.dart`) ثم نستأنف المراقبة،
  ///   فتظهر أي تغييرات من الأدمن مباشرة — لا تأخير.
  void pauseRoleWatch() => _stopRoleWatch();

  /// يستأنف المراقبة عند العودة للمقدمة — إن كانت هناك جلسة صالحة فقط.
  void resumeRoleWatch() {
    if (_isLoggedIn && SupabaseService.instance.hasSession) _startRoleWatch();
  }

  /// ★★ نافذة أمان بعد الدخول: لا يُخرِج التحديثُ المستخدمَ فوراً.
  ///
  /// ★ ما كان يحدث: `login()` يستدعي `refreshFromServer()` بلا
  ///   انتظار (وهو الصحيح للسرعة)، لكن ذلك التحديث صار **ينافس**
  ///   بقية مسار الدخول. وأي `notFound` عابر — استعلام يمرّ قبل أن
  ///   يكتمل، أو خطأ شبكة يترجمه الفحص إلى notFound — كان يُنهي
  ///   الجلسة بعد ثوانٍ من نجاحها، فيرى المستخدم «سجّل خروجاً
  ///   تلقائياً» بلا سبب.
  ///
  /// ★ بعد الدخول مباشرةً، الدليل الوحيد على أن الحساب محذوف هو
  ///   استمرار `notFound` عبر دورة المراقبة (٢٠ ثانية) التالية —
  ///   لا نتيجة واحدة. فالمهلة لا تُضعف الحماية، تمنع فقط verdict
  ///   واحداً متسرّعاً.

  /// ★★ عدد الفحوصات المتتالية التي رجعت `notFound`.
  ///
  /// القاعدة التي طلبها المستخدم، حرفياً:
  /// **لا خروج إلا إذا كان الحساب محذوفاً فعلاً.**
  ///
  /// سابقاً كان يكفي نفي واحد ⇒ `notFound` ⇒ خروج.Indirectوأن `notFound`
  /// نفسه ليس دليل حذف: قد يكون استعلاماً لم يُكمل، أو شبكة انقطعت،
  /// أو — وهو ما حدث فعلاً — جدول خلف RLS يُرجع `[]` لأي استعلام.
  ///
  /// الآن: نحتاج **سSeries متتالية** من `notFound`. أي نجاح واحد
  /// (أو خطأ شبكة) يُصفّر العدّاد ولا يخرج أحداً.
  int _missingStreak = 0;

  /// يجلب المستخدم من قاعدة البيانات ويحدّث دوره (عميل/مندوب/أدمن/صاحب صيدلية).
  /// ★ إشارة فورية من مركز الإشعارات حين يعيّن الطبيب سكرتيراً أو يغيّره
  ///   أو يحذفه (إشعار type='role'). نُلغي كاش الدقيقة ونقرأ الدور الآن،
  ///   فيتحول الجهاز لواجهة العيادة (أو يعود للواجهة العادية) فوراً
  ///   بدل انتظار دورة الفحص.
  void refreshClinicRoleNow() {
    if (!_isLoggedIn) return;
    _clinicGeneration++;
    _clinicLookupPhone = null;
    _clinicLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(refreshFromServer());
  }

  /// ★★ إشارة القاعدة أن هذا الحساب تغيّر (اسم/صورة/دور/تعطيل).
  ///
  ///   تأتي من حدث البثّ `profile` الذي يكتبه مشغّل
  ///   `SQL_PROFILE_SYNC_SIGNAL.sql` لحظة التغيير.
  ///
  ///   · قراءة صريحة واحدة (`app_read_own_user` بلا تحويل) تحسم أمر
  ///     التعطيل: `is_active = false` مؤكّد ⇒ خروج فوري كما وعدت
  ///     رسالة اللوحة «يُمنع من التطبيق فوراً».
  ///   · وإلا نمرّ بمسار التحديث الكامل مع **إبطال كاش دور العيادة**:
  ///     تعيين/إرجاع طبيب أو سكرتير، أو مندوب/صاحب صيدلية ⇒ زبون،
  ///     يظهر في هذه اللحظة لا بعد دورة الدقيقة.
  Future<void> refreshAccountSignal() async {
    if (!_isLoggedIn || _phone == null || _phone!.isEmpty) return;
    final phone = _phone!;
    SupabaseService.instance.setSessionToken(_sessionToken);
    final row = await SupabaseService.instance.readOwnUserRow(phone);
    // تبدّل الحساب أو خرج أثناء الانتظار ⇒ اترك للأحدث.
    if (!_isLoggedIn || _phone != phone) return;
    if (row != null && row['is_active'] == false) {
      _accountRemoved = true;
      _stopRoleWatch();
      await _forceSignOut();
      return;
    }
    refreshClinicRoleNow();
  }

  Future<void> refreshFromServer() async {
    if (!_isLoggedIn || _phone == null || _phone!.isEmpty) return;
    if (_refreshing) return;
    _refreshing = true;
    // ★ حقن `x-app-token` قبل الفحص: بدونه تعمل سياسات RLS على
    //   `users` والجلسة تُقرأ على أنها لا تملك هذا الحساب.
    SupabaseService.instance.setSessionToken(_sessionToken);
    try {
      final result = await SupabaseService.instance.findUserChecked(_phone!);

      // ★★ أي دليل إيجابي على أن الحساب موجود ⇒ لا مَ sip ولا خروج.
      //   نُصفّر العدّاد عند أول نجاح، فلا يتراكم «غياب» عابر.
      if (result.status == UserLookupResult.found) {
        _missingStreak = 0;
        final user = result.user!;
        if (user['is_active'] == false) {
          // إيقاف مؤقت من الأدمن: ليس حذفاً، ولا نُخرج على الإيقاف.
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        _isDriver = user['is_driver'] == true;
        // ★ كان هنا: `_isAdmin = user['is_admin'] == true || _phone == adminPhone`
        // أي أن أي جهاز يسجل الدخول برقم الأدمن كان يصير أدمن تلقائياً من
        // رقم الهاتف وحده — حتى لو أُلغي الدور من القاعدة. الصلاحية تأتي
        // الآن من `is_admin` في القاعدة فقط.
        _isAdmin = user['is_admin'] == true;
        _isShopOwner = user['is_shop_owner'] == true;

        // ★ دور العيادة (طبيب/سكرتير) لا يوجد عمود له في `users`؛
        //   يُقرأ من `doctors` عبر دالة محميّة بمرة واحدة كل دقيقة.
        await _refreshClinicRole();

        // صيدلية صاحب الصيدلية المرتبط برقم هاتفه.
        if (_isShopOwner) {
          final samePhone = _shopLookupPhone == _phone;
          final fresh = samePhone &&
              DateTime.now().difference(_shopLookupAt) < _shopLookupTtl;
          // نبحث فوراً إن لم نكن نعرف الصيدلية، وإلا مرة كل خمس دقائق.
          if (_shopId == null || !fresh) {
            final shop = await SupabaseService.instance.fetchShopByOwnerPhone(
              _phone!,
            );
            _shopLookupPhone = _phone;
            _shopLookupAt = DateTime.now();
            if (shop != null) {
              _shopId = shop['id']?.toString();
              _shopName = shop['name']?.toString();
            }
          }
        } else {
          _shopId = null;
          _shopName = null;
          _shopLookupPhone = null;
          _shopLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
        }

        final serverName = user['name']?.toString();
        final nextName = (serverName != null && serverName.isNotEmpty)
            ? serverName
            : _name;
        // مزامنة صورة الحساب: تعديل الصورة من أي جهاز يظهر لدى المستخدم.
        final serverAvatar = user['avatar_url']?.toString().trim() ?? '';
        final nextAvatar = (serverAvatar.isNotEmpty && serverAvatar != 'null')
            ? serverAvatar
            : _avatarUrl;

        final nextShopId = _isShopOwner ? _shopId : null;
        final nextShopName = _isShopOwner ? _shopName : null;

        // نقارن قبل الكتابة: الدورية تعمل كل ٢٠ ثانية، والكتابة غير
        // الضائعة + `notifyListeners` تعني إعادة بناء **الشاشات الخمس كلها**
        // مع إعادة حساب أقسام الصفحة الرئيسية، كل ٢٠ ثانية، بلا سبب.
        // ★ الأدوار جزء من `changed`: لو أ Admin أبدّل الدور، يجب أن
        // تُبدَّل الشاشة نفسها فوراً. بدونها لا يُعاد البناء إلا إن
        // تغيّر الاسم/الصورة — فلو فُتح الدور والصيدلية غير موجود بعد،
        // يبقى على الشاشة القديمة مع أن الدور تغيّر فعلاً.
        final roleChanged =
            _prevIsDriver != _isDriver ||
            _prevIsAdmin != _isAdmin ||
            _prevIsShopOwner != _isShopOwner ||
            _prevIsDoctor != _isDoctor ||
            _prevIsSecretary != _isSecretary;
        _prevIsDriver = _isDriver;
        _prevIsAdmin = _isAdmin;
        _prevIsShopOwner = _isShopOwner;
        _prevIsDoctor = _isDoctor;
        _prevIsSecretary = _isSecretary;

        final changed =
            roleChanged ||
            _name != nextName ||
            _avatarUrl != nextAvatar ||
            _shopId != nextShopId ||
            _shopName != nextShopName;

        if (_avatarUrl != nextAvatar) {
          _avatarUrl = nextAvatar;
          if (nextAvatar != null) await prefs.setString(_kAvatar, nextAvatar);
        }
        _name = nextName;
        _shopId = nextShopId;
        _shopName = nextShopName;

        if (changed) {
          await prefs.setBool(_kIsDriver, _isDriver);
          await prefs.setBool(_kIsAdmin, _isAdmin);
          await prefs.setBool(_kIsShopOwner, _isShopOwner);
          await prefs.setBool(_kIsDoctor, _isDoctor);
          await prefs.setBool(_kIsSecretary, _isSecretary);
          if (nextShopId != null) {
            await prefs.setString(_kShopId, nextShopId);
          } else {
            await prefs.remove(_kShopId);
          }
          if (nextShopName != null) {
            await prefs.setString(_kShopName, nextShopName);
          } else {
            await prefs.remove(_kShopName);
          }
          if (nextName != null) await prefs.setString(_kName, nextName);
        }

        // نُخطر مرة واحدة فقط وعند تغيّر حقيقي.
        if (changed) notifyListeners();
      } else if (result.status == UserLookupResult.notFound) {
        // ────────────────────────────────────────────────────────────────
        //  ★★★ الحذف الحقيقي فقط يخرج. لا شيء غير ذلك.
        // ────────────────────────────────────────────────────────────────
        //  `notFound` ليس دليلاً على الحذف: قد يكون شبكة مقطوعة، أو
        //  جدولاً خلف RLS يُرجع `[]` لأي استعلام، أو استعلاماً لم يُكمل.
        //  سابقاً كان نفيٌ واحد كافياً للخروج — وهو ما كان يُخرج الناس
        //  بلا سبب.
        //
        //  الآن نطلب **سلسلة متتالية** من الغياب. أي نجاح واحد، أو أي
        //  خطأ شبكة، يُصفّر العدّاد ⇒ لا خروج.
        _missingStreak++;
        final required = 3;
        if (_missingStreak >= required) {
          _accountRemoved = true;
          _stopRoleWatch();
          await _forceSignOut();
        }
        return;
      } else {
        // خطأ شبكة: لا دليل على أي شيء ⇒ لا خروج، ويُصفّر العدّاد.
        _missingStreak = 0;
        return;
      }
    } finally {
      _refreshing = false;
    }
  }

  /// ★ يقرأ دور العيادة من `my_doctor_roles` (طبيب/سكرتير).
  ///
  ///   مرة كل دقيقة فقط: دالة الخادم رخيصة لكن دورة المراقبة تعمل كل
  ///   ٢٠ ثانية لكل حساب، فلا نضيف رحلة RPC في كل دورة. ونتيجة فشل
  ///   الشبكة **لا تمسح** دوراً معروفاً (لا دليل على التغيير).
  Future<void> _refreshClinicRole() async {
    if (_phone == null || _phone!.isEmpty) return;
    if (_isAdmin) {
      _isDoctor = false;
      _isSecretary = false;
      return;
    }
    final samePhone = _clinicLookupPhone == _phone;
    final fresh = samePhone &&
        DateTime.now().difference(_clinicLookupAt) < _clinicLookupTtl;
    if (fresh) return;

    final gen = _clinicGeneration;
    final ctx = await DoctorService.instance.myRoles();
    if (!_isLoggedIn || _phone == null) return;
    // إبطال وقع أثناء القراءة ⇒ النتيجة قد تسبق التغيير ⇒ لا تُخزَّن،
    // والدورة التالية (3 ثوانٍ) تقرأ من جديد.
    if (gen != _clinicGeneration) return;
    final failed =
        (SupabaseService.instance.lastRpcError ?? '').trim().isNotEmpty;
    _clinicLookupPhone = _phone;
    _clinicLookupAt = DateTime.now();
    if (ctx == null && failed) return;
    _isDoctor = ctx?.isDoctor ?? false;
    _isSecretary = ctx?.isSecretary ?? false;
  }

  /// كشف الحساب محذوفاً أو معطلاً من الأدمن: تنظيف محلي دون تغيير
  /// علم accountRemoved حتى يعيد التطبيق التوجيه لشاشة تسجيل الدخول.
  /// ★ لا نُبطل التوكن هنا: `refreshFromServer` يناديها كل ٢٠ ثانية،
  ///   والإبطال كان سيقطع الجلسة نفسها. الإبطال في [logout] و init] فقط.
  Future<void> _forceSignOut() async {
    final prefs = await SharedPreferences.getInstance();
    SupabaseService.instance.setSessionToken(null);
    _isLoggedIn = false;
    _name = null;
    _phone = null;
    _avatarUrl = null;
    _isAdmin = false;
    _isDriver = false;
    _isShopOwner = false;
    _isDoctor = false;
    _isSecretary = false;
    _shopId = null;
    _shopName = null;
    _shopLookupPhone = null;
    _shopLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
    _clinicLookupPhone = null;
    _clinicLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
    await prefs.setBool(_kLoggedIn, false);
    await prefs.remove(_kName);
    await prefs.remove(_kPhone);
    await prefs.remove(_kAvatar);
    await prefs.setBool(_kIsAdmin, false);
    await prefs.setBool(_kIsDriver, false);
    await prefs.setBool(_kIsShopOwner, false);
    await prefs.setBool(_kIsDoctor, false);
    await prefs.setBool(_kIsSecretary, false);
    await prefs.remove(_kShopId);
    await prefs.remove(_kShopName);
    notifyListeners();
  }

  /// يحفظ بيانات المستخدم ويسجل دخوله حتى إعادة التشغيل.
  ///
  /// ★ `sessionToken` هو التوكن الموقّع الذي تعيده verify_login بعد
  ///   SQL_HARDEN_STAGE2. نمرّره إلى SupabaseService فوراً فيُرفَق بترويسة
  ///   `x-app-token` مع كل طلب. **لا نحفظه في SharedPreferences**: التوكن
  ///   bearer يمنح قراءة طلبات الآخرين، وتخزينه في localStorage يجعله
  ///   هدفاً لأي XSS. يُفقد بإغلاق التطبيق ⇒ إعادة دخول، وهو المقايضة
  ///   المقبولة حتى نضيف flutter_secure_storage.
  Future<void> login({
    String? name,
    String? phone,
    String? avatarUrl,
    bool isAdmin = false,
    bool isDriver = false,
    bool isShopOwner = false,
    String? shopId,
    String? shopName,
    String? sessionToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // يُضبط قبل أي قراءة من القاعدة، وإلا طلب refreshFromServer بلا جلسة.
    SupabaseService.instance.setSessionToken(sessionToken);
    // ★ محفوظ هنا أيضاً: التحديث الدوري يحتاجه لحقَن `x-app-token`
    //   قبل قراءة `users` — وهو شرط أن تعيد سياسات RLS الصف.
    _sessionToken = sessionToken;
    _isLoggedIn = true;
    _name = name ?? '';
    _phone = phone;
    if (avatarUrl != null) _avatarUrl = avatarUrl;
    _isAdmin = isAdmin;
    _isDriver = isDriver;
    _isShopOwner = isShopOwner;
    // دور العيادة يُكتشف بعد الدخول من `my_doctor_roles`.
    _isDoctor = false;
    _isSecretary = false;
    _clinicLookupPhone = null;
    _clinicLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
    _accountRemoved = false;
    // ★ عدّاد الغياب لا يعبر بين الجلسات: بقاياه من شبكة متعثّرة
    //   سابقاً كانت تجعل أول فحص بعد دخول جديد يبلغ الحدّ فيُخرج
    //   المستخدم فوراً إلى شاشة الدخول من جديد.
    _missingStreak = 0;
    _shopId = _isShopOwner ? shopId : _shopId;
    _shopName = _isShopOwner ? shopName : _shopName;
    // ★ الكتابات كانت **عشر عمليات `await` متتالية** ⇒ عشر رحلات
    //   منفصلة إلى القرص عبر MethodChannel قبل أن ينتقل المستخدم.
    //   `Future.wait` ينفّذها معاً فيدفعة واحدة، فتنقذ زمن الاستجابة
    //   على الزر دون أن نفقد الضمان: لا نُعلن عن الدخول قبل حفظها.
    await Future.wait([
      prefs.setBool(_kLoggedIn, true),
      prefs.setString(_kName, _name ?? ''),
      prefs.setString(_kPhone, phone ?? ''),
      prefs.setBool(_kIsAdmin, _isAdmin),
      prefs.setBool(_kIsDriver, _isDriver),
      prefs.setBool(_kIsShopOwner, _isShopOwner),
      prefs.setBool(_kIsDoctor, false),
      prefs.setBool(_kIsSecretary, false),
      // ★★ لا بدّ من حفظ التوكن وإلا خرج المستخدم عند كل إغلاق.
      if (_sessionToken != null)
        prefs.setString(_kSessionToken, _sessionToken!),
      if (avatarUrl != null) prefs.setString(_kAvatar, avatarUrl),
      if (_shopId != null) prefs.setString(_kShopId, _shopId!),
      if (_shopName != null) prefs.setString(_kShopName, _shopName!),
    ]);

    // ★★ **بلا انتظار**. كان `await refreshFromServer()` هنا، وهي
    //   ترحلتين شبكيتين متتاليتين: `findUserChecked` ثم
    //   `fetchShopByOwnerPhone` لصاحب الصيدلية. فكان المستخدم يضغط
    //   «دخول» وينتظر الشبكة كاملة (حتى ١٢ ثانية × ٢) قبل أن
    //   تنتقل الواجهة — وهو أبطأ ما في التطبيق وأكثره وضوحاً للمستخدم.
    //   الأدوار تأتي أصلاً من `verify_login` في السطر السابق، فنُعلن
    //   فوراً والتحديث يصحّح بعده (نفس قرار الإقلاع في [_init]).
    unawaited(refreshFromServer());
    _startRoleWatch();
    notifyListeners();
  }

  /// يمسح بيانات الدخول المحفوظة ويُخرج المستخدم.
  ///
  /// ★★ الترتيب مقصود (طلب ٢٠٢٦-١٠-١٢: «عند تسجيل الخروج لا تُرسَل
  ///   إشعارات»): إبطال توكن جهاز هذا الحساب **أولاً وبانتظار ثلاث
  ///   ثوانٍ**، لا `unawaited` في منتصف التنظيف. الذي كان يحدث: النداء
  ///   يُقذف ثم تُصفَّر الواجهة، فمن أغلق التطبيق بعد الخروج مباشرة
  ///   لم يصل النداء أصلاً، فيبقى جهازه مسجّلاً في `push_tokens` لحساب
  ///   خرج — فيستمر السيرفر في دقّه حتى ثلاثة أسابيع. والفشل لا يُعلّق
  ///   الخروج: أسوأ ما فيه رسالة واحدة زيادة.
  Future<void> logout() async {
    final leavingPhone = _phone?.trim() ?? '';
    _shopLookupPhone = null;
    _shopLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
    if (leavingPhone.isNotEmpty) {
      // ★ الخروج = خروج من التطبيق: «آخر ظهور» يُختم قبل أن تُفرَّغ
      //   الجلسة، وإلا بقي الحساب «متصل الآن» حتى تنتهي صلاحية النبضة.
      await PresenceService.instance.markOfflineNow();
      await SupabaseService.instance
          .deactivatePushTokens(leavingPhone, timeoutSeconds: 3);
    }
    await _signOutLocally();
  }

  /// ★★ بعد أن حذفَت القاعدة الحساب فعلاً (`delete_own_account` رجعت
  ///   `ok:true`): تنظيف محلي كامل **بلا رحلة شبكة ثانية** — فصفّ
  ///   المستخدم وصفّ جهازه لم يعودا موجودين، وأي إبطال توكن الآن كتابة
  ///   في رقمٍ لا وجود له.
  Future<void> accountDeletedLocally() async => _signOutLocally();

  /// التنظيف المشترك بين الخروج العادي وحذف الحساب. لا شبكة فيه إطلاقاً.
  Future<void> _signOutLocally() async {
    final prefs = await SharedPreferences.getInstance();
    // ★ يُبطَل التوكن عند الخروج: لو بقي على الجهاز خطأً إلغاؤه
    //   لا يكفي، لأن كل طلب لاحق سيُرسل توكناً صالحاً.
    SupabaseService.instance.setSessionToken(null);
    // ★ ونُفرّغه محلياً أيضاً، وإلا أعادته دورة المراقبة التالية
    //   إلى ترويسات الطلبات بعد الخروج.
    _sessionToken = null;
    // ★ ونغمة معلّقة تُلغى هنا أيضاً: الخروج قد لا يمرّ بـ
    //   NotificationCenter.onAccountChanged، فتبقى النغمة الجارية
    //   للحساب القديم بعد تسجيل الخروج.
    unawaited(NotificationSound.instance.stopAll());
    // ★ كلمة مرور الإدارة محفوظة في الذاكرة عبر الجلسات ⇒ تُمسح عند
    //   الخروج. من ينتقل إلى حساب آخر لا يجدها جاهزة.
    AdminPasswordSession.clear();
    // ★★ مسح سجلّ منع التكرار: كان البقاء بعد الخروج يعني أن
    //   إشعار الحساب **الأول** يُسكت إشعار الحساب **الثاني** على
    //   الجهاز نفسه (مفتاحه order:{id}:{type}، والسجلّ ٢٤ ساعة).
    //   مستخدمان على جهاز واحد ⇒ الأول يُخطئ في إشعارات الثاني.
    //   `NotificationDedup.clear()` كان مكتوباً ولا يُستدعى إطلاقاً.
    unawaited(NotificationDedup.clear());
    // ★★ توكن الجهاز: الخروج أبطل صفّه في `push_tokens`، و`PushService`
    //   كان يتذكر أنه «كتبه» في نفس العملية ⇒ الدخول التالي يمرّ بلا
    //   كتابة، فيبقى الصفّ `is_active=false` والسيرفر لا يرسل FCM لهذا
    //   الهاتف (إشعار الطلب الجديد لا يصل والتطبيق مغلق). النسيان هنا
    //   يجعل أول دخول بعده يعيد التفعيل.
    PushService.instance.forgetRegisteredToken();
    // ★ لقطات الشاشات المحلية (سجل طلباتي / تتبع الطلب) محفوظة بأرقام
    //   الهواتف ومعرفات الطلبات على القرص. تُمسح عند الخروج حتى لا يفتح
    //   حسابٌ آخر على الجهاز نفسه طلبات صاحبه. آمنة المسح: هي نسخ عرض
    //   فقط، والشبكة مصدرها وتُعاد كتابتها عند أول فتح.
    unawaited(CatalogCache.instance.clearAllObjects());
    // ★★ الخروج = الحساب صار **خارج التطبيق** ⇒ لا شعار له بعد الآن.
    //   `account_is_online` (معيار إرسال الشعار) تقرأ `push_tokens`،
    //   وقد أُبطلت هناك في [logout] قبل هذا التنظيف.
    _isLoggedIn = false;
    _name = null;
    _phone = null;
    _avatarUrl = null;
    // ★★ «لا شعار إلا لمن هو داخل»: نمسح شعار الحساب **قبل** إتمام
    //   الخروج. `NotificationCenter.brandImage` صار يستفسر
    //   `isLoggedIn` (وهو false الآن)، وهذا المسح يخلّيه خالياً من
    //   أصله فلا يبقى معلقاً على الجهاز.
    NotificationCenter.instance.clearBrand();
    SupabaseService.instance.clearBrandCache();
    _isAdmin = false;
    _isDriver = false;
    _isShopOwner = false;
    _isDoctor = false;
    _isSecretary = false;
    _shopId = null;
    _shopName = null;
    _clinicLookupPhone = null;
    _clinicLookupAt = DateTime.fromMillisecondsSinceEpoch(0);
    _accountRemoved = false;
    _missingStreak = 0;
    _stopRoleWatch();
    await prefs.setBool(_kLoggedIn, false);
    // ★ لا بدّ من إزالة التوكن المحفوظ أيضاً، وإلا فُتح التطبيق التالي
    //   بـ`auth_logged_in=false` وتوكن حيّ — حالة نصف حيّة.
    await prefs.remove(_kSessionToken);
    await prefs.remove(_kName);
    await prefs.remove(_kPhone);
    await prefs.remove(_kAvatar);
    await prefs.setBool(_kIsAdmin, false);
    await prefs.setBool(_kIsDriver, false);
    await prefs.setBool(_kIsShopOwner, false);
    await prefs.setBool(_kIsDoctor, false);
    await prefs.setBool(_kIsSecretary, false);
    await prefs.remove(_kShopId);
    await prefs.remove(_kShopName);
    notifyListeners();
  }
}
