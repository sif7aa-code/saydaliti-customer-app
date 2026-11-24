import 'package:flutter/material.dart';

/// منتج ضمن صيدلية — يحمل بيانات العرض والسعر واسم الصيدلية.
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.shopId,
    required this.shopName,
    this.logo,
    this.logoImage,
    required this.backgroundColor,
    this.price = 0,
    this.oldPrice,
    this.specialNote,
    this.isVideo = false,
    this.categoryId,
    this.requiresPrescription = false,
  });

  final String id;
  final String name;
  final String shopId;
  final String shopName;
  final IconData? logo;
  final String? logoImage;
  final Color backgroundColor;
  final double price;
  final double? oldPrice;
  final String? specialNote;
  final bool isVideo;

  /// القسم الذي يتبع له المنتج (category_id في قاعدة البيانات).
  final String? categoryId;

  /// ★ يتطلب وصفة طبية: لا يُقبل طلبه في السلة بلا صورة وصفة مرفقة،
  ///   وتظهر الوصفة لصاحب الصيدلية وللأدمن فقط.
  final bool requiresPrescription;

  double get discountPercent {
    if (oldPrice == null || oldPrice! <= 0 || oldPrice! <= price) return 0;
    return ((oldPrice! - price) / oldPrice! * 100).roundToDouble();
  }
}
