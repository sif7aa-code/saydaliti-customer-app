import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/privacy_policy.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/currency_formatter.dart';
import '../services/auth_service.dart';
import '../services/device_sound.dart';
import '../services/doctor_service.dart';
import '../services/local_image_store.dart';
import '../services/location_service.dart';
import '../services/notification_channel_settings.dart';
import '../services/notification_sound.dart';
import '../services/push_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/provider_application_notice.dart';
import 'login_screen.dart';
import 'notification_sound_screen.dart';
import 'register_screen.dart';
import 'doctor_availability_screen.dart';
import 'doctor_wallet_screen.dart';
import 'order_history_screen.dart';
import 'secretary_appointments_screen.dart';
import 'wallet_screen.dart';

/// ألوان صفحة «حسابي» — خاصة بهذا الملف حتى يبقى ترتيب الصفحة وألوانها
/// مطابقين للمرجع دون المساس بأي شاشة أخرى أو بـ`AppColors`.
const Color _navy = AppColors.textPrimary;
const Color _blue = AppColors.primary;
const Color _cardBorder = AppColors.divider;
const Color _gold = AppColors.accent;
const Color _goldDeep = AppColors.accentDeep;

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, this.isGuest = false});

  final bool isGuest;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen>
    with TabRefreshTarget<AccountScreen> {
  @override
  String get tabId => 'account';

  /// ★ نقرة زرّ «حسابي»: تصعد لأعلى الصفحة وتعيد جلب الرصيد الحقيقي
  ///   من الخادم — نفس عمل السحب للتحديث.
  @override
  Future<void> Function() onTabRefresh() => _onRefresh;

  /// ★ نظام «خصوماتي» (دورة ٣ طلبات) وعجلة الحظ أُزيلا بطلب الأدمن
  ///   (2026-11-18): لا قسم «عروضي» هنا، ولا جلب لحالة القفل أو العجلة.

  /// قيم افتراضية تُستعمل فقط إن لم يوجد حساب مسجّل دخول.
  final String _userName = 'مستخدم اطباء ذي قار';
  final String _userPhone = '';
  final String _userAvatarUrl = '';

  bool _uploadingAvatar = false;

  /// مفتاح بطاقة رصيد صاحب الصيدلية (للسحب للتحديث).
  final GlobalKey<_OwnerBalanceCardState> _balanceKey =
      GlobalKey<_OwnerBalanceCardState>();

  /// ★ دور العيادة لهذا الحساب: طبيب أو سكرتير عيادة (بلا استطلاع دوري؛
  ///   يُقرأ عند فتح «حسابي» وعند السحب للتحديث). `null` يعني حساباً
  ///   عادياً فلا يُعرض قسم «العيادة».
  DoctorRoleContext? _clinic;
  bool _clinicLoading = false;

  /// يُزاد عند السحب/لمس التبويب فيعيد جلب حالة طلب الانضمام.
  int _noticeTick = 0;

  /// رقم الحساب الذي قرأنا دور عيادته — يمنع قراءة مكررة ويلتقط
  /// الدخول بعد إنشاء الشاشة (الشاشة نفسها تُبنى للزائر ثم للمسجّل).
  String? _clinicPhone;

  @override
  void initState() {
    super.initState();
    _loadClinic();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      _clinic = null;
      _clinicPhone = null;
      return;
    }
    if (phone != _clinicPhone) _loadClinic();
  }

  Future<void> _loadClinic() async {
    if (_clinicLoading) return;
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) return;
    _clinicLoading = true;
    _clinicPhone = phone;
    final role = await DoctorService.instance.myRoles();
    _clinicLoading = false;
    if (!mounted) return;
    setState(() => _clinic = role);
  }

  /// موقع هذا الحساب: يُحدَّد بدقة عالية ويُحفظ باسم الحساب وحده
  /// (لا تختلط المواقع بين المستخدمين على نفس الجهاز).
  Future<void> _showMyLocation() async {
    if (!mounted) return;
    _toast('جارٍ تحديد موقعك بدقة…', null);
    // ★ overridePin: هذا الزر وعدٌ بالتحديد الآن لا باسترجاع اختيار
    //   سابق؛ لو تُرك الدبوس يعطّله لضغط المستخدم «موقعي» فحصل على
    //   العنوان القديم بلا أي GPS جديد، ثم يظنّ أن التطبيق كذب.
    final result = await LocationService.instance.determinePosition(
      overridePin: true,
    );
    if (!mounted) return;
    setState(() {});
    if (result.isAutoDetected) {
      _toast('تم تحديد موقعك: ${result.address}', true);
    } else {
      _toast(result.errorMessage ?? 'تعذّر تحديد الموقع', false);
    }
  }

  /// يعرض حالة الإشعارات: خدمة الإشعارات والأصوات.
  Future<void> _showPushInfo() async {
    await PushService.instance.init();
    await NotificationSound.instance.load();
    // نغمة الإشعار التي اختارها المستخدم في إعدادات الهاتف.
    await NotificationChannelSettings.instance.init();
    // نغمة أصوات الهاتف المحفوظة على هذا الجهاز.
    await DeviceSound.load();
    final supported = PushService.isSupported;
    final ready = PushService.instance.isReady;
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'إشعارات التطبيق',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('خدمة الإشعارات', ready ? 'مُفعّلة' : 'غير مفعّلة', ready),
                _kv(
                  'الإذن',
                  supported ? 'مطلوب من النظام' : 'غير مدعوم',
                  supported,
                ),
                _kv(
                  'صوت التنبيه',
                  NotificationSound.instance.enabled ? 'مُفعّل' : 'مكتوم',
                  NotificationSound.instance.enabled,
                ),
                const Divider(height: 22),
                Text(
                  'صوت التنبيه',
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'صوت واحد لكل الإشعارات: جرس آيفون — طلب جديد، قبول، رفض، '
                  'توصيل، تغيير سعر، حجز.',
                  style: GoogleFonts.cairo(
                    fontSize: 11,
                    height: 1.6,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: NotificationSound.instance.enabled,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.primary,
                  title: Text(
                    'تشغيل الأصوات',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onChanged: (v) async {
                    await NotificationSound.instance.setEnabled(v);
                    if (!ctx.mounted) return;
                    setDlgState(() {});
                    if (v) {
                      await NotificationSound.instance.preview(
                        NotifySound.alert,
                      );
                    }
                  },
                ),
                ActionChip(
                  label: Text(
                    'معاينة الجرس',
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      NotificationSound.instance.preview(NotifySound.alert),
                ),
                const SizedBox(height: 10),

                // ══ نغمة الإشعار من إعدادات الهاتف ══
                // نقرأ النغمة التي اختارها المستخدم في إعدادات النظام
                // ونحفظها هنا، ونفتح له الصفحة لتغييرها.
                if (NotificationChannelSettings.instance.followSystem)
                  _phoneSoundRow(ctx, setDlgState),
                const SizedBox(height: 6),
                SwitchListTile(
                  value: NotificationChannelSettings.instance.followSystem,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.primary,
                  title: Text(
                    'اعتماد نغمة إعدادات الهاتف',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'أطفئه لسماع نغمة التطبيق الخاصة بدل نغمة إعدادات الهاتف.',
                    style: GoogleFonts.cairo(fontSize: 10.5),
                  ),
                  onChanged: (v) async {
                    await NotificationChannelSettings.instance.setFollowSystem(
                      v,
                    );
                    if (!ctx.mounted) return;
                    setDlgState(() {});
                    if (!v) {
                      await NotificationSound.instance.preview(
                        NotifySound.accepted,
                      );
                    }
                  },
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إغلاق', style: GoogleFonts.cairo()),
            ),
          ],
        ),
      ),
    );
  }

  /// صف «نغمة الإشعار من إعدادات الهاتف»: يعرض ما اختاره المستخدم،
  /// ويفتح له إعدادات النظام لتغييره، ويعيد القراءة بعد العودة.
  Widget _phoneSoundRow(BuildContext ctx, StateSetter setDlgState) {
    final svc = NotificationChannelSettings.instance;
    // أهم قناة: تنبيه عام + طلب جديد ⇒ نفحصهما ونعرض الأول المخصّص.
    const watched = [
      NotificationChannelSettings.alert,
      NotificationChannelSettings.newOrder,
      NotificationChannelSettings.delivered,
    ];
    final current = watched
        .map(svc.displayName)
        .firstWhere((n) => n != 'نغمة النظام', orElse: () => 'نغمة النظام');
    final customised = watched.any(svc.isCustomised);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                customised
                    ? Icons.music_note_rounded
                    : Icons.phone_android_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'نغمة الإشعار (من إعدادات الهاتف)',
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            DeviceSound.hasCustom
                ? (DeviceSound.isSilent
                    ? 'نغمتك المختارة الآن: صامت — الإشعار يظهر بلا رنين.'
                    : 'نغمتك المختارة الآن: ${DeviceSound.label} — من أصوات هاتفك، محفوظة على هذا الجهاز وحده.')
                : customised
                    ? 'اخترتَ: $current — نحترم اختيارك كما هو.'
                    : 'لم تُغيِّر نغمة الإشعارات بعد، فالنغمة الافتراضية تُستخدم.',
            style: GoogleFonts.cairo(
              fontSize: 11,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () async {
                    await Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => const NotificationSoundScreen(),
                      ),
                    );
                    await DeviceSound.load();
                    if (!ctx.mounted) return;
                    setDlgState(() {});
                  },
                  icon: const Icon(Icons.library_music_rounded, size: 17),
                  label: Text(
                    DeviceSound.hasCustom ? 'تغيير النغمة' : 'أصوات الإشعارات',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await NotificationChannelSettings.instance
                        .openAppSettings();
                    // ننتظر عودة المستخدم ثم نقرأ اختياره الجديد.
                    await NotificationChannelSettings.instance
                        .reloadAfterSettings();
                    if (!ctx.mounted) return;
                    setDlgState(() {});
                  },
                  icon: const Icon(Icons.settings_suggest_rounded, size: 17),
                  label: Text(
                    'إعدادات النظام',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// مفتاح تشغيل/كتم أصوات الإشعارات داخل قائمة الإعدادات.
  Widget _soundToggle() {
    return FutureBuilder<void>(
      future: NotificationSound.instance.load(),
      builder: (context, _) {
        final on = NotificationSound.instance.enabled;
        return Switch(
          value: on,
          activeThumbColor: AppColors.primary,
          onChanged: (v) async {
            await NotificationSound.instance.setEnabled(v);
            if (v) {
              await NotificationSound.instance.preview(NotifySound.alert);
            }
            if (mounted) setState(() {});
          },
        );
      },
    );
  }

  /// فتح خدمة العملاء في واتساب الرسمي.
  Future<void> _openSupport() async {
    await ContactTools.openSupport(context);
  }

  void _logout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'تسجيل الخروج',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل أنت متأكد من تسجيل الخروج؟',
          style: GoogleFonts.cairo(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'إلغاء',
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await AuthService.instance.logout();
              // ★ بلا `pushAndRemoveUntil`: كان يُزيل **كل** المسارات
              //   بما فيها `home`، فيصير `LoginScreen` أول وآخر مسار.
              //   وعند نجاح الدخول يُنفَّذ `popUntil(isFirst)` فلا
              //   يُزيح شيئاً، ويبقى `LoginScreen` مساراً ثابتاً لا
              //   يُعاد بناؤه من `ListenableBuilder` ⇒ **لا يدخل
              //   التطبيق بعد الدخول حتى إعادة التشغيل**.
              //   يكفي `logout()` وحده: ينادي `notifyListeners`
              //   فيعود `home` ويعرض شاشة الدخول.
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'خروج',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  /// ★ كان الزر **مزيّناً فقط**: ينادي `logout()` وحده، فيبقى الحساب
  ///   في القاعدة حيّاً وتصله الإشعارات على أي جهاز آخر سجل فيه.
  ///   الآن ينادي `delete_own_account()` **قبل** أي خروج محلي — لأن
  ///   الدالة تقرأ الهوية من توكن الجلسة، فلو خرجنا أولاً لم يبقَ ما
  ///   يثبت من أنت.
  bool _deletingAccount = false;

  void _deleteAccount(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'حذف الحساب نهائياً',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w900,
                  color: AppColors.danger,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'سيُحذف حسابك وكل ما فيه نهائياً: سجل طلباتك ومفرداتها، '
          'ونقاطك ومكافآتك، وأكواد خصمك، وأجهزة الاستقبال المسجّلة — '
          'فلا يصلك إشعار بعد الآن.\n\n'
          'لا يمكن التراجع عن هذا الإجراء، ولا يمكنك التسجيل بحساب جديد '
          'بنفس الرقم قبل مرور ثلاث ساعات.',
          style: GoogleFonts.cairo(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'إلغاء',
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _performDeleteAccount();
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'حذف نهائي',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  /// التنفيذ الفعلي: انتظار → حذف في القاعدة → خروج محلي.
  ///
  /// `messenger` و`navigator` يُلتقطان **قبل** أول `await`: بعدها قد
  /// يُهجر هذا العنصر من الشجرة (لأن `accountDeletedLocally` يعيد بناء
  /// الواجهة إلى شاشة الدخول)، و`ScaffoldMessenger.of(context)` حينها
  /// يرمي ويترك الزر دوّاراً.
  Future<void> _performDeleteAccount() async {
    if (_deletingAccount) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);

    setState(() => _deletingAccount = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Row(
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'جارٍ حذف الحساب نهائياً…',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    Map<String, dynamic> result;
    try {
      result = await SupabaseService.instance.deleteOwnAccount();
    } catch (_) {
      result = const {
        'ok': false,
        'error': 'تعذّر الاتصال بالخادم — لم يُحذف شيء، أعد المحاولة',
      };
    }

    if (navigator.canPop()) navigator.pop();

    final ok =
        result['ok'] == true ||
        result['ok']?.toString().toLowerCase() == 'true';

    if (!ok) {
      final error = (result['error'] ?? result['message'] ?? 'تعذّر حذف الحساب')
          .toString();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              error,
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            backgroundColor: AppColors.danger,
          ),
        );
      if (mounted) setState(() => _deletingAccount = false);
      return;
    }

    // ★ الترتيب مقصود: الحساب زال من القاعدة، فالخروج المحلي الآن بلا
    //   جلسة ولا توكن محفوظ — و`accountDeletedLocally` تمسح الاثنين
    //   وتُسكت الاستطلاع ومركز الإشعارات.
    final orders =
        int.tryParse((result['orders_removed'] ?? '0').toString()) ?? 0;
    await AuthService.instance.accountDeletedLocally();

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            orders > 0
                ? 'تم حذف حسابك نهائياً مع $orders طلب من سجلاتك — '
                      'يمكنك التسجيل بحساب جديد بعد ٣ ساعات'
                : 'تم حذف حسابك نهائياً — يمكنك التسجيل بحساب جديد بعد ٣ ساعات',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          backgroundColor: AppColors.success,
        ),
      );
  }

  void _toast(String msg, [bool? ok]) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: ok == null ? 2 : 4),
          backgroundColor: ok == null
              ? AppColors.primary
              : (ok ? AppColors.success : AppColors.danger),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  Widget _kv(String label, String value, bool good) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            good ? Icons.check_circle_rounded : Icons.info_rounded,
            size: 16,
            color: good ? AppColors.success : AppColors.textHint,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: GoogleFonts.cairo(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onRefresh() async {
    // ★ السحب/زرّ «حسابي» يجلب الاسم والصفة من القاعدة الآن، فلا ينتظر
    //   المستخدم دورة المزامنة (٢٠ ثانية) ليرى تعديل الأدمن في ملفه.
    await AuthService.instance.refreshFromServer();
    final child = _balanceKey.currentState;
    if (child != null) await child.load();
    await _loadClinic();
    if (mounted) setState(() => _noticeTick++);
  }

  /// تعديل صورة الحساب: تُختار من المعرض، تُرفع للسيرفر، وتُحفظ في
  /// عمود avatar_url داخل حساب المستخدم (فيظهر لكل الأجهزة).
  Future<void> _editAvatar() async {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      _toast('سجّل الدخول أولاً لتعديل صورتك', false);
      return;
    }
    if (_uploadingAvatar) return;
    // ★ `profile` بدل تمرير الأرقام: يزيل الضغط المزدوج (كان الالتقاط
    //   يضغط q78 ثم نضغط q78 ثانية ⇒ جيلان من الفقد).
    final file = await LocalImageStore.instance.pickImage(
      profile: ImageProfile.avatar,
    );
    if (file == null) {
      final fail = LocalImageStore.instance.lastPickerFailure;
      if (fail.isNotEmpty) _toast(fail, false);
      return;
    }
    setState(() => _uploadingAvatar = true);
    final url = await LocalImageStore.instance.uploadPicked(
      file,
      folder: 'avatars',
      profile: ImageProfile.avatar,
    );
    if (!mounted) return;
    if (url == null) {
      setState(() => _uploadingAvatar = false);
      _toast(LocalImageStore.instance.lastUploadFailure, false);
      return;
    }
    final saved = await SupabaseService.instance.updateUser(phone, {
      'avatar_url': url,
    });
    if (!mounted) return;
    setState(() => _uploadingAvatar = false);
    if (!saved) {
      _toast('تم رفع الصورة لكن تعذر حفظها في حسابك', false);
      return;
    }
    await AuthService.instance.updateAvatar(url);
    if (!mounted) return;
    setState(() {});
    _toast('تم تحديث صورتك الشخصية', true);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isGuest) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('حسابي'),
          automaticallyImplyLeading: false,
        ),
        body: _GuestLoginView(
          onLogin: () {
            // ★ `push` عادي — **بلا** `pushAndRemoveUntil`: هذا يحفظ
            //   `home`، وعند نجاح الدخول يُزيحه `popUntil(isFirst)`
            //   فيعود `home` الذي يعرض واجهة الدور مباشرة.
            //   بإزالة `home` كان المستخدم يبقى على شاشة دخول
            //   جامدة ويتsockّل إلى إعادة تشغيل التطبيق.
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        automaticallyImplyLeading: false,
        elevation: 0,
        centerTitle: true,
        // بلا خيط فاصل: العنوان نفسه يحمل الخط الأخضر القصير أسفله.
        shape: const Border(),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'حسابي',
              style: GoogleFonts.cairo(
                color: _navy,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 5),
            Container(
              width: 46,
              height: 3,
              decoration: BoxDecoration(
                color: _blue,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
      // ★ تُبنى الصفحة كلها مع كل تغيّر حقيقي في الدور/الاسم/الصورة:
      //   الشاشة محفوظة في `IndexedStack` ولا تُعاد بناؤها وحدها، فحسابٌ
      //   أُلغيت صيدليته من لوحة الأدمن كان يبقى يرى «بطاقة الرصيد»
      //   (محفظة) حتى إعادة التشغيل — والزبون لا محفظة له إطلاقاً.
      //   `notifyListeners` لا يأتي إلا عند تغيّر فعلي، فلا إعادة رسم دورية.
      body: ListenableBuilder(
        listenable: AuthService.instance,
        builder: (context, _) => AppRefreshIndicator(
          color: AppColors.primary,
          onRefresh: _onRefresh,
          child: ListView(
            controller: tabScroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            const SizedBox(height: 8),

            // بروفايل: الهوية والدور فقط (نظام أكواد التوصيل
            // المجاني محذوف بالكامل من التطبيق).
            // ★ تُبنى مع كل إخطار من `AuthService`: تغيير الاسم أو
            //   الحالة أو الدور من لوحة الأدمن يصل عبر المزامنة الدورية،
            //   فتُحدَّث البطاقة هنا **بلا إعادة تشغيل** — الشاشة محفوظة
            //   في `IndexedStack` ولا تُبنى من تلقاء نفسها عند الإخطار.
            ListenableBuilder(
              listenable: AuthService.instance,
              builder: (context, _) => _LuxuryProfileCard(
                name: AuthService.instance.name ?? _userName,
                phone: AuthService.instance.phone ?? _userPhone,
                avatarUrl: AuthService.instance.avatarUrl ?? _userAvatarUrl,
                roleLabel: AuthService.instance.roleLabel,
                roleIcon: AuthService.instance.roleIcon,
                isCustomerOnly: !AuthService.instance.isDriver,
                onEditAvatar: _uploadingAvatar ? null : _editAvatar,
              ),
            ),
            // حالة طلب الانضمام كطبيب/صيدلاني: مرفوض مع السبب أو قيد
            // المراجعة. لا تظهر لحساب بلا طلب أو طلب معتمد.
            ProviderApplicationNotice(
              padding: const EdgeInsets.only(top: 10),
              reloadTick: _noticeTick,
            ),
            // ★ لم تعد هنا بطاقة «لوحة تحكم الأدمن» (2026-10-11): صارت
            //   اللوحة تطبيقاً منفصلاً (`صيدليتي أدمن`)، فلا دخول إليها من
            //   نسخة الزبائن ولا حتى كود لها في هذا الملف.
            // ★ قسم «عروضي» (خصوماتي + عجلة الحظ) أُزيل بطلب الأدمن
            //   2026-11-18: لا دورة ٣ طلبات ولا عجلة في التطبيق.

            // 3. قسم إدارة الحساب والأمان
            const _AccountSectionHeader(
              title: 'إدارة الحساب والأمان',
              icon: Icons.security_rounded,
            ),
            const SizedBox(height: 12),
            _SettingsGroup(
              items: [
                _SettingsItem(
                  icon: Icons.my_location_rounded,
                  title: 'موقعي الحالي',
                  subtitle: LocationService.instance.currentAddress,
                  color: AppColors.primary,
                  onTap: _showMyLocation,
                ),
                _SettingsItem(
                  icon: Icons.volume_up_rounded,
                  title: 'صوت تنبيه الإشعارات',
                  subtitle: 'نغمة عند كل إشعار (طلب جديد، قبول، رفض…)',
                  color: AppColors.success,
                  onTap: _showPushInfo,
                  trailing: _soundToggle(),
                ),
                _SettingsItem(
                  icon: Icons.notifications_active_outlined,
                  title: 'إشعارات التطبيق',
                  subtitle: 'الحالة والأصوات',
                  color: AppColors.accentDeep,
                  onTap: _showPushInfo,
                ),
                _SettingsItem(
                  icon: Icons.privacy_tip_outlined,
                  title: 'سياسة الخصوصية',
                  subtitle: 'ما البيانات التي نحفظها ولمن تُشارك',
                  color: AppColors.info,
                  onTap: () => PrivacyPolicy.showInApp(context),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 4. قسم النشاطات والخدمات
            const _AccountSectionHeader(
              title: 'النشاطات والخدمات',
              icon: Icons.apps_rounded,
            ),
            const SizedBox(height: 12),
            _SettingsGroup(
              items: [
                _SettingsItem(
                  icon: Icons.receipt_long_rounded,
                  title: 'سجل طلباتي',
                  subtitle: 'متابعة الطلبات السابقة والحالية',
                  color: AppColors.info,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OrderHistoryScreen(),
                      ),
                    );
                  },
                ),
                _SettingsItem(
                  icon: Icons.support_agent_rounded,
                  title: 'خدمة العملاء (واتساب)',
                  subtitle: 'تواصل مباشر مع فريق الدعم',
                  color: AppColors.primary,
                  onTap: _openSupport,
                ),
              ],
            ),

            // ★ قسم «العيادة» — يظهر للطبيب وسكرتير العيادة فقط، ودورهم
            //   يُقرأ من القاعدة (`doctors.phone` / `doctors.secretary_phone`).
            //   والدور الحيّ من `AuthService` شرطٌ إضافي: لا محفظة لزبون.
            if (AuthService.instance.canSeeWallet &&
                _clinic != null &&
                _clinic!.hasClinic) ...[
              const SizedBox(height: 20),
              const _AccountSectionHeader(
                title: 'العيادة',
                icon: Icons.local_hospital_outlined,
              ),
              const SizedBox(height: 12),
              _SettingsGroup(
                items: [
                  _SettingsItem(
                    icon: Icons.fact_check_outlined,
                    title: 'موافقات الحجوزات',
                    subtitle: _clinic!.pending > 0
                        ? '${_clinic!.pending} حجز بانتظار موافقتك'
                        : 'اعتمد أو ارفض حجوزات العيادة',
                    color: AppColors.primary,
                    trailing: _clinic!.pending > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.warning.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${_clinic!.pending}',
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                color: AppColors.accentDeep,
                              ),
                            ),
                          )
                        : null,
                    onTap: () {
                      Navigator.of(context)
                          .push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  const SecretaryAppointmentsScreen(),
                            ),
                          )
                          .then((_) => _loadClinic());
                    },
                  ),
                  // حجز الزبائن: نفس شاشة تبويب العيادة — تُفتح هنا أيضاً
                  // لحساب الأدمن المرتبط بطبيب، فلوحة العيادة لا تظهر له.
                  if (_clinic!.doctors.isNotEmpty)
                    _SettingsItem(
                      icon: Icons.toggle_on_rounded,
                      title: 'حجز الزبائن',
                      subtitle:
                          'زر تشغيل/إطفاء واحد — مفتوح: كل أيام الأسبوع',
                      color: AppColors.success,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DoctorAvailabilityScreen(),
                          ),
                        );
                      },
                    ),
                  // المحفظة للطبيب وسكرتير العيادة معاً: القيد واحد.
                  _SettingsItem(
                    icon: Icons.account_balance_wallet_outlined,
                    title: 'محفظة العيادة',
                    subtitle: 'الصافي بعد الاستقطاع الذي تحدده إدارة التطبيق',
                    color: AppColors.accentDeep,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DoctorWalletScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),

            // 5. إجراءات تسجيل الخروج وحذف الحساب
            _OutlinedAction(
              label: 'تسجيل الخروج',
              icon: Icons.logout_rounded,
              onTap: () => _logout(context),
            ),
            const SizedBox(height: 10),
            _DangerAction(
              label: 'حذف الحساب نهائياً',
              onTap: () => _deleteAccount(context),
            ),
            const SizedBox(height: 32),

            // بطاقة رصيد صاحب الصيدلية — أسفل الملف الشخصي، وتُعرض
            // لصاحب الصيدلية فقط (مشتريات الناس من صيدليته بالدينار العراقي).
            // `isShopOwner` من `AuthService` مباشرة: تُخفى فور تجريد الحساب.
            if (AuthService.instance.isShopOwner) ...[
              const _AccountSectionHeader(
                title: 'بطاقة رصيد الصيدلية',
                icon: Icons.account_balance_wallet_rounded,
              ),
              const SizedBox(height: 12),
              _OwnerBalanceCard(key: _balanceKey),
              const SizedBox(height: 32),
            ],
          ],
          ),
        ),
      ),
    );
  }
}

