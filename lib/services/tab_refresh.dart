import 'dart:async';

import 'package:flutter/widgets.dart';

import '../widgets/app_refresh_indicator.dart';

/// ★ نقرة زرّ القائمة السفلية = صعود لأول عنصر + تحديث **حقيقي** + رنّة.
///
/// كيف تعمل بلا ما تعرف الشاشات بعضها؟
///   * الهيكل (`MainShell` / `ShopOwnerShell` / شاشة المندوب) ينادي
///     [TabRefresh.fire] بمعرّف التبويب بعد تحديده.
///   * الشاشة صاحبة ذلك المعرّف مسجّلة عند نفسها عبر
///     [TabRefreshTarget]، فيأتيها النداء وتنفّذ.
///
/// لا حاجة لتمرير دوال في الـConstructors ولا لـ`GlobalKey`، وتبقى
/// الشاشات مبنية **مرة واحدة** كما هي الآن — وهو ما يمنع تلف حالة
/// التبويب عند كل نقرة.
abstract final class TabRefresh {
  TabRefresh._();

  static final Map<String, List<VoidCallback>> _handlers =
      <String, List<VoidCallback>>{};

  /// تسجّل الشاشة نفسها تحت معرّفها. تُرجع دالة إلغاء التسجيل.
  static VoidCallback on(String id, VoidCallback handler) {
    (_handlers[id] ??= <VoidCallback>[]).add(handler);
    return () {
      final list = _handlers[id];
      if (list == null) return;
      list.remove(handler);
      if (list.isEmpty) _handlers.remove(id);
    };
  }

  /// يُنادى من الهيكل بعد تحديد التبويب (ولو كان محدّداً أصلاً).
  static void fire(String id) {
    final list = _handlers[id];
    if (list == null || list.isEmpty) return;
    // نسخة: قد يُزيل معالجٌ نفسه أثناء المرور (شاشة تُغلق أمام المستخدم).
    for (final h in List<VoidCallback>.from(list)) {
      h();
    }
  }
}

/// ★ أضِف هذا الـmixin لأي شاشة تقف خلف زرّ في القائمة السفلية.
///
/// يعطيها [tabScroll] (مرّره في `controller:` لقائمة الشاشة)، ويسجّلها
/// تحت [tabId]، وعند النقرة:
///   1. تصعد للأعلى **فوراً** — هذا هو الجزء السريع: لا تنتظر الشبكة.
///   2. تشغّل [onTabRefresh] داخل [AppRefresh.run] (بلا أي صوت: رنّة
///      التحديث حُذفت بطلب الأدمن ٢٠٢٦-١٠-٢٨).
///
/// إن كان في الشاشة أكثر من قائمة، تُمرَّر [tabScroll] لها كلها (لا
/// تُبنى معاً). وإن كان متصفّحها `PageView`، تُغلّف [onTabScrollToTop]
/// فتستخدم متحكّمها هي.
mixin TabRefreshTarget<T extends StatefulWidget> on State<T> {
  /// معرّف التبويب — يجب أن يطابق ما يناديه الهيكل في [TabRefresh.fire].
  String get tabId;

  /// التحديث الحقيقي للشاشة. أعِد `null` في شاشة بلا شبكة (نموذج إدخال،
  /// سلة محلية…) فتقتصر النقرة على الصعود للأعلى بلا جلب.
  ///
  /// تُعاد كـ*دالة* لا كـFuture لأن العمل لا يبدأ إلا عند النقرة.
  Future<void> Function()? onTabRefresh();

  /// متحكّم التمرير الخاص بالتبويب: يعرّفه الـmixin ويحرّره وحده.
  @protected
  final ScrollController tabScroll = ScrollController();

  bool _refreshing = false;
  VoidCallback? _off;

  /// الصعود للأعلى. `animateTo` قصير (260ms) لأن القفزة المفاجئة تُفقد
  /// المستخدم موضعَه في قائمة طويلة، وهو أطول من أن يُشعر بـ«فوري».
  void onTabScrollToTop() {
    if (!tabScroll.hasClients) return;
    try {
      if (tabScroll.position.pixels <= 1) return;
      tabScroll.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      // قائمة قصيرة أو موضعٌ يُعاد بناؤه الآن: الصعود تجميلي، ولا
      // يُسقط النقرة ولا التحديث.
    }
  }

  @override
  void initState() {
    super.initState();
    _off = TabRefresh.on(tabId, _onTabTapped);
  }

  void _onTabTapped() {
    if (!mounted) return;
    onTabScrollToTop();
    final body = onTabRefresh();
    if (body == null || _refreshing) return;
    // ★ حماية من النقر المتتالي: كل نقرة كانت تدفع ٤ رحلات REST وتُكدّس
    //   الرنّات. الصعود للأعلى يبقى يعمل في كل نقرة.
    _refreshing = true;
    unawaited(
      AppRefresh.run(body)
          .catchError((Object _) {})
          .whenComplete(() => _refreshing = false),
    );
  }

  @override
  void dispose() {
    _off?.call();
    _off = null;
    tabScroll.dispose();
    super.dispose();
  }
}
