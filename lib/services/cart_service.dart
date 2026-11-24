import 'package:flutter/material.dart';

import '../models/product.dart';
import 'shop_hours_store.dart';

class CartItemModel {
  CartItemModel({
    required this.product,
    this.quantity = 1,
  });

  final Product product;
  int quantity;

  double get totalPrice => product.price * quantity;
}

class CartService extends ChangeNotifier {
  CartService._internal();

  static final CartService instance = CartService._internal();

  final List<CartItemModel> _items = [];

  List<CartItemModel> get items => List.unmodifiable(_items);

  int get totalItemCount {
    var count = 0;
    for (final item in _items) {
      count += item.quantity;
    }
    return count;
  }

  double get subtotal {
    var sum = 0.0;
    for (final item in _items) {
      sum += item.totalPrice;
    }
    return sum;
  }

  /// لا توجد رسوم توصيل؛ التوصيل ضمن مكافآت نادي النقاط أو مجاني.
  double get deliveryFee => 0.0;

  double get total => subtotal + deliveryFee;

  /// ★ الإضافة تمر ببوابة واحدة: صيدليةٌ خارج وقته لا يدخل سلعته السلة،
  ///   أياً كانت الصفحة التي ضغط منها الزبون.
  ///
  ///   تُرجع **null** حين أُضيفت، و**نصَّ المنع** حين رُفضت — فيُعرض النص
  ///   كما هو ويقول للزبون متى يفتح الصيدلية فعلاً. الاختيار أن تُرجع الرسالة
  ///   لا أن ترمي استثناءً: المستدعون كثيرون (بطاقة، صف، شبكة، تفاصيل منتج،
  ///   شورتس) ولا ينبغي أن يعرف كل واحد منها صيغة الرفض.
  ///
  ///   قبل هذا كان المنع في الودجات وحدها، فكانت ثلاث صفحات تمرّر
  ///   `isStoreOpen: true` ثابتاً وتضيف منتجات الصيدليات المغلقة بلا سؤال.
  String? addToCart(Product product, {int quantity = 1}) {
    final block = ShopHoursStore.instance.blockMessageFor(
      product.shopId,
      fallbackName: product.shopName,
    );
    if (block != null) return block;

    final index = _items.indexWhere((it) => it.product.id == product.id);
    if (index >= 0) {
      _items[index].quantity += quantity;
    } else {
      _items.add(CartItemModel(product: product, quantity: quantity));
    }
    notifyListeners();
    return null;
  }

  /// ★ زيادة الكمية من داخل السلة تخضع لنفس البوابة: الصيدلية قد يغلق بعد
  ///   أن وضع الزبون سلعته، فلا تُقبل كمية جديدة على صيدلية مغلق.
  ///   الإنقاص والحذف يبقيان مفتوحين دائمًا — منعُهما يحبس الزبون في سلة
  ///   لا يملك أن يفرّغها.
  String? updateQuantity(String productId, int delta) {
    final index = _items.indexWhere((it) => it.product.id == productId);
    if (index < 0) return null;

    if (delta > 0) {
      final product = _items[index].product;
      final block = ShopHoursStore.instance.blockMessageFor(
        product.shopId,
        fallbackName: product.shopName,
      );
      if (block != null) return block;
    }

    final newQty = _items[index].quantity + delta;
    if (newQty <= 0) {
      _items.removeAt(index);
    } else {
      _items[index].quantity = newQty;
    }
    notifyListeners();
    return null;
  }

  void removeItem(String productId) {
    _items.removeWhere((it) => it.product.id == productId);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }
}
