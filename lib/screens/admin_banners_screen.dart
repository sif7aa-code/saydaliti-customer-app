import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/real_data_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/app_image.dart';
import '../widgets/emerald_banner_background.dart';

/// إدارة البانرات الإعلانية: إضافة بانر مع صورة من المعرض، ضبط سرعة التقليب، حذف.
class AdminBannersScreen extends StatefulWidget {
  const AdminBannersScreen({super.key});

  @override
  State<AdminBannersScreen> createState() => _AdminBannersScreenState();
}

class _AdminBannersScreenState extends State<AdminBannersScreen> {
  Future<List<Map<String, dynamic>>>? _bannersFuture;

  /// ★ وجهات النقر: حسابات الأطباء والصيدليات والكوزمتك.
  List<Map<String, dynamic>> _doctors = const [];
  List<Map<String, dynamic>> _shops = const [];
  Map<String, String> _catNames = const {};
  bool _targetsLoaded = false;

  /// كلمات تدلّ على قسم «كوزمتك» في أسماء الأقسام التي ينشئها الأدمن.
  static const List<String> _cosmeticHints = [
    'كوزمتك',
    'تجميل',
    'جمال',
    'مكياج',
    'عطور',
    'مستحضر',
    'cosmetic',
    'beauty',
    'makeup',
    'perfume',
  ];

  @override
  void initState() {
    super.initState();
    _bannersFuture = _fetchBanners();
    unawaited(_loadTargets());
  }

  /// جلب قوائم الوجهات مرة واحدة؛ فشل أي قائمة يتركها فارغة فقط.
  Future<void> _loadTargets() async {
    final results = await Future.wait([
      SupabaseService.instance.fetchDoctors(),
      SupabaseService.instance.fetchShops(),
      SupabaseService.instance.fetchCategories(),
    ]);
    if (!mounted) return;
    setState(() {
      _doctors = results[0];
      _shops = results[1];
      _catNames = {
        for (final c in results[2])
          c['id']?.toString() ?? '': (c['name_ar'] ?? c['name_en'] ?? '')
              .toString(),
      };
      _targetsLoaded = true;
    });
  }

  String _categoryNameOf(Map<String, dynamic> shop) =>
      _catNames[shop['category_id']?.toString() ?? ''] ?? '';

  bool _isCosmeticShop(Map<String, dynamic> shop) {
    // اسم المتجر أيضاً: حساب «كوزمتك صافي سنتر» الحقيقي قسمه محايد
    // («تجريبي العناية»)، فبلا فحص الاسم كان يغيب عن قائمة الكوزمتك.
    final text = '${_categoryNameOf(shop)} ${shop['name'] ?? ''}'.toLowerCase();
    for (final hint in _cosmeticHints) {
      if (text.contains(hint)) return true;
    }
    return false;
  }

  List<Map<String, dynamic>> get _cosmeticShops =>
      _shops.where(_isCosmeticShop).toList(growable: false);

  List<Map<String, dynamic>> get _otherShops =>
      _shops.where((s) => !_isCosmeticShop(s)).toList(growable: false);

  String _doctorLabel(Map<String, dynamic> row) {
    final name = row['name']?.toString().trim() ?? '';
    final spec = (row['specialty'] ?? row['title'] ?? '').toString().trim();
    if (name.isEmpty) return 'طبيب';
    return spec.isEmpty ? name : '$name — $spec';
  }

  String _shopLabel(Map<String, dynamic> row) {
    final name = row['name']?.toString().trim() ?? '';
    final cat = _categoryNameOf(row);
    if (name.isEmpty) return 'حساب';
    return cat.isEmpty ? name : '$name — $cat';
  }

