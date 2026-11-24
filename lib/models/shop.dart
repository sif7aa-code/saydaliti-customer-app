import 'package:flutter/material.dart';

import '../core/utils/shop_status.dart';

class Shop {
  const Shop({
    required this.id,
    required this.name,
    required this.logo,
    this.logoImage,
    required this.backgroundColor,
    this.deliveryFee = '',
    this.deliveryFeeAmount = 0,
    this.specialNote,
    this.isOpen = true,
    this.workingHours = '09:00 ص – 12:00 ص',
    this.workingDays = 'يومياً',
    this.categoryId = 'restaurants',
    this.categoryName = 'مطاعم',
    this.directoryKeys = const [],
  });

  final String id;
  final String name;
  final IconData logo;
  final String? logoImage;
  final Color backgroundColor;
  final String deliveryFee;
  final double deliveryFeeAmount;
  final String? specialNote;

  /// ★ `shops.is_open` صارت **إيقافاً يدوياً** فوق جدول الأوقات، لا
  ///   «مفتوح دائماً»: تشغيل = الوقت يقرر، وإيقاف = مغلق مهما قال الوقت.
  ///   لذلك لا تقرأ هذه الخاصية مباشرة للعرض — اقرأ [statusAt].
  final bool isOpen;
  final String workingHours;
  final String workingDays;
  final String categoryId;
  final String categoryName;

  /// مفاتيح أقسام دليل الرئيسية (`doctor_categories.key`) التي تظهر
  /// فيها بطاقة هذه الصيدلية — يضبطها الأدمن من «الصيدليات».
  /// فارغة = لا بطاقة لها في الدليل مهما كان قسمها.
  final List<String> directoryKeys;

  /// الحالة من الوقت الحقيقي: مفتوح الآن؟ ومتى يفتح/يغلق فعلاً.
  ShopStatus statusAt([DateTime? at]) => shopStatusAt(
    workingHours: workingHours,
    workingDays: workingDays,
    manualOpen: isOpen,
    at: at,
  );

  /// هل يُسمح بإضافة منتجاته للسلة الآن؟
  bool get openForOrders => statusAt().isOpen;
}
