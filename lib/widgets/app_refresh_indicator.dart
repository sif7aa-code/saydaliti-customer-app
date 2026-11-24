import 'package:flutter/material.dart';

/// غلاف [RefreshIndicator] المستخدم في كل الشاشات.
///
/// نفس [RefreshIndicator] حرفياً في الشكل والسلوك، ووُجد ليمرّر السحب من
/// [AppRefresh.run] فلا تحتاج أي شاشة معرفة شيء.
///
/// ★ 2026-10-28: حُذفت رنّة النجاح بطلب الأدمن — **التحديث صامت تماماً**،
///   ولا يُشغَّل أي صوت عند السحب أو عند زرّ التحديث.
class AppRefreshIndicator extends StatelessWidget {
  const AppRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
    this.color,
    this.backgroundColor,
    this.displacement = 40.0,
    this.edgeOffset = 0.0,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.semanticsLabel,
    this.semanticsValue,
    this.strokeWidth = RefreshProgressIndicator.defaultStrokeWidth,
    this.triggerMode = RefreshIndicatorTriggerMode.onEdge,
    this.elevation = 2.0,
  });

  final Widget child;
  final RefreshCallback onRefresh;
  final Color? color;
  final Color? backgroundColor;
  final double displacement;
  final double edgeOffset;
  final ScrollNotificationPredicate notificationPredicate;
  final String? semanticsLabel;
  final String? semanticsValue;
  final double strokeWidth;
  final RefreshIndicatorTriggerMode triggerMode;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => AppRefresh.run(onRefresh),
      color: color,
      backgroundColor: backgroundColor,
      displacement: displacement,
      edgeOffset: edgeOffset,
      notificationPredicate: notificationPredicate,
      semanticsLabel: semanticsLabel,
      semanticsValue: semanticsValue,
      strokeWidth: strokeWidth,
      triggerMode: triggerMode,
      elevation: elevation,
      child: child,
    );
  }
}

/// يشغّل [body] كتحديث (سحب أو زرّ «تحديث» أو نقرة تبويب).
///
/// ★ 2026-10-28: لم يبقَ فيه صوت ولا رنّة — الغلاف باقٍ وحده حتى لا تتغيّر
///   مواضع الاستدعاء في الشاشات.
abstract final class AppRefresh {
  static Future<void> run(Future<void> Function() body) async {
    await body();
  }
}
