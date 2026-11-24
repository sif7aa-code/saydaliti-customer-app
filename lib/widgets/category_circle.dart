import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/category_item.dart';
import 'app_image.dart';

/// ★ حدود صورة القسم (2026-11-17، هوية صيدليتي التركوازية):
///   حلقة خارجية **تركوازي فاتح واحد لكل الأقسام**، ثم فراغ أبيض، ثم حلقة
///   بلون القسم نفسه، ثم أبيض تُعرض فيه الصورة كاملة بلا قصّ.
const Color categoryRimBlue = Color(0xFF8CC9CD);

/// القرص المشترك: مصدر الشكل الوحيد لصور الأقسام في التطبيق.
///
///   [size] القطر الكامل (مع الحلقتين)، و[iconSize] حجم الأيقونة حين لا
///   توجد صورة. الصورة تُعرض داخل **المربّع المحيط بالدائرة** (ضلعه = القطر
///   ÷ جذر ٢) فلا يمسّها القصّ إطلاقاً — وهذا شرط سابق صريح (لا قصّ لصور
///   الأقسام)، والفراغ حولها أبيض كالمرجع.
class CategoryDisc extends StatelessWidget {
  const CategoryDisc({
    super.key,
    required this.category,
    this.size = 78,
    this.iconSize,
  });

  final CategoryItem category;
  final double size;

  /// حجم الأيقونة الاحتياطية (افتراضياً نسبة من القطر).
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final url = category.imageUrl;
    final hasImage = url != null && url.isNotEmpty;
    final tint = category.color;
    final icon = iconSize ?? size * 0.36;

    // ★ السماكات كنسبة من القطر: القرص في الرئيسية ٧٨ وفي الشبكة ٦٢،
    //   فالنسبة تُبقي الشكل واحداً في المكانين.
    final outerRing = (size * 0.026).clamp(1.6, 2.4);
    final gap = (size * 0.040).clamp(2.2, 3.6);
    final innerRing = (size * 0.023).clamp(1.4, 2.2);
    final inset = (size * 0.026).clamp(1.6, 2.4);

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(gap),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: categoryRimBlue, width: outerRing),
      ),
      child: Container(
        padding: EdgeInsets.all(inset),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(
            color: tint.withValues(alpha: 0.9),
            width: innerRing,
          ),
        ),
        child: ClipOval(
          child: LayoutBuilder(
            builder: (context, cons) {
              final d = cons.biggest.shortestSide;
              final box = d / math.sqrt2;
              return Center(
                child: SizedBox(
                  width: box,
                  height: box,
                  child: hasImage
                      ? AppImage(
                          url,
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.medium,
                          cacheWidth: (size * 2.4).round(),
                          cacheHeight: (size * 2.4).round(),
                          loadingBuilder: (context, child, progress) =>
                              progress == null
                              ? child
                              : Icon(category.icon, color: tint, size: icon),
                          errorBuilder: (_, _, _) =>
                              Icon(category.icon, color: tint, size: icon),
                        )
                      : Icon(category.icon, color: tint, size: icon),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// دائرة قسم — بقيت بنفس الاسم والوسائط حتى لا تتغيّر أي شاشة تستعملها،
/// وصار رسمها من [CategoryDisc] وحده.
class CategoryCircle extends StatelessWidget {
  const CategoryCircle({
    super.key,
    required this.category,
    this.size = 62,
    this.iconSize = 28,
  });

  final CategoryItem category;

  /// قطر الدائرة.
  final double size;

  /// حجم الأيقونة الاحتياطية.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return CategoryDisc(category: category, size: size, iconSize: iconSize);
  }
}
