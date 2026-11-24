import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../models/product.dart';
import '../models/shop.dart';
import '../services/real_data_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import 'product_details_screen.dart';
import 'shop_details_screen.dart';

/// شاشة نتائج البحث الموحّدة: منتجات + صيدليات لكل المستخدمين.
class SearchResultsScreen extends StatefulWidget {
  const SearchResultsScreen({super.key, required this.query});

  final String query;

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  List<Product> _products = const [];
  List<Shop> _shops = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run({bool showLoader = true}) async {
    final q = widget.query.trim();
    if (q.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (showLoader) setState(() => _loading = true);

    // بحث محلي فوري من البيانات المحمّلة (أسرع وأضمن).
    final needle = q.toLowerCase();
    final allProducts = await RealDataService.instance.fetchProducts();
    final allShops = await RealDataService.instance.fetchAllShops();
    if (!mounted) return;

    final products = allProducts
        .where((p) => p.name.toLowerCase().contains(needle))
        .toList();
    final shops = allShops
        .where((s) => s.name.toLowerCase().contains(needle))
        .toList();

    setState(() {
      _products = products;
      _shops = shops;
      _loading = false;
    });

    // لاحقاً: بحث السيرفر عن الأسماء غير المحمّلة (يحدّث النتائج إن وُجد).
    unawaited(_remoteSearch(q));
  }

  Future<void> _remoteSearch(String q) async {
    try {
      final rows = await SupabaseService.instance.globalSearch(q);
      if (rows.isEmpty || !mounted) return;
      final needle = q.toLowerCase();
      var changed = false;
      for (final r in rows) {
        // الصيدليات تظهر في قسمها الخاص، فلا تُحوَّل إلى منتجات.
        if ((r['kind']?.toString() ?? 'product') != 'product') continue;
        final name = r['name']?.toString() ?? '';
        if (name.toLowerCase().contains(needle) &&
            _products.every((p) => p.name != name)) {
          final price = (r['price'] as num?)?.toDouble() ?? 0;
          final image = (r['logo_image'] ?? r['image_path'] ?? r['image'])
              ?.toString();
          final shopId = r['shop_id']?.toString() ?? '';
          final shopName = r['shop_name']?.toString() ?? '';
          _products = [
            ..._products,
            Product(
              id: r['id'].toString(),
              name: name,
              shopId: shopId,
              shopName: shopName,
              price: price,
              logoImage: (image == null || image.isEmpty) ? null : image,
              backgroundColor: AppColors.imageBackground,
            ),
          ];
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final total = _products.length + _shops.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'نتائج البحث',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              onRefresh: () => _run(showLoader: false),
              child: total == 0
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      children: [
                        const SizedBox(height: 100),
                        const Icon(
                          Icons.search_off_rounded,
                          size: 64,
                          color: AppColors.textHint,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'لا توجد نتائج لـ "${widget.query}"',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.cairo(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_shops.isNotEmpty) ...[
                          _SectionLabel(
                            text: 'الصيدليات (${_shops.length})',
                            icon: Icons.storefront_rounded,
                          ),
                          const SizedBox(height: 8),
                          for (final s in _shops)
                            ListTile(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ShopDetailsScreen(shop: s),
                                ),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  width: 46,
                                  height: 46,
                                  child: s.logoImage == null
                                      ? const Icon(Icons.storefront_rounded)
                                      : AppImage(
                                          s.logoImage!,
                                          fit: BoxFit.cover,
                                          cacheWidth: 140,
                                          cacheHeight: 140,
                                        ),
                                ),
                              ),
                              title: Text(
                                s.name,
                                style: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                s.isOpen ? 'مفتوح الآن' : 'مغلق',
                                style: GoogleFonts.cairo(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: s.isOpen
                                      ? AppColors.success
                                      : AppColors.danger,
                                ),
                              ),
                              trailing: const Icon(Icons.chevron_left_rounded),
                            ),
                          const SizedBox(height: 18),
                        ],
                        if (_products.isNotEmpty) ...[
                          _SectionLabel(
                            text: 'المنتجات (${_products.length})',
                            icon: Icons.shopping_bag_rounded,
                          ),
                          const SizedBox(height: 8),
                          for (var i = 0; i < _products.length; i++)
                            Builder(
                              builder: (context) {
                                final p = _products[i];
                                return ListTile(
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ProductDetailsScreen(
                                        products: _products,
                                        initialIndex: i,
                                        isStoreOpen: true,
                                      ),
                                    ),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: SizedBox(
                                      width: 46,
                                      height: 46,
                                      child: p.logoImage == null
                                          ? const Icon(Icons.fastfood_rounded)
                                          : AppImage(
                                              p.logoImage!,
                                              fit: BoxFit.cover,
                                              cacheWidth: 140,
                                              cacheHeight: 140,
                                            ),
                                    ),
                                  ),
                                  title: Text(
                                    p.name,
                                    style: GoogleFonts.cairo(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                  subtitle: Text(
                                    p.shopName,
                                    style: GoogleFonts.cairo(
                                      fontSize: 11.5,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                  trailing: Text(
                                    CurrencyFormatter.format(p.price),
                                    style: GoogleFonts.cairo(
                                      fontWeight: FontWeight.w900,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ],
                    ),
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 6),
        Text(
          text,
          style: GoogleFonts.cairo(
            fontWeight: FontWeight.w900,
            fontSize: 14,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}
