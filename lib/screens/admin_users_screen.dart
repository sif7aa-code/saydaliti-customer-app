import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/account_name.dart';
import '../core/utils/user_search.dart';
import '../services/admin_password_session.dart';
import '../services/city_store.dart';
import '../services/doctor_directory_service.dart';
import '../services/local_image_store.dart';
import '../services/real_data_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/tap_to_dismiss_keyboard.dart';
import '../widgets/working_hours_picker.dart';

/// إدارة المستخدمين (الأدمن): عرض المستخدمين وتعيين/إلغاء مندوبية وحذف.
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _users = [];

  /// الأقسام النشطة: تُعرض في نافذة «نقل إلى قسم» عند إنشاء صيدلية جديدة.
  List<Map<String, dynamic>> _categories = const [];

  /// ★ صفة العيادة لكل رقم (طبيب/سكرتير) — تُقرأ من جدول `doctors`
  ///   (`phone` و`secretary_phone`). بدونها كان الحساب المحوَّل إلى
  ///   طبيب يبقى «عميل» في القائمة رغم أن التطبيق يعرض له واجهة
  ///   العيادة. (لا نقرأها من `admin_list_doctor_wallets`: تلك تُرجع
  ///   العيادات التي لها قيود مالية فقط، فطبيب جديد بلا كشفيات يغيب.)
  Map<String, String> _clinicRoles = const {};

  /// ★ أرقام (آخر ١٠) لمن له ملف طبيب **مخفي** (`doctors.is_active=false`):
  ///   ظهر سابقاً في الدليل ثم أُعيد زبوناً. نُظهر ملاحظة أن ملفه ومحفظته
  ///   محفوظان ويعودان عند التحويل إلى طبيب من جديد.
  Set<String> _hiddenDoctorPhones = const {};

  /// كل صفوف `doctors` بما فيها المخفية — بحثُ التحويل يستخدمها فلا
  /// يُنشئ نسخة مكرّرة لطبيب مخفي.
  List<Map<String, dynamic>> _doctorRows = const [];

  /// ★ كلمة البحث. التصفية من القائمة المحمَّلة نفسها، لا طلب جديد للقاعدة:
  ///     المستخدمين كلها تصل في نداء واحد، فالبحث الفوري أسرع وأصدق من
  ///     `ilike` يُعيد تحميل القائمة كل حرف.
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  /// القائمة الظاهرة بعد البحث، وبالأمر نفسه حين لا بحث.
  ///
  /// الصفة (مندوب/أدمن/صاحب صيدلية/عميل) تُطابَق هنا لا داخل `UserSearch`:
  /// لأن تسميتها مصدرها `_roleLabel` في هذه الشاشة، فلا يكون للصفة اسمان.
  List<Map<String, dynamic>> get _visible {
    if (_query.isEmpty) return _users;
    final q = UserSearch.fold(_query);
    return _users
        .where(
          (u) =>
              UserSearch.matches(u, _query) ||
              UserSearch.fold(_roleLabel(u)).contains(q),
        )
        .toList();
  }

  /// تُعيد القائمة الطازجة: تغيير الصلاحية يتحقق منها بعد الكتابة
  /// ليقول الأدمن الحالة **الفعلية** التي في القاعدة لا مجرد «تم».
  Future<List<Map<String, dynamic>>> _load() async {
    setState(() => _loading = true);
    // الثلاثة تنطلق معاً ثم ننتظرها بالترتيب.
    final usersFuture = SupabaseService.instance.fetchUsers();
    final categoriesFuture = SupabaseService.instance.fetchCategories();
    final doctorsFuture = SupabaseService.instance.fetchDoctors(
      includeInactive: true,
    );
    final users = await usersFuture;
    final categories = await categoriesFuture;
    final doctors = await doctorsFuture;
    if (!mounted) return users;
    final activeDoctors = doctors
        .where((d) => d['is_active'] != false)
        .toList();
    setState(() {
      _users = users;
      _categories = categories;
      _doctorRows = doctors;
      _clinicRoles = _mapClinicRoles(activeDoctors);
      _hiddenDoctorPhones = {
        for (final d in doctors)
          if (d['is_active'] == false)
            if (_last10(d['phone']?.toString() ?? '').length >= 7)
              _last10(d['phone']?.toString() ?? ''),
      };
      _loading = false;
    });
    return users;
  }

  /// صف الحساب من قائمة حديثة — بمطابقة آخر ١٠ أرقام كما في `_clinicRoleFor`.
  static Map<String, dynamic>? _rowForPhone(
    List<Map<String, dynamic>> rows,
    String phone,
  ) {
    final key = _last10(phone);
    if (key.length < 7) {
      for (final r in rows) {
        if (r['phone']?.toString() == phone) return r;
      }
      return null;
    }
    for (final r in rows) {
      if (_last10(r['phone']?.toString() ?? '') == key) return r;
    }
    return null;
  }

  /// ★ نافذة انتظار أثناء الكتابة: كان الضغط بلا أي أثر مرئي حتى تعود
  ///   الشبكة (حتى ١٥ ثانية للنداء الواحد)، فيظنّ الأدمن أن الزر لا يعمل.
  Future<T?> _runBusy<T>(String label, Future<T> Function() action) async {
    BuildContext? dlg;
    final shown = showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) {
        dlg = ctx;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            content: Row(
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    unawaited(shown);
    // إطار واحد حتى تُرسم النافذة قبل أن يبدأ النداء الشبكي.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    try {
      return await action();
    } finally {
      final ctx = dlg;
      if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    }
  }

  /// ★ نتيجة العملية بنافذة تُقرأ ولا تُفوَّت — بدل شريط سفلي عابر
  ///   كان يمرّ بلا أن يراه الأدمن، فيقول: «لا يرجع ولا يقول».
  Future<void> _showOutcome({
    required bool ok,
    required String title,
    required String message,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Icon(
          ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          color: ok ? AppColors.success : AppColors.danger,
          size: 40,
        ),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontSize: 13, height: 1.7),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(
              backgroundColor: ok ? AppColors.primary : AppColors.danger,
            ),
            child: Text(
              'حسناً',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  /// إشعار عابر غير حاسم (إلغاء خطوة مثلاً) — لا يعرضه كنجاح ولا كخطأ.
  void _showInfo(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          backgroundColor: AppColors.textSecondary,
        ),
      );
  }

  /// خريطة «آخر ١٠ أرقام» ⇒ صفة العيادة. الطبيب يسبق السكرتير إن كان
  /// الرقم نفسه مسجّلاً في العيادتين.
  Map<String, String> _mapClinicRoles(List<Map<String, dynamic>>? items) {
    if (items == null || items.isEmpty) return const {};
    final map = <String, String>{};
    for (final d in items) {
      final doctor = _last10(d['phone']?.toString() ?? '');
      if (doctor.length >= 7) map[doctor] = 'طبيب';
      final secretary = _last10(d['secretary_phone']?.toString() ?? '');
      if (secretary.length >= 7 && map[secretary] != 'طبيب') {
        map[secretary] = 'سكرتير عيادة';
      }
    }
    return map;
  }

  String? _clinicRoleFor(Map<String, dynamic> user) {
    final key = _last10(user['phone']?.toString() ?? '');
    if (key.length < 7) return null;
    return _clinicRoles[key];
  }

  /// صفّ الطبيب لهذا الحساب من القائمة المحمَّلة (بما فيها المخفي).
  Map<String, dynamic>? _doctorRowFor(
    Map<String, dynamic> user, {
    bool requireActive = false,
  }) {
    final key = _last10(user['phone']?.toString() ?? '');
    if (key.length < 7) return null;
    for (final d in _doctorRows) {
      if (_last10(d['phone']?.toString() ?? '') != key) continue;
      if (requireActive && d['is_active'] == false) continue;
      return d;
    }
    return null;
  }

  /// ★ رسالة تأكيد قبل تغيير الصلاحية — بلا كلمة مرور.
  ///
  /// سبب تغيير المسار أصلاً: `SQL_LOCKDOWN.sql` نصب تريجراً يرفض تغيير
  /// الصلاحيات من التطبيق تماماً (وهو سبب «تعذر» الذي كان يظهر). والطريق
  /// المسموح هو دالة على الخادم. والتأكيد هنا يمنع الخطأ بالضغط بالخطأ.
  Future<bool> _askConfirm(String title, String message) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          title,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          message,
          style: GoogleFonts.cairo(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('تأكيد', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    return yes == true;
  }

  /// ★ تبديل صلاحية عبر الدالة الواحدة `admin_set_user_role`.
  ///
  /// `null` = لا تغيّر هذا العمود. تُعيد true عند النجاح فقط.
  Future<bool> _setRole(
    Map<String, dynamic> user, {
    bool? isDriver,
    bool? isShopOwner,
    bool? isActive,
    required String confirmTitle,
    required String confirmMessage,
    String? successMsg,
  }) async {
    final phone = user['phone']?.toString() ?? '';
    final name = AccountName.real(name: user['name'], phone: user['phone']);
    if (phone.isEmpty) {
      await _showOutcome(
        ok: false,
        title: 'تعذر التغيير',
        message: 'رقم هذا الحساب فارغ، فلا يمكن ربطه بصف في القاعدة.',
      );
      return false;
    }

    // ★ حالة الحساب الحالية تظهر قبل التأكيد: الأدمن يرى من أي صفة
    //   ينتقل الحساب، لا الصفة الجديدة وحدها.
    if (!await _askConfirm(
      confirmTitle,
      'الحالة الحالية: ${_roleLabel(user)}\n\n$confirmMessage',
    )) {
      return false;
    }
    if (!mounted) return false;

    final res = await _runBusy(
      'جارٍ تطبيق التغيير…',
      () => SupabaseService.instance.adminSetUserRole(
        phone,
        isDriver: isDriver,
        isShopOwner: isShopOwner,
        isActive: isActive,
      ),
    );
    if (!mounted) return false;

    if (res == null || res['ok'] != true) {
      final why = (res?['error'] ?? 'لم يردّ الخادم بأي نتيجة').toString();
      await _showOutcome(
        ok: false,
        title: 'تعذر التغيير',
        message: '$why\n\nلم يتغيّر شيء في الحساب.',
      );
      return false;
    }

    // ★ نقرأ الحساب من القاعدة بعد الكتابة: الرسالة تقول الحالة
    //   **الفعلية**، وإن تجاهلت القاعدة التعديل يُقال ذلك صريحاً
    //   بدل إعلان نجاح غير واقعي.
    final fresh =
        await _runBusy('جارٍ تحديث القائمة…', _load) ??
        const <Map<String, dynamic>>[];
    if (!mounted) return false;

    final row = _rowForPhone(fresh, phone);
    var applied = row != null;
    if (row != null) {
      if (isDriver != null) {
        applied = (row['is_driver'] == true) == isDriver;
      } else if (isShopOwner != null) {
        applied = (row['is_shop_owner'] == true) == isShopOwner;
      } else if (isActive != null) {
        applied = (row['is_active'] != false) == isActive;
      }
    }
    if (!applied) {
      await _showOutcome(
        ok: false,
        title: 'لم يتغيّر الحساب',
        message:
            'أعلن الخادم النجاح لكن القاعدة أعادت الحساب بحالته السابقة.'
            '\nالحالة الآن: ${row == null ? 'غير معروفة' : _roleLabel(row)}',
      );
      return false;
    }

    final status = StringBuffer(
      '$name\nالحالة الآن: ${row == null ? _roleLabel(user) : _roleLabel(row)}',
    );
    if (row != null && row['is_active'] == false) {
      status.write(' — الحساب معطّل');
    }
    await _showOutcome(
      ok: true,
      title: successMsg ?? 'تم',
      message: status.toString(),
    );
    return true;
  }

  Future<void> _toggleDriver(Map<String, dynamic> user, bool toDriver) async {
    final name = AccountName.real(name: user['name'], phone: user['phone']);
    await _setRole(
      user,
      isDriver: toDriver,
      confirmTitle: toDriver ? 'تعيينه مندوباً' : 'إزالة المندوبية',
      confirmMessage: toDriver
          ? 'سيتم منح $name صلاحية المندوب، فيظهر له'
                ' الطلبات الجارية وإدارة التوصيل.'
          : 'سيُمنع $name من الوصول لشاشة المندوب'
                ' فوراً.',
      successMsg: toDriver ? 'تم تعيينه مندوباً' : 'تمت إزالة المندوبية',
    );
  }

  /// تحويل أي حساب إلى صاحب صيدلية: يُنشئ الصيدلية فوراً باسم يختاره الأدمن
  /// (أو الاسم الافتراضي) فيظهر الصيدلية في الرئيسية مع منتجاته مباشرةً.
  ///
  /// يسأل أيضاً عن **صورة الحساب** (اختياري) فيُحفظ في `avatar_url` فتظهر
  /// الصورة في الملف الشخصي لكل الأجهزة. الصورة عمود غير محميّ، فتبقى
  /// بPATCH عادي — أما `is_shop_owner` فمحميّ فتمرّ بالدالة.
  ///
  /// إبطال كاش الكتالوج فوراً بعد إنشاء أو ربط صيدلية.
  ///
  /// ★ بدونه لا يظهر الصيدلية الجديد في «الصيدليات» إلا بعد مرور مدّة
  ///   الكاش (٦٠ ثانية) أو إعادة تشغيل التطبيق، فيبدو التحويل ناجحاً
  ///   بينما الصيدلية غائب عن الشاشة. وهو نفس ما يفعله
  ///   `admin_shops_screen` بعد إنشاء صيدلية يدوياً.
  void _publishShop() {
    RealDataService.instance.clearCache();
    RealDataService.instance.catalogGeneration.value++;
  }

  // ★ «إلغاء الصيدلية»: يُخفي المتجر من الرئيسية ويعيد الحساب زبوناً
  //   عادياً — بلا حذف. نفس الصف والمنتجات والطلبات والمحفظة تبقى،
  //   وتعود الصيدلية نفسها عند تعيينه صاحب صيدلية من جديد.
  //
  // ★ الإخفاء يكتب `shops.is_active` — عمود يأتي من
  //   tmp/shop_visibility.sql. قبل تشغيله لا يوجد العمود، فنُرجع
  //   الحساب زبوناً ونُبلغ الأدمن صراحةً أن المتجر بقي ظاهراً، بدل
  //   ادّعاء إخفاء لم يحدث.
  Future<void> _cancelPharmacy(Map<String, dynamic> user) async {
    final phone = user['phone']?.toString() ?? '';
    final name = AccountName.real(name: user['name'], phone: user['phone']);
    if (phone.isEmpty) {
      await _showOutcome(
        ok: false,
        title: 'تعذر التغيير',
        message: 'رقم هذا الحساب فارغ.',
      );
      return;
    }
    final shop = await SupabaseService.instance.fetchShopByOwnerPhone(phone);
    if (!mounted) return;
    final shopName = shop?['name']?.toString() ?? '';
    if (!await _askConfirm(
      'إلغاء الصيدلية',
      'الحالة الحالية: ${_roleLabel(user)}\n\n'
          'سيصبح $name زبوناً عادياً وتُخفى ${shopName.isEmpty ? 'صيدليته' : 'صيدلية «$shopName»'} '
          'من الرئيسية والأقسام. لا يُحذف شيء: الاسم والمنتجات والطلبات '
          'والمحفظة تبقى، وتعود الصيدلية نفسها عند تعيينه صاحب صيدلية من جديد.',
    )) {
      return;
    }
    if (!mounted) return;

    final res = await _runBusy(
      'جارٍ إلغاء الصيدلية…',
      () =>
          SupabaseService.instance.adminSetUserRole(phone, isShopOwner: false),
    );
    if (!mounted) return;
    if (res == null || res['ok'] != true) {
      await _showOutcome(
        ok: false,
        title: 'تعذر التغيير',
        message: '${res?['error'] ?? 'لم يردّ الخادم'}\n\nلم يتغيّر شيء.',
      );
      return;
    }

    var hidden = true;
    String? hideProblem;
    if (shop != null && shop['is_active'] != false) {
      if (shop.containsKey('is_active')) {
        hidden =
            await _runBusy(
              'جارٍ إخفاء الصيدلية…',
              () => SupabaseService.instance.updateShop(shop['id'].toString(), {
                'is_active': false,
              }),
            ) ??
            false;
        if (hidden) {
          _publishShop();
        } else {
          hideProblem = SupabaseService.instance.lastAdminError.trim();
        }
      } else {
        hidden = false;
        hideProblem =
            'عمود الإخفاء غير موجود بعد — شغّل tmp/shop_visibility.sql.';
      }
    }

    await _runBusy('جارٍ تحديث القائمة…', _load);
    if (!mounted) return;
    final buffer = StringBuffer('$name\nالحالة الآن: زبون عادي');
    if (shop != null) {
      buffer.write(
        hidden
            ? '\nأُخفيت الصيدلية «$shopName» عن الزبائن، وبياناتها ومحفظتها محفوظة.'
            : '\nبقيت الصيدلية ظاهرة: ${hideProblem ?? 'تعذر الإخفاء'}.',
      );
    }
    await _showOutcome(
      ok: true,
      title: 'تم إلغاء الصيدلية',
      message: buffer.toString(),
    );
  }

  Future<void> _toggleShopOwner(Map<String, dynamic> user, bool toOwner) async {
    if (!toOwner) {
      await _cancelPharmacy(user);
      return;
    }
    final phone = user['phone']?.toString() ?? '';
    final userName = user['name']?.toString().trim() ?? '';

    // الصورة تُختار مرة واحدة وتُستخدم لكل مسارات التحويل.
    final avatarUrl = await _askAvatar(user['avatar_url']?.toString() ?? '');
    if (!mounted) return;

    // صيدلية موجودة مسبقاً؟ نقرأها قبل سؤال الدوام لنجعل جدولها الحالي
    // نقطة بداية بدل أن يبدأ الأدمن من الصفر في كل مرة.
    final existing = await SupabaseService.instance.fetchShopByOwnerPhone(
      phone,
    );
    if (!mounted) return;

    // ★ أيام وساعات الدوام تظهر في بروفايل الصيدلية للجميع.
    //   إلغاء الورقة لا يلغي التحويل: يبقى الدوام الحالي كما هو.
    final hours = await showWorkingHoursPicker(
      context,
      initialText: existing?['working_hours']?.toString() ?? '09:00 - 23:00',
      initialDays: existing?['working_days']?.toString() ?? 'يومياً',
      fullWeek: false,
      title: 'أيام وساعات دوام الصيدلية',
    );
    if (!mounted) return;
    if (existing != null) {
      if (avatarUrl != null &&
          !await SupabaseService.instance.updateUser(phone, {
            'avatar_url': avatarUrl,
          })) {
        _showMessage('تعذر حفظ صورة الحساب', false);
        return;
      }
      final ok = await _setRole(
        user,
        isShopOwner: true,
        confirmTitle: 'تعيينه صاحب صيدلية',
        confirmMessage:
            'سيُربط الحساب بالصيدلية «${existing['name'] ?? ''}»'
            ' وستظهر له شاشة إدارة المنتجات.',
        successMsg:
            'تم التعيين. الصيدلية موجودة باسم: ${existing['name'] ?? ''}',
      );
      if (!ok) return;
      // ★ كانت مخفية بـ«إلغاء الصيدلية»؟ تعود هي نفسها للظهور بكل
      //   منتجاتها وطلباتها ومحفظتها — لا تُنشأ صيدلية جديدة.
      if (existing['is_active'] == false) {
        final restored = await SupabaseService.instance.updateShop(
          existing['id'].toString(),
          {'is_active': true},
        );
        if (restored) _publishShop();
      }
      if (hours != null) {
        await SupabaseService.instance.updateShopWorkingHours(
          existing['id'].toString(),
          openTime: hours.open,
          closeTime: hours.close,
          workingDays: hours.days,
        );
      }
      _publishShop();
      return;
    }

    // لا يوجد صيدلية: نطلب اسم الصيدلية (مع قسمه الاختياري) وننشئه فوراً.
    final details = await _askShopDetails(userName);
    if (details == null || !mounted) return;
    final shopName = details.name;

    final created = await SupabaseService.instance.addShop(
      name: shopName,
      ownerPhone: phone,
      imageUrl: avatarUrl,
      categoryId: details.categoryId,
    );
    if (!mounted) return;
    if (!created) {
      _showMessage('تعذر إنشاء الصيدلية', false);
      return;
    }
    // ★ الصيدلية المنشأ بـ`category_id` يظهر في قسمه فوراً. أمّا الربط
    //   العكسي (`categories.shop_id`) فتقوم به دالة `link_shop_category`
    //   في القاعدة على الـtrigger، فلا يحتاج PATCH إضافي من هنا.
    final shop = await SupabaseService.instance.fetchShopByOwnerPhone(phone);
    if (shop != null && mounted) {
      if (hours != null) {
        await SupabaseService.instance.updateShopWorkingHours(
          shop['id'].toString(),
          openTime: hours.open,
          closeTime: hours.close,
          workingDays: hours.days,
        );
        if (!mounted) return;
      }
      if (details.categoryId != null) {
        await SupabaseService.instance.linkShopCategory(
          shop['id'].toString(),
          details.categoryId!,
        );
        if (!mounted) return;
      }
    }
    // ★ الصيدلية موجود الآن في القاعدة، فنُبطل الكاش فوراً: لو أُلغي
    //   التحويل لاحقاً، يبقى الصيدلية ظاهراً في «الصيدليات» لا يختفي.
    _publishShop();
    if (avatarUrl != null) {
      await SupabaseService.instance.updateUser(phone, {
        'avatar_url': avatarUrl,
      });
    }
    final ok = await _setRole(
      user,
      isShopOwner: true,
      confirmTitle: 'التحويل إلى صيدلية',
      confirmMessage:
          'ستُنشأ صيدلية باسم «$shopName» لهذا الحساب، وسيصبح'
          ' لإدارة منتجاته فوراً.',
      successMsg: 'تم التحويل إلى صيدلية: $shopName',
    );
    // ★ الصيدلية أُنشئ قبل منح الصلاحية، فإخفاق هذه الخطوة يترك صيدليةً
    //   بلا مالك — نُخبر الأدمن صراحةً بدل ابتلاع الخطأ.
    if (!ok) {
      _showMessage(
        'أُنشئت الصيدلية «$shopName» لكن لم يُمنح دور صاحب الصيدلية. '
        'حاول التحويل مرة أخرى.',
        false,
      );
    }
  }

  static String _last10(String v) {
    final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  /// ★ تحويل حساب إلى طبيب: يُنشئ ملف الدليل برقم الحساب نفسه (فتُتاح
  ///   ورقة تعديل البروفايل لصاحب الحساب أيضاً) أو يحدّث ملفاً موجوداً
  ///   لنفس الرقم. الصورة والدوام يختارهما الأدمن هنا، ويظهران في
  ///   بروفايل الطبيب للجميع.
  Future<void> _toDoctor(Map<String, dynamic> user) async {
    final phone = user['phone']?.toString().trim() ?? '';
    if (phone.isEmpty) {
      await _showOutcome(
        ok: false,
        title: 'تعذر التحويل',
        message: 'رقم هذا الحساب فارغ، فلا يمكن ربطه بملف طبيب.',
      );
      return;
    }
    final userName = AccountName.real(name: user['name'], phone: user['phone']);
    final currentAvatar = user['avatar_url']?.toString() ?? '';

    final photo = await _askAvatar(currentAvatar, folder: 'doctors');
    if (!mounted) return;

    final hours = await showWorkingHoursPicker(
      context,
      initialText: '09:00 - 14:00',
      title: 'أيام وساعات دوام الطبيب',
    );
    if (!mounted) return;
    if (hours == null) {
      if (photo != null && photo.isNotEmpty) {
        unawaited(SupabaseService.instance.deleteImage(photo));
      }
      // ★ كان الخروج صامتاً تماماً: الأدمن يغلق الورقة فيرى «لا شيء
      //   حدث» ولا يعرف أن التحويل لم يُحفظ.
      _showInfo('أُلغي التحويل — لم تُحدَّد أوقات الدوام، ولم يُحفظ أي تغيير.');
      return;
    }

    final nameCtrl = TextEditingController(text: userName);
    final displayName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'اسم الطبيب في الدليل',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          textAlign: TextAlign.right,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          decoration: const InputDecoration(
            labelText: 'الاسم الذي يظهر للزبائن',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(
              'متابعة',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    final name = displayName?.trim() ?? '';
    nameCtrl.dispose();
    if (!mounted) return;
    if (name.isEmpty) {
      if (photo != null && photo.isNotEmpty) {
        unawaited(SupabaseService.instance.deleteImage(photo));
      }
      _showInfo('أُلغي التحويل — لم يُكتب اسم الطبيب، ولم يُحفظ أي تغيير.');
      return;
    }

    // ★ يشمل المخفي: ملف أُعيد زبوناً سابقاً يُعاد تفعيله بنفس الصف
    //   (اسمه ودوامه ومحفظته ومواعيده)، لا تُنشأ نسخة مكرّرة له.
    final doctors = await SupabaseService.instance.fetchDoctors(
      includeInactive: true,
    );
    if (!mounted) return;
    final me = _last10(phone);
    Map<String, dynamic>? existing;
    if (me.length >= 7) {
      for (final row in doctors) {
        if (_last10(row['phone']?.toString() ?? '') == me) {
          existing = row;
          break;
        }
      }
    }
    final wasHidden = existing?['is_active'] == false;

    final uploaded = (photo != null && photo.isNotEmpty) ? photo : '';
    final imagePath = uploaded.isNotEmpty
        ? uploaded
        : (existing?['image_path']?.toString() ?? currentAvatar);

    final existingRow = existing;
    bool ok;
    if (existingRow != null) {
      final oldImage = existingRow['image_path']?.toString() ?? '';
      ok =
          await _runBusy(
            'جارٍ تحديث ملف الطبيب…',
            () => SupabaseService.instance.updateDoctor(
              existingRow['id'].toString(),
              {
                'name': name,
                'phone': phone,
                'working_hours': hours.text,
                // ★ الحساب المحوَّل يدخل شريط الرأس المتحرك أيضاً: نعلّمه مميزاً
                //   حتى يظهر في مقدمة الشريط كبقية المضافين من «إدارة الأطباء».
                'is_featured': true,
                // ★ كان مخفياً بعد «إرجاع إلى زبون»: يعود للظهور بنفس المعرّف
                //   والاسم والدوام والمواعيد ودفتر المحفظة — لا يُحذف شيء.
                'is_active': true,
                if (imagePath.isNotEmpty && imagePath != oldImage)
                  'image_path': imagePath,
              },
            ),
          ) ??
          false;
      if (ok &&
          imagePath.isNotEmpty &&
          imagePath != oldImage &&
          oldImage.startsWith('http')) {
        unawaited(SupabaseService.instance.deleteImage(oldImage));
      }
    } else {
      ok =
          await _runBusy(
            'جارٍ تحويل الحساب إلى طبيب…',
            () => SupabaseService.instance.addDoctor(
              name: name,
              phone: phone,
              city: CityStore.cities.first,
              imagePath: imagePath,
              workingHours: hours.text,
              // ★ «تحويل إلى طبيب» يضيفه مميزاً فيدخل الشريط المتحرك فوراً.
              isFeatured: true,
            ),
          ) ??
          false;
    }
    if (!mounted) return;
    if (!ok) {
      if (uploaded.isNotEmpty) {
        unawaited(SupabaseService.instance.deleteImage(uploaded));
      }
      final why = SupabaseService.instance.lastAdminError.trim();
      await _showOutcome(
        ok: false,
        title: 'تعذر التحويل إلى طبيب',
        message:
            '${why.isEmpty ? 'لم يردّ الخادم بسبب محدد.' : why}'
            '\n\nلم يُنشأ ملف طبيب ولم يتغيّر الحساب.',
      );
      return;
    }

    // ★ الاسم يُكتب في ملف الطبيب **وفي الملف الشخصي** معاً: كان
    //   يُحفظ في `doctors` وحده، فيبقى على «حسابي» اسم الحساب القديم
    //   رغم أن اسم الطبيب في الدليل تغيّر. والصورة الجديدة (إن اختارها
    //   الأدمن) تصل إلى `users.avatar_url` مثل باقي تحويلات الحساب،
    //   فيظهر التغيير في الملف الشخصي بلا إعادة تسجيل دخول.
    final profileOk =
        await _runBusy(
          'جارٍ مزامنة اسم الحساب…',
          () => SupabaseService.instance.updateUser(phone, {
            'name': name,
            if (uploaded.isNotEmpty) 'avatar_url': uploaded,
          }),
        ) ??
        false;
    await DoctorDirectoryService.instance.refreshNow();
    // ★ «نفس المتجر»: صيدليته المخفية (أُعيد زبوناً سابقاً) تعود للظهور
    //   بنفس المعرّف والمنتجات — لا تُنشأ صيدلية جديدة ولا يُمسح شيء.
    var shopRestored = false;
    final linkedShop = await SupabaseService.instance.fetchShopByOwnerPhone(
      phone,
    );
    if (linkedShop != null && linkedShop['is_active'] == false) {
      shopRestored = await SupabaseService.instance.updateShop(
        linkedShop['id'].toString(),
        {'is_active': true},
      );
      if (shopRestored) _publishShop();
    }
    // ★ نقرأ القائمة من جديد: الحالة المعروضة في الرسالة هي التي
    //   في القاعدة فعلاً، لا مجرد الخبر الذي أرسلناه.
    await _runBusy('جارٍ تحديث القائمة…', _load);
    if (!mounted) return;

    final role = _clinicRoles[_last10(phone)];
    final buffer = StringBuffer(
      existing != null
          ? 'تم تحديث ملف الطبيب: $name'
          : 'تم تحويل الحساب إلى طبيب: $name',
    );
    if (wasHidden) {
      buffer.write(
        '\nأُعيد ملف الطبيب المخفي للظهور بنفس الاسم والمعلومات والمحفظة.',
      );
    }
    if (shopRestored) {
      buffer.write('\nوعادت صيدليته للظهور بنفس المنتجات والبيانات.');
    }
    buffer.write('\nالحالة الآن: ${role ?? 'طبيب'}');
    if (role == null) {
      buffer.write(
        '\nملف الطبيب محفوظ في الدليل، لكنه لم يظهر بعد في هذه القائمة — '
        'اسحب القائمة للتحديث.',
      );
    }
    if (!profileOk) {
      buffer.write(
        '\n\nملاحظة: اسم الحساب في «حسابي» لم يتغيّر لأن صلاحيات القاعدة '
        'رفضت تعديله — غيّره من زر القلم.',
      );
    }
    await _showOutcome(
      ok: true,
      title: existing != null ? 'تم تحديث ملف الطبيب' : 'تم التحويل إلى طبيب',
      message: buffer.toString(),
    );
  }

  /// ★ «إرجاع إلى زبون» بعد التحويل إلى طبيب — إخفاء لا حذف.
  ///
  ///   يُخفي ملف الطبيب من الدليل وشريط الأطباء وواجهة العيادة
  ///   (`doctors.is_active=false` — الدوال العامة تُفلتر به)، ويُخفي
  ///   صيدليته إن وُجدت، ويزيل صفة صاحب الصيدلية. الصفوف والاسم والدوام
  ///   والمواعيد ودفتر المحفظة والمنتجات تبقى في القاعدة، فتعود كما هي
  ///   عند التحويل إلى طبيب أو صاحب صيدلية من جديد.
  Future<void> _revertToCustomer(Map<String, dynamic> user) async {
    final doctor = _doctorRowFor(user, requireActive: true);
    if (doctor == null) {
      await _showOutcome(
        ok: false,
        title: 'لا يوجد ملف طبيب نشط',
        message: 'هذا الحساب ليس طبيباً في الدليل الآن.',
      );
      return;
    }
    final phone = user['phone']?.toString() ?? '';
    final name = AccountName.real(name: user['name'], phone: user['phone']);
    final doctorName = doctor['name']?.toString().trim() ?? name;
    final shop = await SupabaseService.instance.fetchShopByOwnerPhone(phone);
    if (!mounted) return;
    final shopName = shop?['name']?.toString() ?? '';
    final canHideShop = shop != null && shop.containsKey('is_active');
    final shopWasVisible = shop != null && shop['is_active'] != false;

    final lines = StringBuffer()
      ..writeln('الحالة الحالية: ${_roleLabel(user)}')
      ..writeln()
      ..write(
        'سيُخفى ملف الطبيب «$doctorName» من دليل الأطباء وشريط الأطباء، '
        'وتصبح واجهة العيادة موقوفة له. ',
      );
    if (shopWasVisible) {
      lines.write(
        'وتُخفى صيدليته ${shopName.isEmpty ? '' : '«$shopName» '}من الرئيسية. ',
      );
    }
    if (user['is_shop_owner'] == true) {
      lines.write('ويُزال دور صاحب الصيدلية فيصبح زبوناً عادياً. ');
    }
    lines.write(
      'لا يُحذف شيء: الاسم والمعلومات والمنتجات والمواعيد والمحفظة '
      'تبقى وتعود كما هي عند التحويل إلى طبيب من جديد.',
    );

    if (!await _askConfirm('إرجاع إلى زبون', lines.toString())) return;
    if (!mounted) return;

    final doctorHidden =
        await _runBusy(
          'جارٍ إخفاء ملف الطبيب…',
          () => SupabaseService.instance.updateDoctor(doctor['id'].toString(), {
            'is_active': false,
          }),
        ) ??
        false;
    if (!mounted) return;
    if (!doctorHidden) {
      await _showOutcome(
        ok: false,
        title: 'تعذر الإخفاء',
        message:
            '${SupabaseService.instance.lastAdminError.trim()}\n\n'
            'لم يتغيّر شيء.',
      );
      return;
    }

    var shopHidden = true;
    String? shopProblem;
    if (shopWasVisible) {
      if (canHideShop) {
        shopHidden =
            await _runBusy(
              'جارٍ إخفاء الصيدلية…',
              () => SupabaseService.instance.updateShop(shop['id'].toString(), {
                'is_active': false,
              }),
            ) ??
            false;
        if (shopHidden) {
          _publishShop();
        } else {
          shopProblem = SupabaseService.instance.lastAdminError.trim();
        }
      } else {
        shopHidden = false;
        shopProblem =
            'عمود الإخفاء غير موجود بعد — شغّل tmp/shop_visibility.sql.';
      }
    }

    var ownerRemoved = true;
    if (user['is_shop_owner'] == true) {
      final res = await _runBusy(
        'جارٍ إرجاع الحساب إلى زبون…',
        () => SupabaseService.instance.adminSetUserRole(
          phone,
          isShopOwner: false,
        ),
      );
      ownerRemoved = res != null && res['ok'] == true;
    }
    if (!mounted) return;

    await DoctorDirectoryService.instance.refreshNow();
    await _runBusy('جارٍ تحديث القائمة…', _load);
    if (!mounted) return;

    final buffer = StringBuffer('$name\nالحالة الآن: زبون عادي')
      ..write(
        '\nأُخفي ملف الطبيب «$doctorName» — الاسم والدوام والمواعيد '
        'والمحفظة محفوظة.',
      );
    if (shopWasVisible) {
      buffer.write(
        shopHidden
            ? '\nأُخفيت الصيدلية ${shopName.isEmpty ? '' : '«$shopName» '}'
                  'عن الزبائن، ومنتجاتها ومحفظتها محفوظة.'
            : '\nبقيت الصيدلية ظاهرة: ${shopProblem ?? 'تعذر الإخفاء'}.',
      );
    }
    if (!ownerRemoved) {
      buffer.write('\nتعذر إزالة دور صاحب الصيدلية — أعد المحاولة.');
    }
    await _showOutcome(
      ok: true,
      title: 'تم الإرجاع إلى زبون',
      message: buffer.toString(),
    );
  }

  /// ★ تغيير اسم الحساب من لوحة الأدمن.
  ///
  ///   يُكتب في `users.name` مباشرة (عمود غير محميّ)، فيلتقطه
  ///   `AuthService.refreshFromServer` في دورته القادمة ويُحدِّث بطاقة
  ///   الملف الشخصي دون إعادة تشغيل.
  Future<void> _renameUser(Map<String, dynamic> user) async {
    final phone = user['phone']?.toString() ?? '';
    if (phone.isEmpty) {
      _showMessage('رقم الحساب فارغ', false);
      return;
    }
    final ctrl = TextEditingController(text: user['name']?.toString() ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تغيير الاسم',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textAlign: TextAlign.right,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          decoration: const InputDecoration(
            labelText: 'الاسم الذي يظهر في الملف الشخصي',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(
              'حفظ',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final trimmed = name?.trim() ?? '';
    if (!mounted || trimmed.isEmpty) return;
    final ok = await SupabaseService.instance.updateUser(phone, {
      'name': trimmed,
    });
    if (!mounted) return;
    _showMessage(ok ? 'تم تغيير الاسم إلى: $trimmed' : 'تعذر تغيير الاسم', ok);
    if (ok) _load();
  }

  /// يختار الأدمن صورة شخصية للحساب (اختياري) ويرفعها للسيرفر.
  ///
  /// تُخزَّن في `users.avatar_url` ⇒ تظهر في الملف الشخصي فوراً وعلى كل
  /// الأجهزة، وتُستعمل أيضاً كصورة الصيدلية.
  /// يعيد null إذا تخطّى الأدمن الاختيار.
  Future<String?> _askAvatar(
    String currentUrl, {
    String folder = 'avatars',
  }) async {
    if (!mounted) return null;
    String? picked;
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'صورة الحساب (اختياري)',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // معاينة الصورة المختارة (أو الحالية).
              Builder(
                builder: (context) => ClipOval(
                  child: AppImage(
                    picked ?? currentUrl,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 96,
                      height: 96,
                      color: AppColors.iconContainer,
                      child: const Icon(
                        Icons.person_rounded,
                        size: 44,
                        color: AppColors.textHint,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        setLocal(() => busy = true);
                        // ★ `profile` بدل تمرير الأرقام: يزيل الضغط
                        //   المزدوج (كان الالتقاط q78 ثم نضغط q78 ثانية).
                        final file = await LocalImageStore.instance.pickImage(
                          profile: ImageProfile.avatar,
                        );
                        if (!ctx.mounted) return;
                        if (file == null) {
                          final fail =
                              LocalImageStore.instance.lastPickerFailure;
                          setLocal(() => busy = false);
                          if (fail.isNotEmpty) {
                            ScaffoldMessenger.of(
                              ctx,
                            ).showSnackBar(SnackBar(content: Text(fail)));
                          }
                          return;
                        }
                        final url = await LocalImageStore.instance.uploadPicked(
                          file,
                          folder: folder,
                          profile: ImageProfile.avatar,
                        );
                        if (!ctx.mounted) return;
                        if (url == null) {
                          setLocal(() => busy = false);
                          final fail =
                              LocalImageStore.instance.lastUploadFailure;
                          if (fail.isNotEmpty) {
                            ScaffoldMessenger.of(
                              ctx,
                            ).showSnackBar(SnackBar(content: Text(fail)));
                          }
                          return;
                        }
                        setLocal(() {
                          picked = url;
                          busy = false;
                        });
                      },
                icon: const Icon(Icons.photo_camera_rounded, size: 18),
                label: Text(
                  'اختيار صورة',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('تخطّي', style: GoogleFonts.cairo()),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: Text(
                'حفظ',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );

    return picked;
  }

  /// يسأل الأدمن عن اسم الصيدلية (افتراضياً اسم الحساب + «صيدلية»)،
  /// ومعه زر «نقل إلى قسم» لاختيار القسم الذي يُربط به الصيدلية.
  ///
  /// ★ لماذا الزر: الصيدلية المنشأ هنا كان يبقى `category_id = null`
  ///   («بلا قسم») فلا يظهر في أي قسم ولا منتجاته ضمن قسم. الربط هنا
  ///   يوفر خطوة `admin_shops → أيقونة القسم` بعد كل تحويل.
  ///
  /// يعيد `(الاسم, معرّف القسم)` — والمعرّف `null` = بلا قسم.
  Future<({String name, String? categoryId})?> _askShopDetails(
    String userName,
  ) async {
    final ctrl = TextEditingController(
      text: userName.isEmpty ? 'اطباء ذي قار' : 'صيدلية $userName',
    );
    final active = _categories.where((c) => c['is_active'] != false).toList();
    var categoryId = <String?>[];
    var categoryName = <String?>[null];

    final result = await showDialog<({String name, String? categoryId})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'اسم الصيدلية',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (v) => Navigator.pop(ctx, (
                  name: v.trim(),
                  categoryId: categoryId.last,
                )),
                decoration: const InputDecoration(
                  labelText: 'الاسم الذي يظهر للزبائن',
                ),
              ),
              const SizedBox(height: 14),
              // ★ زر نقل الصيدلية إلى قسم: يعرض القسم المختار أو «بلا قسم».
              OutlinedButton.icon(
                onPressed: active.isEmpty
                    ? null
                    : () async {
                        final picked = await _askCategory(active);
                        if (picked == null || !ctx.mounted) return;
                        setDlgState(() {
                          categoryId = [picked.id];
                          categoryName = [picked.name];
                        });
                      },
                icon: const Icon(Icons.category_rounded, size: 20),
                label: Text(
                  categoryName.last ?? 'نقل إلى قسم (بلا قسم)',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: categoryName.last == null
                      ? AppColors.primary
                      : AppColors.brandDark,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              if (active.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'لا توجد أقسام: أنشئ قسماً من «إدارة الأقسام» أولاً.',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      color: AppColors.textHint,
                    ),
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
              onPressed: () => Navigator.pop(ctx, (
                name: ctrl.text.trim(),
                categoryId: categoryId.last,
              )),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result == null) return null;
    if (result.name.isEmpty) return null;
    return result;
  }

  /// نافذة اختيار القسم: `(المعرّف، الاسم)` أو `null` عند الإلغاء.
  /// اختيار «بلا قسم» يُعيد `id = null`.
  Future<({String? id, String name})?> _askCategory(
    List<Map<String, dynamic>> active,
  ) async {
    return showDialog<({String? id, String name})>(
      context: context,
      builder: (ctx) => SimpleDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'نقل الصيدلية إلى قسم',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, (id: null, name: 'بلا قسم')),
            child: Text(
              'بلا قسم',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(height: 1),
          for (final c in active)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (
                id: c['id']?.toString(),
                name: c['name_ar']?.toString() ?? 'قسم',
              )),
              child: Row(
                children: [
                  Icon(
                    Icons.category_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c['name_ar']?.toString() ?? 'قسم',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleActive(Map<String, dynamic> user, bool toActive) async {
    final name = AccountName.real(name: user['name'], phone: user['phone']);
    await _setRole(
      user,
      isActive: toActive,
      confirmTitle: toActive ? 'تفعيل الحساب' : 'تعطيل الحساب',
      confirmMessage: toActive
          ? 'سيستعيد $name القدرة على الدخول والتطبيق.'
          : 'سيُمنع $name من الدخول والتطبيق فوراً،'
                ' حتى لو كان داخل التطبيق الآن.',
      successMsg: toActive ? 'تم تفعيل الحساب' : 'تم تعطيل الحساب فوراً',
    );
  }

  /// ★ الحذف لم يعد طلباً مباشراً من المتصفح: صار يمرّ عبر
  ///   `admin_delete_user` على القاعدة، وهو يرفض أي طلب لا يحمل
  ///   كلمة مرور أدمن صحيحة. لذلك نطلبها هنا ونؤكد أولاً.
  ///
  /// ★ الثقة بالأدمن: تُكتب مرة واحدة لكل فتح للتطبيق — إن كانت
  ///   محفوظة في الجلسة (AdminPasswordSession) تُعاد مباشرة بلا نافذة.
  ///   ذاكرة فقط، لا قرص؛ وتضيع بإغلاق التطبيق.
  Future<String?> _askAdminPassword(String action) async {
    final remembered = AdminPasswordSession.cached;
    if (remembered != null && remembered.isNotEmpty) return remembered;

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
            child: Text('متابعة', style: GoogleFonts.cairo()),
          ),
        ],
      ),
    );
    ctrl.dispose();
    // ★ نحفظها في الذاكرة فقط — لهذه الجلسة، وتضيع بالإغلاق.
    final typed = pw?.trim() ?? '';
    if (typed.isNotEmpty) AdminPasswordSession.remember(typed);
    return pw;
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف المستخدم',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل أنت متأكد من حذف '
          '${AccountName.real(name: user['name'], phone: user['phone'])}؟',
          style: GoogleFonts.cairo(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'حذف نهائي',
              style: GoogleFonts.cairo(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final pw = await _askAdminPassword('حذف المستخدم نهائياً');
    if (pw == null || pw.isEmpty || !mounted) return;

    final ok = await SupabaseService.instance.deleteUser(
      user['phone'].toString(),
      adminPassword: pw,
    );
    if (!mounted) return;
    _showMessage(
      ok ? 'تم حذف المستخدم' : 'تعذر الحذف — تحقق من كلمة مرور الأدمن',
      ok,
    );
    if (ok) _load();
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

  String _roleLabel(Map<String, dynamic> user) {
    if (user['is_admin'] == true) return 'أدمن';
    if (user['is_shop_owner'] == true) return 'صاحب صيدلية';
    // ★ صفة العيادة تُقرأ من جدول الأطباء: التحويل إلى طبيب لا يغيّر
    //   أي عمود في `users`، فبدونها يظهر «عميل».
    final clinic = _clinicRoleFor(user);
    if (clinic != null) return clinic;
    if (user['is_driver'] == true) return 'مندوب';
    return 'عميل';
  }

  Color _roleColor(Map<String, dynamic> user) {
    if (user['is_admin'] == true) return AppColors.danger;
    if (user['is_shop_owner'] == true) return AppColors.warning;
    final clinic = _clinicRoleFor(user);
    if (clinic == 'طبيب') return AppColors.primary;
    if (clinic == 'سكرتير عيادة') return AppColors.accentDeep;
    if (user['is_driver'] == true) return AppColors.info;
    return AppColors.textSecondary;
  }

  IconData _roleIcon(Map<String, dynamic> user) {
    if (user['is_admin'] == true) return Icons.admin_panel_settings_rounded;
    if (user['is_shop_owner'] == true) return Icons.storefront_rounded;
    final clinic = _clinicRoleFor(user);
    if (clinic == 'طبيب') return Icons.medical_services_rounded;
    if (clinic == 'سكرتير عيادة') return Icons.badge_rounded;
    if (user['is_driver'] == true) return Icons.delivery_dining_rounded;
    return Icons.person_rounded;
  }

  /// ★ حقل البحث الفوري — أعلى القائمة، بلا لون خلفه غير لون الصفحة.
  Widget _buildSearchBar() {
    OutlineInputBorder edge(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      child: TextField(
        controller: _searchCtrl,
        textAlign: TextAlign.right,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _query = v.trim()),
        style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          hintText: 'ابحث بالاسم أو رقم الهاتف…',
          hintStyle: GoogleFonts.cairo(color: AppColors.textHint, fontSize: 13),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 20,
            color: AppColors.primary,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: _clearSearch,
                  tooltip: 'حذف البحث',
                ),
          isDense: true,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
          border: edge(AppColors.divider),
          enabledBorder: edge(AppColors.divider),
          focusedBorder: edge(AppColors.primary),
        ),
      ),
    );
  }

  /// عدّاد النتيجة: لا يُعرض إلا أثناء البحث، حتى يعرف الأدمن كم بقي له.
  Widget _buildResultLine() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
      child: Text(
        '${_visible.length} من ${_users.length}',
        style: GoogleFonts.cairo(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_users.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Icon(
            Icons.people_outline_rounded,
            size: 64,
            color: AppColors.textHint,
          ),
          SizedBox(height: 12),
          Center(child: Text('لا يوجد مستخدمون')),
        ],
      );
    }
    final shown = _visible;
    if (shown.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 96),
          const Icon(
            Icons.person_search_rounded,
            size: 56,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              'لا نتيجة لـ «$_query»',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              'اكتب جزءاً من الاسم أو رقماً كاملاً أو جزءاً منه',
              style: GoogleFonts.cairo(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: shown.length,
      itemBuilder: (_, i) {
        final u = shown[i];
        return _UserTile(
          user: u,
          roleLabel: _roleLabel(u),
          roleColor: _roleColor(u),
          roleIcon: _roleIcon(u),
          isDoctor: _clinicRoleFor(u) == 'طبيب',
          hasHiddenDoctor: _hiddenDoctorPhones.contains(
            _last10(u['phone']?.toString() ?? ''),
          ),
          onToggleDriver: (toDriver) => _toggleDriver(u, toDriver),
          onToggleShopOwner: (toOwner) => _toggleShopOwner(u, toOwner),
          onToDoctor: () => _toDoctor(u),
          onRevertToCustomer: () => _revertToCustomer(u),
          onToggleActive: (toActive) => _toggleActive(u, toActive),
          onRename: () => _renameUser(u),
          onDelete: () => _deleteUser(u),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'إدارة المستخدمين',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: TapToDismissKeyboard(
        child: AppRefreshIndicator(
          color: AppColors.primary,
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _buildSearchBar(),
                    if (_query.isNotEmpty) _buildResultLine(),
                    Expanded(child: _buildList()),
                  ],
                ),
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.roleLabel,
    required this.roleColor,
    required this.roleIcon,
    required this.isDoctor,
    required this.hasHiddenDoctor,
    required this.onToggleDriver,
    required this.onToggleShopOwner,
    required this.onToDoctor,
    required this.onRevertToCustomer,
    required this.onToggleActive,
    required this.onRename,
    required this.onDelete,
  });

  final Map<String, dynamic> user;
  final String roleLabel;
  final Color roleColor;
  final IconData roleIcon;
  final bool isDoctor;
  final bool hasHiddenDoctor;
  final void Function(bool toDriver) onToggleDriver;
  final void Function(bool toOwner) onToggleShopOwner;
  final VoidCallback onToDoctor;
  final VoidCallback onRevertToCustomer;
  final void Function(bool toActive) onToggleActive;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final name = AccountName.real(name: user['name'], phone: user['phone']);
    final phone = user['phone']?.toString() ?? '';
    final isDriver = user['is_driver'] == true;
    final isAdmin = user['is_admin'] == true;
    final isShopOwner = user['is_shop_owner'] == true;
    final isActive = user['is_active'] != false;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: roleColor.withValues(alpha: 0.12),
                  child: Icon(roleIcon, color: roleColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      // ★ بلا لقب عام: إن لم يكن لهذا الحساب اسم حقيقي
                      //   يُعرض رقمه في الأعلى، فلا تُكرَّر السطران.
                      if (phone.isNotEmpty && phone != name)
                        Text(
                          phone,
                          textAlign: TextAlign.right,
                          style: GoogleFonts.cairo(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: roleColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        roleLabel,
                        style: GoogleFonts.cairo(
                          color: roleColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isActive
                              ? Icons.verified_rounded
                              : Icons.block_rounded,
                          color: isActive
                              ? AppColors.success
                              : AppColors.danger,
                          size: 14,
                        ),
                        Text(
                          isActive ? 'مفعّل' : 'معطّل',
                          style: GoogleFonts.cairo(
                            color: isActive
                                ? AppColors.success
                                : AppColors.danger,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            if (!isAdmin) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => onToggleDriver(!isDriver),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDriver
                            ? AppColors.danger
                            : AppColors.info,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: Icon(
                        isDriver
                            ? Icons.undo_rounded
                            : Icons.delivery_dining_rounded,
                        size: 17,
                      ),
                      label: Text(
                        isDriver ? 'إلغاء المندوبية' : 'تعيين مندوب',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => onToggleShopOwner(!isShopOwner),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isShopOwner
                            ? AppColors.danger
                            : AppColors.warning,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: Icon(
                        isShopOwner
                            ? Icons.store_mall_directory_outlined
                            : Icons.storefront_rounded,
                        size: 17,
                      ),
                      label: Text(
                        isShopOwner ? 'إلغاء الصيدلية' : 'صاحب صيدلية',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // ★ تحويل إلى طبيب: ملف دليل برقم الحساب نفسه، بصورة
              //   ودوام يختارهما الأدمن ويظهران في البروفايل للجميع.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onToDoctor,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.medical_services_outlined, size: 17),
                  label: Text(
                    isDoctor ? 'تعديل ملف الطبيب' : 'تحويل إلى طبيب',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              // ★ إرجاع الطبيب زبوناً عادياً: يخفي ملفه واسمه من الدليل
              //   وصيدليته من الرئيسية — بلا حذف، فيعود كما هو لاحقاً.
              if (isDoctor) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onRevertToCustomer,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.visibility_off_outlined, size: 17),
                    label: Text(
                      'إرجاع إلى زبون (إخفاء من الدليل)',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
              // ★ ملف طبيب مخفي: اسمه ومحفظته ومواعيده في القاعدة،
              //   ويعود للظهور بالتحويل إلى طبيب.
              if (hasHiddenDoctor && !isDoctor) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.visibility_off_rounded,
                      size: 15,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'ملف طبيب مخفي — بياناته ومحفظته محفوظة، ويعود بالتحويل إلى طبيب.',
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
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => onToggleActive(!isActive),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isActive
                            ? AppColors.danger
                            : AppColors.success,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: Icon(
                        isActive
                            ? Icons.block_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 17,
                      ),
                      label: Text(
                        isActive ? 'تعطيل الحساب' : 'تفعيل الحساب',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // ★ تغيير الاسم: يُحدَّث في الملف الشخصي للزبون
                  //   خلال دورة المزامنة القادمة، بلا إعادة دخول.
                  IconButton(
                    onPressed: onRename,
                    tooltip: 'تغيير الاسم',
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.primary.withValues(
                        alpha: 0.10,
                      ),
                    ),
                    icon: const Icon(
                      Icons.edit_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                  ),
                  IconButton(
                    onPressed: onDelete,
                    tooltip: 'حذف المستخدم',
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.danger.withValues(alpha: 0.10),
                    ),
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
