import 'package:flutter/material.dart';

/// غلاف لمسات ناعم (2026-10-23 — «سلاسة أعلى للأزرار»).
///
/// يضغط الزر/البطاقة على نفسه قليلاً تحت الإصبع ثم يرجع بمنحنى مريح،
/// وهو مبني على [Listener] لا على [GestureDetector]: فلا يسرق النقرة من
/// [InkWell] أو الزر الذي داخله، ولا ينافس تمرير القائمة، فقط يراقب
/// المؤشر الذي نزل فوقه ويعطي الحركة.
///
/// الاستعمال: يغلّف الأزرار الخاصة المرسومة بـ`Container + InkWell`
/// (مثل زر «أضف» داخل بطاقات المنتجات). أما أزرار Material
/// (Filled/Elevated/…) فتأخذ نعومتها من السمة العامة في `app_theme.dart`.
class SoftPress extends StatefulWidget {
  const SoftPress({
    super.key,
    required this.child,
    this.pressScale = 0.955,
    this.enabled = true,
  });

  final Widget child;

  /// كم ينكمش العنصر تحت الإصبع (1 = بلا أثر).
  final double pressScale;
  final bool enabled;

  @override
  State<SoftPress> createState() => _SoftPressState();
}

class _SoftPressState extends State<SoftPress> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.pressScale < 1.0;
    return Listener(
      // `translucent`: العنصر يبقى جزءاً من مسار اللمس بلا ما يمنع من تحته.
      behavior: HitTestBehavior.translucent,
      onPointerDown: active ? (_) => _set(true) : null,
      // اللمس يُسلَّم لنفس العنصر حتى لو خرج الإصبع عنه ⇒ لا يبقى «ضاغطاً».
      onPointerUp: active ? (_) => _set(false) : null,
      onPointerCancel: active ? (_) => _set(false) : null,
      child: AnimatedScale(
        scale: _pressed ? widget.pressScale : 1.0,
        // النزول أسرع والرجوع ألين — هذا ما يجعل اللمسة «حقيقية».
        duration: Duration(milliseconds: _pressed ? 110 : 210),
        curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
