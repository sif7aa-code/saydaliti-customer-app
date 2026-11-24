import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../widgets/app_image.dart';
import 'notification_sound.dart';

/// إشعار داخلي يظهر فوق أي شاشة فور تغيّر أي حالة.
/// يعمل لكل المستخدمين (زبون / مندوب / أدمن) في كل الشاشات.
class StatusCenter {
  StatusCenter._();

  static final StatusCenter instance = StatusCenter._();

  /// يسجّل الـ Overlay عند بناء أي شاشة (حتى يظهر الإشعار فوقها).
  final GlobalKey<OverlayState> overlayKey = GlobalKey<OverlayState>();

  /// بديل عند عدم توفر الـ Overlay: يستخدم navigatorKey من MaterialApp.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  OverlayState? _attached;

  /// يربط الـ Overlay الخاص بـ MaterialApp ليصل الإشعار لكل الشاشات.
  void attach(BuildContext context) {
    _attached = Overlay.maybeOf(context, rootOverlay: true);
  }

  OverlayState? get _overlay =>
      _attached ?? overlayKey.currentState ?? navigatorKey.currentState?.overlay;

  OverlayEntry? _entry;
  int _seq = 0;

  /// آخر إشعار (لتستطيع الشاشات التفاعل معه).
  final ValueNotifier<AppNotice?> latest = ValueNotifier<AppNotice?>(null);

  /// رقم الحساب الذي يعمل الآن على هذا الجهاز.
  /// يُضبط من `app.dart`، ويمنع عرض إشعارات الطلب على جهاز صاحبه
  /// (مثلاً المندوب الذي قبل الطلب لا يرى إشعار «تم قبول طلبك»).
  static String? activeAccountPhone;

  /// مفاتيح آخر إشعارات بُثّت، مع وقت بثّها — لمنع تكرار نفس الإشعار
  /// وصوته (يصل الإشعار أحياناً من FCM ومن جدول الإشعارات معاً).
  static final Map<String, int> _recentKeys = {};

  static const int _repeatWindowMs = 4000;

  /// يسجّل هذا الحدث ويعيد `false` إن كان مكرّراً خلال [_repeatWindowMs].
  ///
  /// يُستعمل من كل مسارات العرض (البطاقة الداخلية، إشعار النظام، FCM)
  /// حتى لا يظهر الإشعار مرتين ولا يُشغَّل صوته مرتين مهما كان مصدره.
  static bool claimOnce(String? key, {int windowMs = _repeatWindowMs}) {
    if (key == null || key.isEmpty) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _recentKeys[key];
    if (last != null && now - last < windowMs) return false;
    _recentKeys[key] = now;
    if (_recentKeys.length > 80) {
      _recentKeys.remove(_recentKeys.keys.first);
    }
    return true;
  }

  /// يبثّ إشعاراً داخلياً: يظهر فوراً على كل الشاشات مع صوت تنبيهه.
  ///
  /// [imageUrl] شعار الحساب الذي أرسل الإشعار (شعار خاص بكل حساب).
  /// [sound] نغمة التنبيه؛ تُشغَّل مرة واحدة لكل إشعار.
  /// [dedupeKey] مفتاح يمنع تكرار العرض/الصوت لنفس الحدث خلال ثوانٍ.
  Future<void> broadcast({
    required String title,
    required String body,
    String? status,
    String? orderId,
    String? imageUrl,
    String? sound,
    String? serial,
    bool isDriverRequest = false,
    String? dedupeKey,
    Duration duration = const Duration(seconds: 5),
    bool playSound = true,
    VoidCallback? onTap,
  }) async {
    if (!claimOnce(dedupeKey)) return;

    final notice = AppNotice(
      id: ++_seq,
      title: title,
      body: body,
      status: status,
      orderId: orderId,
      serial: serial,
      isDriverRequest: isDriverRequest,
      imageUrl: (imageUrl == null || imageUrl.trim().isEmpty)
          ? null
          : imageUrl.trim(),
      sound: sound,
      onTap: onTap,
    );
    latest.value = notice;
    _show(notice, duration);

    if (playSound) unawaited(_announce(notice));
  }

  /// يشغّل النغمة القصيرة المناسبة لهذا الإشعار.
  Future<void> _announce(AppNotice notice) async {
    final sound = NotificationSound.resolve(notice.sound ?? notice.status);
    await NotificationSound.instance.play(sound);
  }

