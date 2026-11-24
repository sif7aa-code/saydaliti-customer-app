import 'dart:math' as math;

import 'package:flutter/material.dart';

/// لوحة ألوان مشتقّة من لون أساسي واحد: الخلفية والتدرّجات والطبقات.
///
/// كل بانر يأخذ لوناً أساسياً مختلفاً ⇒ خلفيات مختلفة، لكن **بنية اللون
/// واحدة**: تدرّج داكن←متوسط←أفتح أفقياً، وطبقات هندسية بلون أفتح منه،
/// ولمعة زجاجية علوية. الأخضر يبقى العنصر المسيطر ما دام الأساس أخضر.
@immutable
class EmeraldBannerPalette {
  const EmeraldBannerPalette({
    required this.seed,
    required this.dark,
    required this.mid,
    required this.light,
    required this.shapeA,
    required this.shapeB,
  });

  /// يبني لوحة من لون أساسي عبر ضبط الإضاءة والتشبّع، فلا نحتاج لتخزين
  /// ثلاثة ألوان لكل بانر: لون واحد يكفي ويولّد البقية بانتظام.
  factory EmeraldBannerPalette.fromSeed(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    Color tone(double lightness, double saturation) => hsl
        .withLightness(lightness.clamp(0.0, 1.0))
        .withSaturation(saturation.clamp(0.0, 1.0))
        .toColor();

    return EmeraldBannerPalette(
      seed: seed,
      dark: tone(hsl.lightness * 0.84, hsl.saturation * 1.02),
      mid: seed,
      light: tone((hsl.lightness + 0.09).clamp(0.0, 1.0), hsl.saturation * 0.95),
      shapeA: tone((hsl.lightness + 0.15).clamp(0.0, 1.0), hsl.saturation * 0.88),
      shapeB: tone((hsl.lightness + 0.21).clamp(0.0, 1.0), hsl.saturation * 0.82),
    );
  }

  static EmeraldBannerPalette of(Color seed) =>
      EmeraldBannerPalette.fromSeed(seed);

  /// اللوحات الجاهزة المعروضة في شاشة إدارة البانرات: كل درجة من هوية
  /// الأخضر الطبي لتطبيق صيدليتي (2026-11-19)، مع الأزرق والنيلي
  /// خيارين إضافيين للتنويع.
  static const List<Color> presetSeeds = [
    Color(0xFF008000), // الأخضر الأساسي (الافتراضي)
    Color(0xFF2E9E2E), // أخضر مشرق (رأس الصفحة)
    Color(0xFF004D00), // أخضر عميق (أسفل بطاقة الرأس)
    Color(0xFF006B00), // أخضر داكن
    Color(0xFF007300), // أخضر متوسط
    Color(0xFF269B26), // أخضر فاتح ساطع
    Color(0xFF1A76F3), // أزرق (خيار تنويع)
    Color(0xFF4A38E0), // نيلي (خيار تنويع)
  ];

  final Color seed;
  final Color dark;
  final Color mid;
  final Color light;
  final Color shapeA;
  final Color shapeB;
}

/// خلفية البانر الأفقية: تدرّج غني + طبقات هندسية شفافة + لمعة زجاجية.
///
/// الترتيب من الأسفل للأعلى:
///  1. تدرّج أساسي أفقي `dark → mid → light`.
///  2. أربع طبقات هندسية كبيرة (دوائر + شكل مستدير مائل) بـ`shapeA/B`
///     بعتامة 10%–18%: بلا حدود ولا تفاصيل حادة.
///  3. بقع ضوء شعاعية خفيفة (تدرّج إضاءة) متداخلة بنعومة.
///  4. طبقة زجاجية: أبيض شفاف أعلى + لمعة قطرية + تعتيم خفيف أسفل.
///
/// **الظل خارج الحد**: الإطار يرسم الظلّ، والخلفية تقصّ نفسها بـ`ClipRRect`
/// بنفس زاوية الإطار، فلا يخرج أي شكل أو ظلّ عن حدود البانر المستديرة.
class EmeraldBannerBackground extends StatelessWidget {
  const EmeraldBannerBackground({
    super.key,
    required this.palette,
    this.borderRadius = 22,
  });