  /// الوجهة الحالية لبانر محفوظ، بنفس صيغة التخزين.
  ({String? kind, String? id}) _destinationOf(Map<String, dynamic> banner) {
    final target = banner['target_url']?.toString().trim() ?? '';
    if (target.startsWith('doctor:')) {
      final id = target.substring('doctor:'.length).trim();
      if (id.isNotEmpty) return (kind: 'doctor', id: id);
    }
    final shopId = banner['shop_id']?.toString().trim() ?? '';
    if (shopId.isNotEmpty && shopId != 'null') {
      Map<String, dynamic>? shop;
      for (final s in _shops) {
        if (s['id']?.toString() == shopId) {
          shop = s;
          break;
        }
      }
      final cosmetic = shop != null && _isCosmeticShop(shop);
      return (kind: cosmetic ? 'cosmetics' : 'shop', id: shopId);
    }
    return (kind: null, id: null);
  }

  String _destinationLabel(Map<String, dynamic> banner) {
    final dest = _destinationOf(banner);
    if (dest.kind == 'doctor') {
      for (final d in _doctors) {
        if (d['id']?.toString() == dest.id) {
          return 'حساب طبيب: ${d['name']}';
        }
      }
      return 'حساب طبيب';
    }
    if (dest.kind != null) {
      for (final s in _shops) {
        if (s['id']?.toString() == dest.id) {
          return 'حساب ${dest.kind == 'cosmetics' ? 'كوزمتك' : 'صيدلية'}: '
              '${s['name']}';
        }
      }
      return dest.kind == 'cosmetics' ? 'حساب كوزمتك' : 'حساب صيدلية';
    }
    final target = banner['target_url']?.toString().trim() ?? '';
    if (target.isNotEmpty && target != 'null') return 'رابط خارجي';
    return 'بدون وجهة (تُفتح صفحة الصيدليات)';
  }

  Future<List<Map<String, dynamic>>> _fetchBanners() async {
    final rows = await SupabaseService.instance.fetchBanners();
    await RealDataService.instance.clearCache();
    RealDataService.instance.catalogGeneration.value++;
    return rows;
  }

  Future<void> _refresh() async {
    final future = _fetchBanners();
    setState(() => _bannersFuture = future);
    await future;
  }