  void _show(AppNotice notice, Duration duration) {
    final overlay = _overlay;
    if (overlay == null) return;
    // ★ خانة واحدة لا اثنتان: الشعار الظاهر يُزال **في نفس اللحظة**
    //   بلا انتظار انتهاء حركته، ثم يُزرَّع الجديد فوقه في نفس الإطار.
    //   هذا حرفية الطلب: «وإذا اتى شعار اخر يختفي الاول فورا ويظهر
    //   الثاني» — لا طابور ولا تراكم ولا شريطان فوق بعض.
    final previous = _entry;
    _entry = null;
    previous?.remove();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _NoticeBanner(
        notice: notice,
        duration: duration,
        onDismiss: () {
          if (_entry == entry) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

/// بيانات الإشعار الداخلي.
class AppNotice {
  const AppNotice({
    required this.id,
    required this.title,
    required this.body,
    this.status,
    this.orderId,
    this.serial,
    this.isDriverRequest = false,
    this.imageUrl,
    this.sound,
    this.onTap,
  });

  final int id;
  final String title;
  final String body;
  final String? status;
  final String? orderId;

  /// رقم الطلب التسلسلي (#12) — يظهر مع «لديك طلب جديد».
  final String? serial;

  /// الطلب هو «طلب مندوب» ⇒ عبارة «لديك طلب مندوب جديد».
  final bool isDriverRequest;

  /// شعار الحساب المُرسِل (شعار خاص بكل حساب).
  final String? imageUrl;

  /// اسم نغمة التنبيه (عمود sound).
  final String? sound;
  final VoidCallback? onTap;
}

/// بطاقة الإشعار العائمة أعلى الشاشة.
///
/// ★ حركتها كما طُلبت بالحرف: «يظهر شعار داخلي من الأعلى وينزل قليلاً
///   ثم يختفي» ⇒ تنزل من فوق حدّ الشاشة إلى موضعها، تمكث مدة
///   [duration]، ثم تطلع راجعة وتذوب. لا زر إغلاق ولا اختفاء فجائي:
///   هي نفسها تلغي نفسها، ولو جاء إشعار جديد أُزيلت من الجذر فوراً.
class _NoticeBanner extends StatefulWidget {
  const _NoticeBanner({
    required this.notice,
    required this.duration,
    required this.onDismiss,
  });

  final AppNotice notice;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_NoticeBanner> createState() => _NoticeBannerState();
}

class _NoticeBannerState extends State<_NoticeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _hideTimer;
  bool _dismissed = false;

  // المسافة التي تنزلها البطاقة من فوق الشاشة، ومسافة ذهابها عند
  // الاختفاء: تنزل بقدر ارتفاعها كاملاً فلا تُقطع، وتخرج للأعلى نفسها.
  static const double _dropPx = 96;

  /// ★ كل إشعار طلبٍ واحد لوّن أزرق — الطلبات لا تُميَّز بألوان
  ///   متغيّرة. كان `new_order` برتقالياً و`delivered` أخضر و
  ///   `delivering` فيروزي، فيصير لون الشعار دالّة على الحالة لا على
  ///   كونه طلباً، ويختلط مع ألوان بقية الأحداث (بنفسجي/أحمر).
  static const Color _orderBlue = AppColors.primary;

  static bool _isOrder(AppNotice n) {
    // ★ طلبٌ = له orderId، أو نوعٌ من أنواع الطلبات المعروفة.
    if (n.orderId != null && n.orderId!.isNotEmpty) return true;
    return switch (n.status) {
      'order_created' || 'new_order' || 'driver_request' ||
      'accepted' || 'delivering' || 'delivered' || 'rejected' ||
      'cancelled' || 'reopened' || 'item_changed' => true,
      _ => false,
    };
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 190),
    )..forward();
    _hideTimer = Timer(widget.duration, _vanish);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// يختفي: يطلع راجعاً إلى فوق ويذوب، ثم تُرفع البطاقة من الشجرة.
  ///
  /// `then` على حالة الحركة لا `whenComplete`: عند الاستبدال الفوري
  /// تُزال البطاقة من خارجنا فنموت بلا `_dispose` مكرر ولا نداء زائد.
  void _vanish() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    _hideTimer?.cancel();
    _controller.reverse().then((_) {
      if (!mounted) return;
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final isOrder = _isOrder(notice);
    final color = isOrder
        ? _orderBlue
        : switch (notice.status) {
            'rejected' || 'cancelled' || 'appointment_rejected' =>
              AppColors.danger,
            'item_changed' => AppColors.accentDeep,
            'appointment_request' => AppColors.primary,
            'appointment_approved' => AppColors.success,
            _ => _orderBlue,
          };
    final icon = switch (notice.status) {
      'delivered' => Icons.check_circle_rounded,
      'rejected' || 'cancelled' => Icons.cancel_rounded,
      'delivering' => Icons.delivery_dining_rounded,
      'accepted' => Icons.local_shipping_rounded,
      'new_order' => Icons.campaign_rounded,
      'item_changed' => Icons.swap_horiz_rounded,
      'broadcast' => Icons.campaign_rounded,
      'reopened' => Icons.replay_rounded,
      'points' => Icons.stars_rounded,
      // ★ حجز دكتور/ة: للنقر فوق الشريط، لا أيقونة طلب صيدلية.
      'appointment_request' => Icons.event_available_rounded,
      'appointment_approved' => Icons.event_available_rounded,
      'appointment_rejected' => Icons.event_busy_rounded,
      _ => Icons.notifications_active_rounded,
    };

    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 14,
      right: 14,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {
            notice.onTap?.call();
            _vanish();
          },
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(_controller.value);
              return Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  // enters من فوق حد الشاشة (−_dropPx) ⇒ 0، ويخرج كذلك.
                  offset: Offset(0, -_dropPx * (1 - t)),
                  child: child,
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: color.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  _NoticeAvatar(notice: notice, color: color, icon: icon),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          notice.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          notice.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// أيقونة الإشعار: شعار التطبيق (أو الحساب) إن وُجد، وإلا أيقونة الحالة.
class _NoticeAvatar extends StatelessWidget {
  const _NoticeAvatar({
    required this.notice,
    required this.color,
    required this.icon,
  });

  final AppNotice notice;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    // ★ الشعار يأتي من `imageUrl` (شعار الحساب المُرسِل أو التطبيق
    //   نفسه)، والآن يظهر داخل دائرة زرقاء لكل إشعار طلب. وإن لم
    //   يتوفّر شعار نُبقي الأيقونة داخل الدائرة نفسها بدل نسبة
    //   بيضاء على خلفية شفافة — كان يعطي أيقونة بلا هوية لونية.
    final logo = notice.imageUrl;
    final hasLogo = logo != null && logo.isNotEmpty;

    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: hasLogo
          ? AppImage(
              logo,
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              cacheWidth: 88,
              cacheHeight: 88,
              errorBuilder: (_, _, _) => Icon(icon, color: Colors.white, size: 21),
            )
          : Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: Colors.white, size: 21),
            ),
    );
  }
}