  final EmeraldBannerPalette palette;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) التدرّج الأساسي (اللون المسيطر).
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.dark, p.mid, p.light],
                stops: const [0.0, 0.54, 1.0],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),

          // 2) الطبقات الهندسية. المواضع خارج الحدود مقصودة: `ClipRRect`
          //    أعلاه هو ما يمنع خروجها فعلياً عن إطار البانر.
          Positioned(
            left: -74,
            top: -80,
            child: _Blob(size: 196, color: p.shapeA, opacity: 0.17),
          ),
          Positioned(
            right: -48,
            top: -36,
            child: _Blob(size: 136, color: p.shapeB, opacity: 0.14),
          ),
          Positioned(
            right: 30,
            bottom: -88,
            child: _Blob(size: 170, color: p.shapeA, opacity: 0.12),
          ),
          Positioned(
            left: 74,
            bottom: -66,
            child: _Blob(size: 116, color: p.shapeB, opacity: 0.10),
          ),
          Positioned(
            right: -28,
            bottom: -32,
            child: Transform.rotate(
              angle: math.pi / 7,
              child: _Blob(size: 98, color: p.shapeB, opacity: 0.11, radius: 30),
            ),
          ),

          // 3) بقع ضوء شعاعية: تدرّج إضاءة ناعم بلا حدود ظاهرة.
          Positioned(
            left: -42,
            top: -48,
            child: const IgnorePointer(child: _Glow(size: Size(244, 194), color: Color(0x22FFFFFF))),
          ),
          Positioned(
            right: -32,
            bottom: -72,
            child: IgnorePointer(child: _Glow(size: Size(214, 172), color: Color(0x1AFFFFFF))),
          ),

          // 4) الطبقة الزجاجية.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0x1CFFFFFF), Color(0x00FFFFFF), Color(0x0F000000)],
                stops: [0.0, 0.45, 1.0],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0x1FFFFFFF), Color(0x00FFFFFF)],
                begin: Alignment.topLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// كتلة هندسية شبه شفافة: دائرة أو مستطيل مستدير، بلا حدود.
class _Blob extends StatelessWidget {
  const _Blob({
    required this.size,
    required this.color,
    required this.opacity,
    this.radius,
  });

  final double size;
  final Color color;
  final double opacity;

  /// `null` = دائرة كاملة، ورقم = استدارة خفيفة تكسر دائرية الشكل.
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: opacity),
        shape: radius == null ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: radius == null ? null : BorderRadius.circular(radius!),
      ),
    );
  }
}

/// بقعة ضوء شعاعية (تدرّج إضاءة) بلا حواف.
class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});

  final Size size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          radius: 0.92,
        ),
      ),
    );
  }
}

/// إطار البانر: الحدّ الفاتح + الظلّ + **قصّ المحتوى داخل الزاوية**.
///
/// ★ هنا يُحلّ محلّ الشكوى «الظل/الزخرفة خارج الحدّ»: أي شكل داخل البانر
/// (الدوائر الزخرفية، الدوائر البيضاء، الصورة) تحت `ClipRRect` واحد يجمعه،
/// وإلا ظهرت أطرافه مربّعة خارج الحدود المستديرة. الظلّ وحده يُرسم على الحافة
/// المستديرة فيبقى نظيفاً ولا يُقتطع لأن `DecoratedBox` يسبق القصّ.
class EmeraldBannerFrame extends StatelessWidget {
  const EmeraldBannerFrame({
    super.key,
    required this.child,
    this.borderRadius = 22,
  });

  final Widget child;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: child,
      ),
    );
  }
}