  void _showMessage(String msg, bool ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
        ),
      );
  }

  /// لوحة ألوان البانر كما ستظهر تماماً للزبون: نفس مولّد
  /// `EmeraldBannerPalette` المستخدم في العرض.
  EmeraldBannerPalette _paletteFor(String? hex) =>
      EmeraldBannerPalette.of(_seedColor(hex));

  Color _seedColor(String? hex) {
    final raw = (hex ?? '').trim().toUpperCase();
    switch (raw) {
      case 'GREEN':
        return AppColors.primary;
      case 'ORANGE':
        return const Color(0xFFB45309);
      case 'BLUE':
        return AppColors.primaryDark;
    }
    var h = raw.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return AppColors.primary;
    final v = int.tryParse(h, radix: 16);
    return v == null ? AppColors.primary : Color(v);
  }

  /// `#RRGGBB` من لون، بدون `alpha` — نفس الصيغة التي يقرأها مولّد اللوحة.
  String _hexOf(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// معاينة البانر بنفس بنية العرض النهائي (زوايا مقصوصة).
  Widget _bannerPreview(
    String? hex, {
    required String label,
    required IconData icon,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 74,
        child: Stack(
          fit: StackFit.expand,
          children: [
            EmeraldBannerBackground(
              palette: _paletteFor(hex),
              borderRadius: 14,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: Colors.white.withValues(alpha: 0.9),
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        shadows: const [
                          Shadow(color: Color(0x66000000), blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateColor(String bannerId, Color seed) async {
    final hex =
        '#${(seed.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final ok = await SupabaseService.instance.updateBanner(bannerId, {
      'color_hex': hex,
    });
    if (!mounted) return;
    _showMessage(
      ok
          ? 'تم تحديث اللون'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر تحديث اللون'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _refresh();
  }

  Future<void> _updateSpeed(String bannerId, int seconds) async {
    final ok = await SupabaseService.instance.updateBanner(bannerId, {
      'speed_seconds': seconds,
    });
    if (!mounted) return;
    _showMessage(
      ok
          ? 'تم تحديث السرعة'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر تحديث السرعة'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _refresh();
  }

  /// قسم «الانتقال عند النقر»: طبيب أو صيدلية أو كوزمتك أو بدون.
  ///
  /// يُستخدم في نموذج الإضافة وفي تعديل وجهة بانر محفوظ، فيبقى التخزين
  /// واحداً: الطبيب في `target_url` بصيغة `doctor:<id>`، والصيدلية/
  /// الكوزمتك في `shop_id`.
  Widget _destinationSection({
    required String? kind,
    required String? id,
    required ValueChanged<String?> onKind,
    required ValueChanged<String?> onId,
  }) {
    final options = switch (kind) {
      'doctor' => _doctors,
      'shop' => _otherShops,
      'cosmetics' => _cosmeticShops,
      _ => const <Map<String, dynamic>>[],
    };
    final labelOf = kind == 'doctor' ? _doctorLabel : _shopLabel;
    final validId = options.any((r) => r['id']?.toString() == id) ? id : null;
    const emptyText = {
      'doctor': 'لا توجد حسابات أطباء مسجّلة.',
      'shop': 'لا توجد حسابات صيدليات.',
      'cosmetics': 'لا توجد حسابات كوزمتك — الحساب يظهر هنا إذا احتوى '
          'اسمه أو اسم قسمه على «كوزمتك» أو «تجميل».',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'الانتقال عند النقر على البانر',
          style: GoogleFonts.cairo(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'اختر الحساب الذي يُفتح للزبون عند النقر',
          style: GoogleFonts.cairo(
            fontSize: 10.5,
            color: AppColors.textHint,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final opt in const [
              ('none', 'بدون'),
              ('doctor', 'طبيب'),
              ('shop', 'صيدلية'),
              ('cosmetics', 'كوزمتك'),
            ])
              ChoiceChip(
                label: Text(
                  opt.$2,
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: (kind ?? 'none') == opt.$1
                        ? Colors.white
                        : AppColors.textPrimary,
                  ),
                ),
                selected: (kind ?? 'none') == opt.$1,
                selectedColor: AppColors.primary,
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFE3EFE5)),
                showCheckmark: false,
                onSelected: (_) => onKind(opt.$1 == 'none' ? null : opt.$1),
              ),
          ],
        ),
        if (kind != null) ...[
          const SizedBox(height: 10),
          if (options.isEmpty)
            Text(
              emptyText[kind] ?? 'لا توجد حسابات.',
              style: GoogleFonts.cairo(
                fontSize: 11,
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
              ),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: validId,
              isExpanded: true,
              style: GoogleFonts.cairo(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: switch (kind) {
                  'doctor' => 'حساب الطبيب',
                  'cosmetics' => 'حساب الكوزمتك',
                  _ => 'حساب الصيدلية',
                },
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              items: [
                for (final row in options)
                  DropdownMenuItem(
                    value: row['id'].toString(),
                    child: Text(
                      labelOf(row),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onId,
            ),
        ],
      ],
    );
  }

  /// تعديل وجهة بانر محفوظ بلا حذفه وإعادة إضافته.
  Future<void> _editDestination(Map<String, dynamic> banner) async {
    final current = _destinationOf(banner);
    final currentTarget = banner['target_url']?.toString().trim() ?? '';
    var kind = current.kind;
    var id = current.id;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'الانتقال عند النقر',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
          ),
          content: SingleChildScrollView(
            child: _destinationSection(
              kind: kind,
              id: id,
              onKind: (k) => setDialogState(() {
                kind = k;
                id = null;
              }),
              onId: (v) => setDialogState(() => id = v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء', style: GoogleFonts.cairo()),
            ),
            FilledButton(
              onPressed: () {
                if (kind != null && id == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(
                        'اختر الحساب الذي ينتقل إليه البانر',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                      ),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: AppColors.danger,
                    ),
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: Text(
                'حفظ',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    // «بدون» يلغي وجهة الحساب فقط ويُبقي الرابط الخارجي إن كان رابطاً.
    final keepExternal =
        kind == null &&
        currentTarget.isNotEmpty &&
        !currentTarget.startsWith('doctor:');
    final values = <String, dynamic>{
      'target_url': kind == 'doctor'
          ? 'doctor:$id'
          : (keepExternal ? currentTarget : null),
      'shop_id': (kind == 'shop' || kind == 'cosmetics') ? id : null,
    };
    final ok = await SupabaseService.instance.updateBanner(
      banner['id'].toString(),
      values,
    );
    if (!mounted) return;
    _showMessage(
      ok
          ? 'تم ربط البانر بالوجهة المختارة'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر تحديث وجهة البانر'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _refresh();
  }

  Future<void> _addBanner() async {
    final titleCtrl = TextEditingController();
    final subtitleCtrl = TextEditingController();
    final badgeCtrl = TextEditingController();
    final linkCtrl = TextEditingController();
    String? newImageUrl;
    // ★ وجهة النقر (حساب طبيب/صيدلية/كوزمتك) — تُختار من قسم مستقل.
    String? destKind;
    String? destId;
    // ★ حقيبة الصور المرفوعة في هذا النموذج — تُمسح إن أُلغي أو فشل الإدراج.
    final uploads = AdminUploads();
    var speed = 6.0;
    // ★ لون البانر: يبدأ بلون مختلف عن كل البانرات القائمة تلقائياً،
    //   فلا يخرج بانران بنفس اللون إلا باختيار الأدمن يدوياً.
    var seedColor = EmeraldBannerPalette.presetSeeds.first;
    final usedColors = <String>{};
    for (final row in await SupabaseService.instance.fetchBanners()) {
      final h = row['color_hex']?.toString().trim().toUpperCase() ?? '';
      if (h.isNotEmpty) usedColors.add(h);
    }
    for (final preset in EmeraldBannerPalette.presetSeeds) {
      final hex = preset
          .toARGB32()
          .toRadixString(16)
          .substring(2)
          .toUpperCase();
      if (!usedColors.contains(hex)) {
        seedColor = preset;
        break;
      }
    }
    if (!_targetsLoaded) {
      await _loadTargets();
      if (!mounted) return;
    }

    if (!mounted) return;

    final picked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'إضافة بانر جديد',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                AdminImageUploader(
                  folder: 'banners',
                  height: 130,
                  uploads: uploads,
                  icon: Icons.image_rounded,
                  placeholder:
                      'اختار صورة من المعرض (تُرفع للسيرفر وتظهر للجميع)',
                  onChanged: (url) => newImageUrl = url,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: titleCtrl,
                  textAlign: TextAlign.right,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: 'عنوان البانر',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: subtitleCtrl,
                  textAlign: TextAlign.right,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: 'نص فرعي (اختياري)',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: badgeCtrl,
                  textAlign: TextAlign.right,
                  maxLength: 20,
                  decoration: InputDecoration(
                    labelText: 'شارة (اختياري)',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _destinationSection(
                  kind: destKind,
                  id: destId,
                  onKind: (k) => setSheetState(() {
                    destKind = k;
                    destId = null;
                  }),
                  onId: (v) => setSheetState(() => destId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: linkCtrl,
                  textAlign: TextAlign.right,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'رابط خارجي — بديل عن اختيار حساب (اختياري)',
                    hintText: 'https://example.com',
                    prefixIcon: const Icon(Icons.link_rounded, size: 20),
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'لون البانر',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                _ColorPicker(
                  selected: seedColor,
                  onChanged: (c) => setSheetState(() => seedColor = c),
                ),
                const SizedBox(height: 10),
                _bannerPreview(
                  _hexOf(seedColor),
                  label: titleCtrl.text.trim().isEmpty
                      ? 'معاينة البانر'
                      : titleCtrl.text.trim(),
                  icon: Icons.local_offer_rounded,
                ),
                const SizedBox(height: 12),
                Text(
                  'مدة عرض كل بانر: ${speed.round()} ثانية',
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'رقم أصغر = أسرع تقليب (من ٣ إلى ٣٠ ثانية)',
                  style: GoogleFonts.cairo(
                    fontSize: 10.5,
                    color: AppColors.textHint,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Slider(
                  value: speed,
                  min: 3,
                  max: 30,
                  divisions: 27,
                  activeColor: AppColors.primary,
                  label: '${speed.round()} ثانية',
                  onChanged: (v) => setSheetState(() => speed = v),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () {
                    final title = titleCtrl.text.trim();
                    if (title.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(
                            'أدخل عنوان البانر',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: AppColors.danger,
                        ),
                      );
                      return;
                    }
                    if (destKind != null && destId == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(
                            'اختر الحساب الذي ينتقل إليه البانر',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: AppColors.danger,
                        ),
                      );
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'حفظ البانر',
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked != true) {
      uploads.discard();
      return;
    }
    final title = titleCtrl.text.trim();
    final subtitle = subtitleCtrl.text.trim();
    final badge = badgeCtrl.text.trim();
    final link = linkCtrl.text.trim();
    // ★ اختيار حساب يحدّد الوجهة: الطبيب في `target_url` بصيغة
    //   `doctor:<id>`، والصيدلية/الكوزمتك في `shop_id`.
    final destDoctor = destKind == 'doctor';
    final destShop = destKind == 'shop' || destKind == 'cosmetics';
    final ok = await SupabaseService.instance.addBanner(
      title: title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      badge: badge.isEmpty ? null : badge,
      speedSeconds: speed.round(),
      sortOrder: 0,
      imagePath: newImageUrl,
      imageUrl: newImageUrl,
      targetUrl: destDoctor ? 'doctor:$destId' : (link.isEmpty ? null : link),
      shopId: destShop ? destId : null,
      colorHex: _hexOf(seedColor),
    );
    if (!mounted) return;
    // ★ الصورة تُرفع قبل الإدراج؛ فلا يُعتمد بقاءها في السحابة إلا بنجاح
    //   الصف في القاعدة، وإلا أُلغيت النافذة.
    if (ok) {
      uploads.keep();
    } else {
      uploads.discard();
    }
    linkCtrl.dispose();
    _showMessage(
      ok
          ? 'تمت إضافة البانر'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر إضافة البانر'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _refresh();
  }

  Future<void> _deleteBanner(Map<String, dynamic> banner) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف البانر',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل تريد حذف "${banner['title']}"؟',
          style: GoogleFonts.cairo(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'حذف',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await SupabaseService.instance.deleteBanner(
      banner['id'].toString(),
    );
    if (!mounted) return;
    _showMessage(
      ok
          ? 'تم حذف البانر'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر حذف البانر'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
    if (ok) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'إدارة البانرات الإعلانية',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addBanner,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'إضافة بانر',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _bannersFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                'حدث خطأ أثناء تحميل البانرات',
                style: GoogleFonts.cairo(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
            );
          }
          final banners = snap.data ?? const <Map<String, dynamic>>[];
          return AppRefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refresh,
            child: banners.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 140),
                      const Icon(
                        Icons.view_carousel_rounded,
                        size: 64,
                        color: AppColors.textHint,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          'لا توجد بانرات بعد',
                          style: GoogleFonts.cairo(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: banners.length,
                    itemBuilder: (_, i) {
                      final banner = banners[i];
                      final image =
                          banner['image_path']?.toString() ??
                          banner['image_url']?.toString() ??
                          '';
                      final colorHex = banner['color_hex']?.toString();
                      final badge = banner['badge']?.toString() ?? '';
                      final subtitle = banner['subtitle']?.toString() ?? '';
                      final speed = (banner['speed_seconds'] is num)
                          ? (banner['speed_seconds'] as num).toInt()
                          : 4;
                      return Card(
                        elevation: 1.5,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: SizedBox(
                                      width: 56,
                                      height: 56,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          EmeraldBannerBackground(
                                            palette: _paletteFor(colorHex),
                                            borderRadius: 12,
                                          ),
                                          const Icon(
                                            Icons.local_offer_rounded,
                                            color: Colors.white,
                                            size: 26,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (badge.isNotEmpty) ...[
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppColors.primaryLight,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              badge,
                                              style: GoogleFonts.cairo(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w800,
                                                color: AppColors.primary,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                        ],
                                        Text(
                                          banner['title']?.toString() ?? 'بانر',
                                          style: GoogleFonts.cairo(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        if (subtitle.isNotEmpty) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            subtitle,
                                            style: GoogleFonts.cairo(
                                              fontSize: 11,
                                              color: AppColors.textSecondary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      color: AppColors.danger,
                                    ),
                                    onPressed: () => _deleteBanner(banner),
                                  ),
                                ],
                              ),
                              if (image.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                // ★ بلا قصّ وبلا أقواس: الصورة كاملة حتى
                                //   الحواف (كان القصّ المستدير يقطع الشرائط
                                //   الفاتحة عند الزوايا).
                                AppImage(
                                  image,
                                  width: double.infinity,
                                  height: 90,
                                  // ★ الصورة كاملة بلا اقتطاع — نفس ما
                                  //   يظهر للزبون في البانر (contain).
                                  fit: BoxFit.contain,
                                ),
                              ],
                              const SizedBox(height: 10),
                              Text(
                                'لون البانر',
                                style: GoogleFonts.cairo(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _ColorPicker(
                                selected: _seedColor(colorHex),
                                onChanged: (c) =>
                                    _updateColor(banner['id'].toString(), c),
                              ),
                              const SizedBox(height: 10),
                              _BannerSpeedSlider(
                                initialSeconds: speed,
                                onChangedEnd: (s) =>
                                    _updateSpeed(banner['id'].toString(), s),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.ads_click_rounded,
                                    size: 16,
                                    color: AppColors.textSecondary,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'النقر يفتح: ${_destinationLabel(banner)}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.cairo(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _editDestination(banner),
                                    child: Text(
                                      'تغيير الوجهة',
                                      style: GoogleFonts.cairo(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

/// منتقي ألوان البانر: لوحة دوائر ملوّنة، والاختيار يظهر فوراً في المعاينة.
class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.selected, required this.onChanged});

  final Color selected;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final seed in EmeraldBannerPalette.presetSeeds)
          _Swatch(
            seed: seed,
            active: seed.toARGB32() == selected.toARGB32(),
            onTap: () => onChanged(seed),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.seed,
    required this.active,
    required this.onTap,
  });

  final Color seed;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 46,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.textPrimary : Colors.transparent,
            width: 2.4,
          ),
        ),
        padding: const EdgeInsets.all(2.5),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              EmeraldBannerBackground(
                palette: EmeraldBannerPalette.of(seed),
                borderRadius: 8,
              ),
              if (active)
                const Icon(
                  Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 18,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// شريط التحكم الحيّ بسرعة التقليب (3..30 ثانية) مع الحفظ عند انتهاء السحب.
///
/// ★ المدى ٣–٣٠ هو نفسه الذي يفرضه `BannerCarousel` والخدمة:
///   ما يُعرض هنا هو ما يحصل فعلاً، فلا يظنّ الأدمن أن قيمة أخرى تعمل.
class _BannerSpeedSlider extends StatefulWidget {
  const _BannerSpeedSlider({
    required this.initialSeconds,
    required this.onChangedEnd,
  });

  final int initialSeconds;
  final ValueChanged<int> onChangedEnd;

  @override
  State<_BannerSpeedSlider> createState() => _BannerSpeedSliderState();
}

class _BannerSpeedSliderState extends State<_BannerSpeedSlider> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialSeconds.clamp(3, 30).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'سرعة التقليب: ${_value.round()} ثانية',
          style: GoogleFonts.cairo(
            fontSize: 12,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
        Slider(
          value: _value,
          min: 3,
          max: 30,
          divisions: 27,
          activeColor: AppColors.primary,
          label: '${_value.round()}',
          onChanged: (v) => setState(() => _value = v),
          onChangeEnd: (v) => widget.onChangedEnd(v.round()),
        ),
      ],
    );
  }
}
