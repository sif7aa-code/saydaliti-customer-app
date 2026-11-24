import 'package:flutter/material.dart';

import '../models/category_item.dart';
import '../models/product.dart';
import 'product_row.dart';
import 'section_header.dart';

/// قسم أقسام على الصفحة الرئيسية: عنوان القسم ثم منتجاته
/// كصف أفقي قابل للتمرير يميناً ويساراً.
class CategoryProductSection extends StatelessWidget {
  const CategoryProductSection({
    super.key,
    required this.category,
    required this.products,
    this.closedShopIds = const <String>{},
    this.onProductTap,
    this.onViewAll,
  });

  final CategoryItem category;

  /// منتجات القسم (تُعرض مرتبة حسب الأحدث أولاً).
  final List<Product> products;

  final Set<String> closedShopIds;
  final ValueChanged<Product>? onProductTap;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SectionHeader(
            title: category.title,
            icon: category.icon,
            onViewAll: onViewAll,
          ),
        ),
        const SizedBox(height: 12),
        ProductRow(
          products: products,
          closedShopIds: closedShopIds,
          onProductTap: onProductTap,
        ),
        const SizedBox(height: 26),
      ],
    );
  }
}
