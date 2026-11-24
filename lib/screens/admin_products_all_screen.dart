import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import 'admin_products_screen.dart';

/// اختيار الصيدلية لإدارة منتجاته — نقطة وصول واحدة لكل الصيدليات
/// (بدل تكرار زرّين يفتحان نفس الشاشة).
class AdminProductsAllScreen extends StatefulWidget {
  const AdminProductsAllScreen({super.key});

  @override
  State<AdminProductsAllScreen> createState() => _AdminProductsAllScreenState();
}

class _AdminProductsAllScreenState extends State<AdminProductsAllScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _shops = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shops = await SupabaseService.instance.fetchShops();
    if (!mounted) return;
    setState(() {
      _shops = shops;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'إدارة المنتجات',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AppRefreshIndicator(
              onRefresh: _load,
              child: _shops.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 160),
                        Center(
                          child: Text(
                            'لا توجد صيدليات بعد',
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      itemCount: _shops.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final s = _shops[i];
                        final name = s['name']?.toString() ?? 'صيدلية';
                        final id = s['id']?.toString() ?? '';
                        return Card(
                          elevation: 1.5,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: AppColors.primaryLight,
                              child: Icon(
                                Icons.storefront_rounded,
                                color: AppColors.primary,
                              ),
                            ),
                            title: Text(
                              name,
                              style: GoogleFonts.cairo(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              s['is_open'] == false ? 'مغلق' : 'مفتوح',
                              style: GoogleFonts.cairo(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: s['is_open'] == false
                                    ? AppColors.danger
                                    : AppColors.success,
                              ),
                            ),
                            trailing: const Icon(Icons.chevron_left_rounded),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AdminProductsScreen(shopId: id),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