/// رأس قسم خاص بصفحة «حسابي»: أيقونة خضراء يمين العنوان، العنوان أخضر داكن
/// عريض، وخط أخضر قصير أسفل العنوان. (بديل محلي عن `SectionHeader`
/// المشتركة حتى لا يتغيّر مظهر أي شاشة أخرى.)
class _AccountSectionHeader extends StatelessWidget {
  const _AccountSectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _goldDeep, size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                    color: _navy,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              width: 58,
              height: 3,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_gold, Color(0x00C1912F)],
                  begin: AlignmentDirectional.centerStart,
                  end: AlignmentDirectional.centerEnd,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// بطاقة هوية الحساب مع ملخص المكافآت السريع.
class _LuxuryProfileCard extends StatelessWidget {
  const _LuxuryProfileCard({
    required this.name,
    required this.phone,
    required this.avatarUrl,
    this.onEditAvatar,
    this.roleLabel = 'زبون',
    this.roleIcon = '🧑',
    this.isCustomerOnly = true,
  });

  final String name;
  final String phone;
  final String avatarUrl;
  final VoidCallback? onEditAvatar;
  final String roleLabel;
  final String roleIcon;

  /// الأدمن والمندوب لا يُعرض عليهم ما يخصّ عروض الزبون.
  final bool isCustomerOnly;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width <= 340;
    final avatarSize = compact ? 64.0 : 72.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _cardBorder),
        boxShadow: [
          BoxShadow(
            color: _navy.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: avatarSize,
                    height: avatarSize,
                    decoration: BoxDecoration(
                      color: AppColors.accentLight,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.45),
                      ),
                    ),
                    child: ClipOval(
                      child: AppImage(
                        avatarUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.person_rounded,
                          color: AppColors.accentDeep,
                          size: 38,
                        ),
                      ),
                    ),
                  ),
                  if (onEditAvatar != null)
                    Positioned(
                      left: -2,
                      bottom: -2,
                      child: GestureDetector(
                        onTap: onEditAvatar,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppColors.accentDeep,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: const Icon(
                            Icons.photo_camera_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(width: compact ? 12 : 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              color: _navy,
                              fontSize: compact ? 16.5 : 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.lock_outline_rounded,
                          color: AppColors.textHint,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            phone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accentLight,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '$roleIcon  $roleLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          color: AppColors.accentDeep,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        const Icon(
                          Icons.workspace_premium_rounded,
                          color: _gold,
                          size: 15,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'عضو مميز في اطباء ذي قار',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              color: _goldDeep,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsItem {
  const _SettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.color,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final VoidCallback? onTap;

  /// عنصر بديل عن سهم «‹» على اليسار (مثل مفتاح تشغيل/إيقاف).
  final Widget? trailing;
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.items});

  final List<_SettingsItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _cardBorder),
        boxShadow: [
          BoxShadow(
            color: _navy.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            _SettingTile(item: items[i]),
            if (i != items.length - 1)
              const Divider(height: 1, indent: 64, endIndent: 16),
          ],
        ],
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({required this.item});

  final _SettingsItem item;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: item.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(item.icon, color: item.color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: GoogleFonts.cairo(
                        color: _navy,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (item.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle!,
                        style: GoogleFonts.cairo(
                          color: AppColors.textSecondary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (item.trailing != null)
                item.trailing!
              else
                const Icon(
                  Icons.chevron_left_rounded,
                  color: AppColors.textHint,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinedAction extends StatelessWidget {
  const _OutlinedAction({required this.label, required this.icon, this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          // زر خروج أبيض للجميع: خلفية بيضاء ونص أخضر واضح.
          backgroundColor: Colors.white,
          foregroundColor: AppColors.primary,
          side: BorderSide(color: AppColors.primary.withValues(alpha: 0.30)),
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: Icon(icon, size: 18, color: AppColors.primary),
        label: Text(
          label,
          style: GoogleFonts.cairo(
            fontWeight: FontWeight.w800,
            fontSize: 13.5,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }
}

class _DangerAction extends StatelessWidget {
  const _DangerAction({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: onTap,
        child: Text(
          label,
          style: GoogleFonts.cairo(
            color: AppColors.danger,
            fontWeight: FontWeight.w800,
            fontSize: 12.5,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.danger.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

class _GuestLoginView extends StatelessWidget {
  const _GuestLoginView({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                color: AppColors.primaryLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                color: AppColors.primary,
                size: 44,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'وضع المشاهدة فقط',
              style: GoogleFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'أنت تدخل كزائر. سجّل الدخول أو أنشئ حساباً للوصول إلى ملفك الشخصي وطلباتك ومكافآتك.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onLogin,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'تسجيل الدخول',
                style: GoogleFonts.cairo(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RegisterScreen()),
                );
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.5),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'إنشاء حساب جديد',
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة رصيد الصيدلية: يعرضها الملف الشخصي لصاحب الصيدلية فقط،
/// وتُحسب من المنتجات التي اشتراها الناس من صيدليته بالدينار العراقي.
class _OwnerBalanceCard extends StatefulWidget {
  const _OwnerBalanceCard({super.key});

  @override
  State<_OwnerBalanceCard> createState() => _OwnerBalanceCardState();
}

class _OwnerBalanceCardState extends State<_OwnerBalanceCard> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  /// يجلب الرصيد من قاعدة البيانات ويحدّث البطاقة.
  Future<void> load() async {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _loading = true);
    final data = await SupabaseService.instance.fetchShopOwnerBalance(phone);
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final shopName = d?['shop_name']?.toString() ?? '';
    final balance = (d?['balance'] as num?)?.toDouble() ?? 0;
    final pending = (d?['pending'] as num?)?.toDouble() ?? 0;
    final itemsSold = (d?['items_sold'] as num?)?.toInt() ?? 0;
    final ordersCount = (d?['orders_count'] as num?)?.toInt() ?? 0;
    final delivered = (d?['delivered_orders'] as num?)?.toInt() ?? 0;

    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.navyCardGradient,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.40),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.30),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(25),
        child: Stack(
          children: [
            // نسيج زجاجي: طبقة بيضاء شفافة تعطي إحساس الزجاج المصقور.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.18),
                      Colors.white.withValues(alpha: 0.02),
                      Colors.white.withValues(alpha: 0.10),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
            // وميض زجاجي: توهج دائري علوي ونقطة ضوء سفلي.
            Positioned(
              left: -50,
              top: -80,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.20),
                      blurRadius: 42,
                      spreadRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: -40,
              bottom: -70,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.05),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.12),
                      blurRadius: 30,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.20),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.35),
                                ),
                              ),
                              child: const Icon(
                                Icons.account_balance_wallet_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'بطاقة رصيد الصيدلية',
                                    style: GoogleFonts.cairo(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  if (shopName.isNotEmpty)
                                    Text(
                                      shopName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.cairo(
                                        color: Colors.white.withValues(
                                          alpha: 0.8,
                                        ),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => AppRefresh.run(load),
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.refresh_rounded,
                                color: Colors.white,
                                size: 19,
                              ),
                              tooltip: 'تحديث الرصيد',
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'رصيدك المكتمل',
                          style: GoogleFonts.cairo(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          CurrencyFormatter.format(balance),
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            shadows: const [
                              Shadow(color: Colors.black26, blurRadius: 8),
                            ],
                          ),
                        ),
                        if (pending > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            'قيد التوصيل (معلق): ${CurrencyFormatter.format(pending)}',
                            style: GoogleFonts.cairo(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            _Chip(label: '$itemsSold منتج مباع'),
                            const SizedBox(width: 8),
                            _Chip(label: '$delivered طلب مُوصَّل'),
                            const SizedBox(width: 8),
                            _Chip(label: '$ordersCount طلب'),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // ★ فتح المحفظة الكاملة (سجل الطلبات). الأدمن
                        //   الذي هو صاحب صيدلية لا يمر بواجهة صاحب الصيدلية
                        //   (مستثنى في app.dart)، فهذه بوابته إلى المحفظة.
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ShopWalletScreen(),
                                ),
                              );
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.65),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 17,
                            ),
                            label: Text(
                              'فتح المحفظة الكاملة',
                              style: GoogleFonts.cairo(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// شريحة صغيرة شفافة داخل بطاقة الرصيد.
class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.cairo(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
