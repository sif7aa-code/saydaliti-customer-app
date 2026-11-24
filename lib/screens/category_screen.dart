import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/category_item.dart';
import '../models/product.dart';
import '../models/shop.dart';
import '../services/real_data_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/product_card.dart';
import '../widgets/section_header.dart';
import '../widgets/shop_card.dart';
import 'shop_details_screen.dart';
import 'product_details_screen.dart';

/// ألوان بطاقة القسم العلوية — نفس لوحة الأخضر/الأبيض المستخدمة في الرئيسية
/// وشاشة الصيدليات. خاصة بهذا الملف: لا تلمس `AppColors` ولا أي شاشة أخرى.
const Color _navy = AppColors.textPrimary;
const Color _blue = AppColors.primary;
const Color _tintLight = AppColors.primaryLight;
const Color _tintDeep = AppColors.surfaceTint;
const Color _iconBlue = AppColors.iconContainer;
const Color _muted = AppColors.textSecondary;

class CategoryScreen extends StatefulWidget {
  const CategoryScreen({super.key, required this.category});

  final CategoryItem category;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  List<Shop> _shops = const [];
  List<Product> _products = const [];

  /// حالة فتح الصيدلية keyed بالمعرّف.
  ///
  /// كان كل منتج يبحث في قائمة الصيدليات **مرتين** (`any` ثم `firstWhere`)
  /// داخل `build` ⇒ مسحَان كاملان لكل منتج في كل بناء، وقائمة `ListView`
  /// غير كسولة ⇒ كل بطاقة في القسم تُبنى وتطلب صورها دفعة واحدة.
  Map<String, bool> _shopOpenById = const {};

  @override
  void initState() {
    super.initState();
    // ★ إعادة الرسم عند تغيّر الكتالوج (تحديث خلفي بعد حذف منتج):
    //   وإلا بقي المنتج المحذوف معروضاً في القسم كل مدة فتح الشاشة.
    _onCatalogChanged = () {
      if (mounted) _load();
    };
    RealDataService.instance.catalogGeneration.addListener(_onCatalogChanged!);
    _load();
  }

  VoidCallback? _onCatalogChanged;

  @override
  void dispose() {
    final cb = _onCatalogChanged;
    if (cb != null) {
      RealDataService.instance.catalogGeneration.removeListener(cb);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      RealDataService.instance.fetchShopsByCategory(widget.category.id),
      RealDataService.instance.fetchProductsByCategory(widget.category.id),
    ]);
    if (!mounted) return;
    final shops = results[0] as List<Shop>;
    setState(() {
      _shops = shops;
      _products = results[1] as List<Product>;
      _shopOpenById = {for (final s in shops) s.id: s.isOpen};
    });
  }

  Future<void> _onRefresh() async {
    await _load();
  }

  void _openProduct(Product product) {
    var list = _products.where((p) => p.shopId == product.shopId).toList();
    if (list.isEmpty) list = [product];
    final index = list.indexWhere((p) => p.id == product.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductDetailsScreen(
          products: list,
          initialIndex: index < 0 ? 0 : index,
          isStoreOpen: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final category = widget.category;
    final shops = _shops;
    final products = _products;
    final shopOpen = _shopOpenById;

    // ترويسة + فاصل + ترويسة الصيدليات + جسم الصيدليات + فاصل + ترويسة المنتجات
    // + جسم المنتجات + فاصل.
    //
    // ★ الجسمان يُحسبان بعنصر واحد حتى وهما فارغان (رسالة «لا توجد…»)،
    //   والعدّاد القديم `8 + …` كان ينقص واحداً فآخر منتج يُستبدل بالفاصل
    //   الختامي — قسم بمنتج واحد كان يظهر بلا أي منتج تحته.
    final shopsBody = shops.isEmpty ? 1 : shops.length;
    final productsBody = products.isEmpty ? 1 : products.length;
    final itemCount = 9 + shopsBody + productsBody;

    return Scaffold(
      appBar: AppBar(
        title: Text(category.title),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_forward_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _onRefresh,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          // ★ 12 = حاشية الصفحة المقاسة من المرجع (17px ÷ 1.6)
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // 0..6: الترويسة وأقسام العناوين.
            if (index <= 1) {
              if (index == 0) return const SizedBox(height: 12);
              return _CategoryHeader(
                category: category,
                shops: shops,
                products: products,
              );
            }
            if (index == 2) return const SizedBox(height: 20);
            if (index == 3) {
              return SectionHeader(
                title: 'صيدليات ${category.title} (${shops.length})',
              );
            }
            if (index == 4) return const SizedBox(height: 12);

            // جسم الصيدليات.
            if (index < 5 + shopsBody) {
              if (shops.isEmpty)
                return const _EmptyNote(
                  'لا توجد صيدليات مسجلة في هذا القسم حالياً',
                );
              final i = index - 5;
              if (i < 0 || i >= shops.length) return const SizedBox.shrink();
              final shop = shops[i];
              return Column(
                children: [
                  RepaintBoundary(
                    child: ShopCard(
                      shop: shop,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ShopDetailsScreen(shop: shop),
                        ),
                      ),
                    ),
                  ),
                  if (i != shops.length - 1) const SizedBox(height: 12),
                ],
              );
            }

            // 5 + جسم الصيدليات : فاصل + ترويسة المنتجات + فاصل.
            final productHeadIndex = 5 + shopsBody;
            if (index == productHeadIndex) return const SizedBox(height: 24);
            if (index == productHeadIndex + 1) {
              return SectionHeader(
                title: 'منتجات قسم ${category.title} (${products.length})',
              );
            }
            if (index == productHeadIndex + 2)
              return const SizedBox(height: 12);

            // جسم المنتجات.
            if (index == itemCount - 1) return const SizedBox(height: 24);
            if (products.isEmpty) {
              return const _EmptyNote('لا توجد منتجات متاحة في هذا القسم');
            }
            final i = index - (productHeadIndex + 3);
            if (i < 0 || i >= products.length) return const SizedBox.shrink();
            final product = products[i];
            return Column(
              children: [
                RepaintBoundary(
                  child: ProductCard(
                    product: product,
                    showShopName: true,
                    // بحث O(1) بدل مسح القائمة مرتين لكل منتج.
                    isStoreOpen: shopOpen[product.shopId] ?? true,
                    onTap: () => _openProduct(product),
                  ),
                ),
                if (i != products.length - 1) const SizedBox(height: 12),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.category,
    required this.shops,
    required this.products,
  });

  final CategoryItem category;
  final List<Shop> shops;
  final List<Product> products;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // ★ أخضر فاتح مثل بطاقة «مندوب حر» في الرئيسية: أفتح أعلى اليمين
        //   وأعمق أسفل اليسار — بلا قص ولا تدرّج خارج اللوحة الجديدة.
        gradient: const LinearGradient(
          colors: [_tintLight, _tintDeep],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _iconBlue, width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: _iconBlue,
              shape: BoxShape.circle,
              border: Border.all(color: _blue.withValues(alpha: 0.35)),
            ),
            child: Icon(category.icon, color: _navy, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'قسم ${category.title}',
                  style: GoogleFonts.cairo(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: _navy,
                  ),
                ),
                Text(
                  '${shops.length} صيدليات متاحة  •  ${products.length} منتجات',
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    color: _muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Text(
          text,
          style: GoogleFonts.cairo(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
