import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/doctor_profile.dart';
import '../services/doctor_directory_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/doctor_list_card.dart';
import 'doctor_profile_screen.dart';

/// ★ تبويب «المفضلة» في الشريط السفلي: كل طبيب/مجمع/مختبر أُضيف إلى
///   المفضلة، كما هي في قلوب الدليل نفسها (SharedPreferences).
///
///   بلا فلتر مدينة أو قسم — «كل من أُضيف إلى المفضلة» حرفياً — ومعرّف
///   اختفى من الدليل يُسقط بدل عرض بطاقة معطوبة. النقرة تفتح البروفايل
///   كما في الرئيسية، والقلب يزيل البطاقة فوراً من هنا.
class FavoriteDoctorsScreen extends StatefulWidget {
  const FavoriteDoctorsScreen({super.key});

  @override
  State<FavoriteDoctorsScreen> createState() => _FavoriteDoctorsScreenState();
}

class _FavoriteDoctorsScreenState extends State<FavoriteDoctorsScreen>
    with TabRefreshTarget<FavoriteDoctorsScreen> {
  @override
  String get tabId => 'favs';

  @override
  Future<void> Function()? onTabRefresh() => _load;

  List<DoctorProfile> _all = DoctorDirectoryService.instance.initial;
  Set<String> _favs = <String>{};
  bool _loading = true;
  VoidCallback? _onDoctorsChanged;

  @override
  void initState() {
    super.initState();
    // إضافة/تعديل/حذف طبيب من اللوحة يظهر هنا فوراً كما في الدليل.
    _onDoctorsChanged = () => _load();
    DoctorDirectoryService.instance.generation.addListener(_onDoctorsChanged!);
    _load();
  }

  @override
  void dispose() {
    final cb = _onDoctorsChanged;
    if (cb != null) {
      DoctorDirectoryService.instance.generation.removeListener(cb);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final list = await DoctorDirectoryService.instance.fetch(force: false);
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() {
      _all = list;
      _favs = favs;
      _loading = false;
    });
  }

  List<DoctorProfile> get _favorites =>
      _all.where((d) => _favs.contains(d.id)).toList(growable: false);

  Future<void> _toggleFav(String id) async {
    await DoctorDirectoryService.instance.toggleFavorite(id);
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() => _favs = favs);
  }

  Future<void> _openProfile(DoctorProfile d) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DoctorProfileScreen(doctor: d)),
    );
    if (!mounted) return;
    // القلب قد يُطفأ من داخل البروفايل — تُعاد القراءة فور الرجوع.
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() => _favs = favs);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _favorites;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(rows.isEmpty ? 'المفضلة' : 'المفضلة (${rows.length})'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _load,
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : rows.isEmpty
            ? _empty()
            : ListView.separated(
                controller: tabScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final d = rows[i];
                  return DoctorListCard(
                    key: ValueKey<String>('fav:${d.id}'),
                    doctor: d,
                    isFav: true,
                    onFav: () => _toggleFav(d.id),
                    onTap: () => _openProfile(d),
                  );
                },
              ),
      ),
    );
  }

  Widget _empty() {
    return ListView(
      controller: tabScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 90),
        const Icon(
          Icons.favorite_border_rounded,
          size: 64,
          color: AppColors.textHint,
        ),
        const SizedBox(height: 16),
        Text(
          'لا يوجد في المفضلة بعد',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'اضغط القلب في بطاقة أي طبيب أو مجمع أو مختبر من الرئيسية '
          'لإضافته هنا. المفضلة محفوظة على جهازك وتظهر كلها بلا فلترة.',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            fontSize: 12.5,
            height: 1.6,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
