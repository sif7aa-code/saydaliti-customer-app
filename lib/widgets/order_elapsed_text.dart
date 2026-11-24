import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/order_elapsed.dart';

/// ★ سطر «وقت الطلب» الحيّ — يُعرض للمندوب وللزبون وللأدمن من نفس الدالة.
///
/// يتحدّث من نفسه كل `OrderElapsed.tick` بلا انتظار لرفرش الشاشة: الطلب
/// المنتظر على قائمة المندوب يتقدّم أمام عينيه، وكذلك الزبون في تتبعه،
/// واللوحة في «مراقبة الطلبات» — وهي وحدها تطلب `precise` مع `withClock`
/// لأن الأدمن يقارن طلبات بجانب بعضها فيحتاج الدقيقة واسطة الإرسال نفسها.
///
/// ساعة واحدة للكل: المؤقّت مشترك بالعدّاد، فمئة بطاقة لا تملك مئة
/// `Timer`، ويتوقف نبض الساعة تلقائياً حين تُغلق كل الشاشات التي تعرضه.
///
/// يعرض '' ⇒ لا شيء: بلا `created_at` لا نختلق «منذ» على مجهول.
class OrderElapsedText extends StatefulWidget {
  const OrderElapsedText({
    super.key,
    required this.order,
    this.showIcon = true,
    this.iconSize = 14,
    this.style,
    this.precise = false,
    this.withClock = false,
  });

  /// صف الطلب كما جاء من القاعدة (`created_at`، `delivered_at`).
  final Map<String, dynamic> order;

  /// أيقونة الساعة أمام النص — تُطفأ حيث يكون السياق واضحاً.
  final bool showIcon;
  final double iconSize;
  final TextStyle? style;

  /// ★ الدقائق مع الساعات: «منذ ساعتين و15 دقيقة» بدل «منذ ساعتين».
  final bool precise;

  /// ★ ساعة الطلب نفسها قبل المدة: «طلب 3:20 مساءً · منذ ساعتين و15 دقيقة».
  final bool withClock;

  @override
  State<OrderElapsedText> createState() => _OrderElapsedTextState();
}

class _OrderElapsedTextState extends State<OrderElapsedText> {
  @override
  void initState() {
    super.initState();
    _SharedClock.attach();
  }

  @override
  void dispose() {
    _SharedClock.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OrderElapsed.placedAt(widget.order) == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<DateTime>(
      valueListenable: _SharedClock.now,
      builder: (context, now, _) {
        final elapsed = widget.precise
            ? OrderElapsed.labelPrecise(widget.order, now: now)
            : OrderElapsed.label(widget.order, now: now);
        if (elapsed.isEmpty) return const SizedBox.shrink();
        final text = widget.withClock
            ? 'طلب ${OrderElapsed.clock(widget.order['created_at'])} · $elapsed'
            : elapsed;
        final style = widget.style ??
            GoogleFonts.cairo(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: AppColors.textSecondary,
            );
        if (!widget.showIcon) return Text(text, style: style);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.schedule_rounded,
              size: widget.iconSize,
              color: style.color,
            ),
            const SizedBox(width: 5),
            // مرن: النص وحده في صف يتمدّد قد يتجاوز حدّ البطاقة، وسبق
            // أن ظهر شريط «RIGHT OVERFLOWED» في سطور الأوقات.
            Flexible(child: Text(text, style: style)),
          ],
        );
      },
    );
  }
}

/// الساعة المشتركة: نبض واحد لكل الشاشات، يتوقف حين لا ناظر.
class _SharedClock {
  const _SharedClock._();

  static final ValueNotifier<DateTime> now = ValueNotifier(DateTime.now());
  static Timer? _timer;
  static int _refs = 0;

  static void attach() {
    _refs++;
    _timer ??= Timer.periodic(OrderElapsed.tick, (_) {
      // يُستدعى حتى لو لم تعد هناك شاشات، فيُطفأ عند أول صفير بلا ناظر.
      if (_refs <= 0) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      now.value = DateTime.now();
    });
  }

  static void detach() {
    if (_refs > 0) _refs--;
    if (_refs == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}
