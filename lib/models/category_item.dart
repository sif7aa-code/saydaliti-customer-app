import 'package:flutter/material.dart';

/// قسم رئيسي يظهر في شبكة الأيقونات الدائرية (مطاعم، سوبر ماركت...).
class CategoryItem {
  const CategoryItem({
    required this.id,
    required this.title,
    required this.icon,
    required this.color,
    this.imageUrl,
    this.shopId,
  });

  final String id;
  final String title;
  final IconData icon;
  final Color color;

  /// صورة حقيقية للقسم تُعرض داخل حدود الدائرة.
  final String? imageUrl;

  /// الصيدلية المرتبط بهذا القسم (`categories.shop_id`)، أو null لقسم
  /// عام لكل الصيدليات. منتج هذه الصيدلية يتبع القسم حتى لو كان
  /// `products.category_id` فارغاً.
  final String? shopId;
}
