import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/contact_tools.dart';
import '../core/utils/social_link.dart';
import '../models/doctor_profile.dart';
import '../services/auth_service.dart';
import '../services/doctor_directory_service.dart';
import '../services/supabase_service.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/image_viewer.dart';
import '../widgets/working_hours_picker.dart';
import 'doctor_appointment_screen.dart';
import 'login_screen.dart';

/// بروفايل الطبيب/المجمع/المختبر — التصميم المرجعي (2026-11-19).
///
/// ★ نسخة مطابقة للمرجع بلا تقييم إطلاقاً: لا نجوم ولا «كيف كان تعاملك».
///   العدّادان زيارات الملف والمفضلة حقيقيان من القاعدة عبر
///   `visit_doctor_profile` و`toggle_doctor_favorite`
///   (tmp/doctors_profile.sql): الزيارة تُسجّل مرة واحدة لكل حساب مريض
///   أو IP، والمفضلة صف واحد لكل زائر.
///
///   الحقول المهنية (نبذة/دوام رسمي/ملاحظات/عنوان العيادة) يأتي بها
///   الأدمن من «إدارة الأطباء»، أو صاحب حساب الطبيب من زر التعديل هنا.
///   والقاعدة وحدها تقرر من يحقّ له: `update_doctor_profile_self`
///   (tmp/doctors_self_edit.sql) تسمح للأدمن أو لهاتف الحساب المطابق
///   لهاتف الطبيب، وترفض كل من سواهما.
class DoctorProfileScreen extends StatefulWidget {
  const DoctorProfileScreen({super.key, required this.doctor});

  final DoctorProfile doctor;

  @override
  State<DoctorProfileScreen> createState() => _DoctorProfileScreenState();
}

class _DoctorProfileScreenState extends State<DoctorProfileScreen> {
  late DoctorProfile _doctor = widget.doctor;

  DoctorProfileStats? _stats;
  bool _favBusy = false;

  DoctorProfile get d => _doctor;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  /// تسجيل الزيارة وجلب العدّادين. إن لم يُشغَّل ملف SQL بعد، تبقى
  /// الشاشة تعمل بالمفضلة المحلية وأصفار في العدّادات.
  Future<void> _loadStats() async {
    final stats = await DoctorDirectoryService.instance.visitProfile(d.id);
    if (!mounted) return;
    if (stats != null) {
      setState(() => _stats = stats);
      return;
    }
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() {
      _stats = DoctorProfileStats(
        visits: 0,
        favorites: 0,
        isFavorite: favs.contains(d.id),
      );
    });
  }

  /// السحب للتحديث: يجلب أحدث نسخة من ملف الطبيب من الشبكة (اسم/نبذة/
  /// دوام/عنوان/صورة كما عدّلها الأدمن أو صاحب الحساب) ثم يحدّث العدّادين.
  Future<void> _refresh() async {
    try {
      final all = await DoctorDirectoryService.instance.refreshNow();
      final match = all.where((x) => x.id == d.id);
      if (!mounted) return;
      if (match.isNotEmpty) setState(() => _doctor = match.first);
    } catch (_) {}
    await _loadStats();
  }

  Future<void> _toggleFavorite() async {
    if (_favBusy) return;
    setState(() => _favBusy = true);
    final stats = await DoctorDirectoryService.instance.toggleFavoriteRemote(
      d.id,
    );
    if (!mounted) return;
    if (stats != null) {
      // ★ نسخة قديمة من `toggle_doctor_favorite` كانت تعيد المفضلة وحدها
      //   بلا الزيارات، فتظهر الزيارات صفراً بعد أول نقرة. نحتفظ بالعدد
      //   المعروض إن جاء الرد بلا زيارات (والنسخة الجديدة ترسلها).
      final cur = _stats;
      setState(() {
        _stats = (cur == null || stats.visits > 0)
            ? stats
            : DoctorProfileStats(
                visits: cur.visits,
                favorites: stats.favorites,
                isFavorite: stats.isFavorite,
              );
        _favBusy = false;
      });
      return;
    }
    // احتياط بلا القاعدة: المفضلة المحلية (المعرّفات المرجعية المدمجة).
    final now = await DoctorDirectoryService.instance.toggleFavorite(d.id);
    if (!mounted) return;
    final cur = _stats;
    final base = cur?.favorites ?? 0;
    setState(() {
      _stats = DoctorProfileStats(
        visits: cur?.visits ?? 0,
        favorites: now ? base + 1 : (base > 0 ? base - 1 : 0),
        isFavorite: now,
      );
      _favBusy = false;
    });
  }

  // ---- صلاحية التعديل -------------------------------------------------

  static String _digits(String v) => v.replaceAll(RegExp(r'[^0-9]'), '');

  /// آخر ١٠ أرقام: تقارن 0770… و964770… بلا لبس.
  static String _last10(String v) {
    final s = _digits(v);
    return s.length > 10 ? s.substring(s.length - 10) : s;
  }

  /// زر التعديل للأدمن أو لهاتف الحساب المطابق لهاتف الطبيب.
  ///
  /// هذا للعرض فقط — القاعدة تفحص الجلسة الموقّعة مرة أخرى داخل
  /// `update_doctor_profile_self`، فلا يكفي تعديل الواجهة للكتابة.
  /// وصفوف الدليل المرجعية (`ref-…`) ليست في القاعدة فلا تُعدَّل.
  bool get _canEdit {
    if (d.id.startsWith('ref-')) return false;
    if (AuthService.instance.isAdmin) return true;
    final me = _last10(AuthService.instance.phone ?? '');
    final owner = _last10(d.phone);
    return me.length >= 7 && owner.length >= 7 && me == owner;
  }

  Future<String?> _saveSelfEdit(_EditValues v) async {
    try {
      final row = await SupabaseService.instance
          .rpcOne('update_doctor_profile_self', {
            'p_doctor_id': d.id,
            'p_bio': v.bio,
            'p_working_hours': v.hours,
            'p_notes': v.notes,
            'p_clinic_address': v.address,
            'p_image_path': v.imagePath ?? '',
          });
      if (row == null) return 'تعذّر الوصول إلى الخادم';
      if (row['ok'] == true) return null;
      switch ('${row['error'] ?? ''}') {
        case 'not_allowed':
          return 'هذا الحساب لا يملك صلاحية تعديل هذا الملف';
        case 'doctor_not_found':
          return 'هذا الملف غير موجود في القاعدة بعد';
        default:
          return 'تعذّر الحفظ — أعد المحاولة';
      }
    } on PostgrestFailure catch (e) {
      if (e.statusCode == 404) {
        return 'شغّل ملف tmp/doctors_self_edit.sql أولاً لتفعيل التعديل';
      }
      return 'تعذّر الحفظ: ${e.detail}';
    } catch (_) {
      return 'تعذّر الاتصال بالخادم';
    }
  }

  Future<void> _openEditor() async {
    final result = await showModalBottomSheet<_EditValues>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _EditSheet(doctor: d, onSave: _saveSelfEdit),
    );
    if (result == null || !mounted) return;
    setState(() {
      _doctor = _doctor.copyWith(
        bio: result.bio,
        workingHours: result.hours,
        notes: result.notes,
        clinicAddress: result.address,
        imagePath: result.imagePath ?? '',
      );
    });
    _toast('تم حفظ ملف الطبيب');
    // تحديث الذاكرة والقرص حتى تعرض البطاقات والبروفايل الجديد لاحقاً.
    unawaited(DoctorDirectoryService.instance.refreshNow());
  }

  void _toast(String msg, {bool ok = true}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
        ),
      );
  }

  String get _shareText {
    final lines = <String>[
      '${d.name} — ${d.specialtyLabel}',
      if (d.displayAddress.isNotEmpty) d.displayAddress,
      'عبر تطبيق اطباء ذي قار: https://saydaliti.netlify.app',
    ];
    return lines.join('\n');
  }

  Future<void> _share() async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    if (!mounted) return;
    _toast('تم نسخ رابط الملف — أرسله لمن تريد');
  }

  Future<void> _showQr() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(
          Icons.qr_code_2_rounded,
          color: AppColors.primary,
          size: 38,
        ),
        title: Text(
          'مشاركة الملف',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: Text(
          _shareText,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            fontSize: 12.5,
            height: 1.7,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إغلاق', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _shareText));
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _toast('تم نسخ رابط الملف');
            },
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(
              'نسخ الرابط',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _call() async {
    final phone = d.phone.trim();
    if (phone.isEmpty) {
      _toast('لا يوجد رقم اتصال لهذا الحساب', ok: false);
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone.replaceAll(' ', ''));
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _whatsapp() async {
    final phone = d.phone.trim();
    if (phone.isEmpty) {
      _toast('لا يوجد رقم واتساب لهذا الحساب', ok: false);
      return;
    }
    await ContactTools.whatsappCustomer(
      context,
      phone,
      message: 'السلام عليكم، أرغب بحجز موعد عند ${d.name}.',
    );
  }

  /// رابط تواصل حر (فيسبوك/إنستغرام/تيك توك/يوتيوب/تيليگرام/فايبر/واتساب/
  /// Google Play) — أيقونة الزر تتعرّف على المنصة من الرابط نفسه.
  Future<void> _openLink() async {
    final href = d.facebookHref;
    if (href.isEmpty) return;
    await launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
  }

  /// الضغط على الصورة يعرضها كاملة قابلة للتكبير — لصور الحزمة والسيرفر.
  void _openPhoto() {
    final asset = d.localAsset;
    final url = d.imageUrl;
    if (asset == null && url == null) return;
    ImageViewerScreen.open(context, url: url, asset: asset, title: d.name);
  }

  /// الحجز كما كان من الدليل: الزائر يمرّ ببوابة الدخول أولاً لأن
  /// تثبيت الحجز يحتاج جلسة.
  void _book() {
    void push() => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DoctorAppointmentScreen(
          prefillDoctorName: d.name,
          prefillSpecialty: d.specialty,
        ),
      ),
    );
    if (!AuthService.instance.isLoggedIn) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              LoginScreen(showBackButton: true, onLoginSuccess: push),
        ),
      );
      return;
    }
    push();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final isFav = stats?.isFavorite ?? false;
    final hasLink = d.facebookHref.isNotEmpty;
    final canEdit = _canEdit;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: true,
        title: const SizedBox.shrink(),
        actions: [
          IconButton(
            tooltip: 'مشاركة',
            onPressed: _showQr,
            icon: const Icon(Icons.qr_code_2_rounded, size: 22),
          ),
          IconButton(
            tooltip: 'نسخ الرابط',
            onPressed: _share,
            icon: const Icon(Icons.share_rounded, size: 21),
          ),
          IconButton(
            tooltip: isFav ? 'إزالة من المفضلة' : 'إضافة للمفضلة',
            onPressed: _favBusy ? null : _toggleFavorite,
            icon: Icon(
              isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 23,
              color: isFav ? AppColors.favorite : Colors.white,
            ),
          ),
          if (canEdit)
            IconButton(
              tooltip: 'تعديل ملف الطبيب',
              onPressed: _openEditor,
              icon: const Icon(Icons.edit_rounded, size: 21),
            ),
        ],
      ),
      body: AppRefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
          children: [
            _ProfileHead(doctor: d, onPhotoTap: _openPhoto),
            const SizedBox(height: 20),
            _StatsRow(
              visits: stats?.visits ?? 0,
              favorites: stats?.favorites ?? 0,
              isFavorite: isFav,
              onFavoriteTap: _favBusy ? null : _toggleFavorite,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(flex: 2, child: _CallButton(onTap: _call)),
                const SizedBox(width: 9),
                Expanded(flex: 2, child: _WhatsAppButton(onTap: _whatsapp)),
                const SizedBox(width: 9),
                Expanded(
                  child: hasLink
                      ? _LinkButton(href: d.facebookHref, onTap: _openLink)
                      : _BookingButton(onTap: _book),
                ),
              ],
            ),
            if (d.displayAddress.isNotEmpty) ...[
              const SizedBox(height: 16),
              _InfoCard(
                icon: Icons.location_on_rounded,
                title: 'عنوان العيادة',
                child: Column(
                  children: [
                    Text(
                      d.displayAddress,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        height: 1.6,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (d.bio.isNotEmpty) ...[
              const SizedBox(height: 12),
              _InfoCard(
                icon: Icons.person_outline_rounded,
                title: 'نبذة مهنية',
                child: _BodyText(d.bio),
              ),
            ],
            if (d.workingHours.isNotEmpty) ...[
              const SizedBox(height: 12),
              _InfoCard(
                icon: Icons.schedule_rounded,
                title: 'أوقات الدوام الرسمي',
                child: _BodyText(d.workingHours),
              ),
            ],
            if (d.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _InfoCard(
                icon: Icons.notes_rounded,
                title: 'الملاحظات',
                child: _BodyText(d.notes),
              ),
            ],
            if (hasLink) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _book,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.event_available_rounded, size: 20),
                label: Text(
                  'حجز موعد',
                  style: GoogleFonts.cairo(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// رأس البروفايل موسَّط بالكامل: الصورة في الوسط ثم الاسم واللقب والتخصص
/// والمنطقة — توسيط جميع كلام البروفايل كما طُلب.
class _ProfileHead extends StatelessWidget {
  const _ProfileHead({required this.doctor, this.onPhotoTap});

  final DoctorProfile doctor;
  final VoidCallback? onPhotoTap;

  /// الضغط على شارة التوثيق يوضّح معناها للزائر.
  void _showVerified(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        contentPadding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.info.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.verified_rounded,
                color: AppColors.info,
                size: 42,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'ملف شخصي تم التحقق منه',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 16.5,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '(موثوق)',
              style: GoogleFonts.cairo(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.info,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'هذا الحساب موثّق من إدارة التطبيق.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
                child: Text(
                  'حسناً',
                  style: GoogleFonts.cairo(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final area = doctor.area.isNotEmpty ? doctor.area : '';
    final cover = doctor.coverImageUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ★ غلاف احترافي (طلب 2026-11-20): ارتفاع ثابت 150 وزوايا 18،
        //   والصورة تُقصّ لتملأ الإطار كاملاً (لا فراغ ولا تمدّد)،
        //   ودائرة الصورة تتداخل مع أسفله. يعرضه الأدمن وحده.
        if (cover != null)
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: double.infinity,
                  height: 150,
                  child: AppImage(
                    cover,
                    fit: BoxFit.cover,
                    cacheWidth: 900,
                    errorBuilder: (_, _, _) =>
                        Container(color: AppColors.primaryLight),
                  ),
                ),
              ),
              Positioned(
                bottom: -48,
                child: _Avatar(doctor: doctor, onTap: onPhotoTap),
              ),
            ],
          )
        else
          _Avatar(doctor: doctor, onTap: onPhotoTap),
        SizedBox(height: cover != null ? 60 : 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                doctor.name,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  height: 1.35,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            if (doctor.verified) ...[
              const SizedBox(width: 5),
              _VerifiedBadge(onTap: () => _showVerified(context)),
            ],
          ],
        ),
        if (doctor.title.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            doctor.title,
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          doctor.specialtyLabel,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: AppColors.primary,
          ),
        ),
        if (area.isNotEmpty) ...[
          const SizedBox(height: 5),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                area,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryDark,
                ),
              ),
              const SizedBox(width: 3),
              const Icon(
                Icons.location_on_rounded,
                size: 15,
                color: AppColors.primaryDark,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// شارة التوثيق بجانب الاسم — قابلة للضغط وتشرح معناها.
class _VerifiedBadge extends StatelessWidget {
  const _VerifiedBadge({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'موثّق — ملف شخصي تم التحقق منه',
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.verified_rounded, size: 21, color: AppColors.info),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.doctor, this.onTap});

  final DoctorProfile doctor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final asset = doctor.localAsset;
    final url = doctor.imageUrl;
    final hasPhoto = asset != null || url != null;
    Widget fallback() => Container(
      color: AppColors.primaryLight,
      child: const Icon(
        Icons.person_rounded,
        color: AppColors.primary,
        size: 46,
      ),
    );
    final avatar = Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(2.5),
      child: ClipOval(
        child: asset != null
            ? Image.asset(
                asset,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback(),
              )
            : url != null
            ? AppImage(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback(),
              )
            : fallback(),
      ),
    );
    return GestureDetector(
      onTap: hasPhoto ? onTap : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          // شارة صغيرة تقول إن الصورة تُفتح مكبَّرة.
          if (hasPhoto)
            Positioned(
              left: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(
                  Icons.zoom_in_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.visits,
    required this.favorites,
    required this.isFavorite,
    this.onFavoriteTap,
  });

  final int visits;
  final int favorites;
  final bool isFavorite;
  final VoidCallback? onFavoriteTap;

  static String _fmt(int v) => v.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onFavoriteTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _StatCell(
                icon: isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                value: _fmt(favorites),
                label: 'في المفضلة',
                color: isFavorite ? AppColors.favorite : null,
              ),
            ),
          ),
        ),
        Container(width: 1, height: 38, color: AppColors.divider),
        Expanded(
          child: _StatCell(
            icon: Icons.visibility_rounded,
            value: _fmt(visits),
            label: 'زيارات الملف',
          ),
        ),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.icon,
    required this.value,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value,
              style: GoogleFonts.cairo(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                height: 1.1,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 5),
            Icon(icon, size: 17, color: color ?? AppColors.primary),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: GoogleFonts.cairo(
            fontSize: 11.5,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Material(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: const Center(
            child: Icon(Icons.call_rounded, color: Colors.white, size: 23),
          ),
        ),
      ),
    );
  }
}

/// زر واتساب: يفتح محادثة مباشرة مع رقم الطبيب ورسالة جاهزة.
class _WhatsAppButton extends StatelessWidget {
  const _WhatsAppButton({required this.onTap});

  final VoidCallback onTap;

  static const Color _brand = Color(0xFF25D366);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: _brand, width: 1.4),
            ),
            child: const Center(
              child: Icon(Icons.chat_rounded, color: _brand, size: 23),
            ),
          ),
        ),
      ),
    );
  }
}

/// زر الرابط الخارجي: يقود إلى صفحة الطبيب على أي منصة، والأيقونة
/// واللون يتبعان المنصة المكتشفة من الرابط (فيسبوك/إنستغرام/تيك توك/
/// يوتيوب/تيليگرام/فايبر/واتساب/Google Play) وإلا أيقونة رابط عامة.
class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.href, required this.onTap});

  final String href;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final platform = SocialLink.detect(href);
    return SizedBox(
      height: 50,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: const Color(0xFFE3E8EA), width: 1.2),
            ),
            child: Center(
              child: SocialLink.buildIcon(
                platform,
                size: 24,
                color: SocialLink.colorOf(platform),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BookingButton extends StatelessWidget {
  const _BookingButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: const Color(0xFFE3E8EA), width: 1.2),
            ),
            child: Center(
              child: Text(
                'حجز موعد',
                style: GoogleFonts.cairo(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// بطاقة معلومات موسَّطة العنوان والنص (نبذة/دوام/ملاحظات/عنوان).
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE9EEEA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 7),
              Icon(icon, size: 19, color: AppColors.primary),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _BodyText extends StatelessWidget {
  const _BodyText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: GoogleFonts.cairo(
        fontSize: 13,
        height: 1.85,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    );
  }
}

/// قيم نموذج تعديل الملف — يعيدها الورقة بعد نجاح القاعدة.
class _EditValues {
  const _EditValues({
    required this.bio,
    required this.hours,
    required this.notes,
    required this.address,
    required this.imagePath,
  });

  final String bio;
  final String hours;
  final String notes;
  final String address;
  final String? imagePath;
}

/// ورقة تعديل ملف الطبيب — تُعرض للأدمن أو لصاحب الحساب المطابق فقط.
///
/// الصورة تُرفع **قبل** الحفظ إلى السلة (تصميم رافع الصور عندنا)، فإن
/// أُلغي التعديل حُذف ما رُفع عبر [AdminUploads.discard] بلا ملفات يتيمة،
/// وإن نجح الحفظ أُبقيت الصورة الجديدة وحُذفت القديمة التي استُبدلت.
class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.doctor, required this.onSave});

  final DoctorProfile doctor;

  /// يعيد null عند النجاح أو رسالة الخطأ العربية.
  final Future<String?> Function(_EditValues values) onSave;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _bioCtrl = TextEditingController(
    text: widget.doctor.bio,
  );
  late final TextEditingController _hoursCtrl = TextEditingController(
    text: widget.doctor.workingHours,
  );
  late final TextEditingController _notesCtrl = TextEditingController(
    text: widget.doctor.notes,
  );
  late final TextEditingController _addressCtrl = TextEditingController(
    text: widget.doctor.clinicAddress,
  );

  late String? _imagePath = widget.doctor.imagePath.trim().isEmpty
      ? null
      : widget.doctor.imagePath;

  final AdminUploads _uploads = AdminUploads();

  /// ملفات قديمة (من خارج هذا النموذج) انتظر قرار الحفظ قبل حذفها.
  final List<String> _removed = [];

  bool _saving = false;
  bool _kept = false;
  String _error = '';

  @override
  void dispose() {
    _bioCtrl.dispose();
    _hoursCtrl.dispose();
    _notesCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    final values = _EditValues(
      bio: _bioCtrl.text.trim(),
      hours: _hoursCtrl.text.trim(),
      notes: _notesCtrl.text.trim(),
      address: _addressCtrl.text.trim(),
      imagePath: _imagePath,
    );
    final err = await widget.onSave(values);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _saving = false;
        _error = err;
      });
      return;
    }
    _kept = true;
    _uploads.keep();
    for (final url in _removed) {
      unawaited(SupabaseService.instance.deleteImage(url));
    }
    Navigator.pop(context, values);
  }

  void _cancel() {
    _uploads.discard();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) => InputDecoration(
      labelText: label,
      counterText: '',
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    );

    return PopScope(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        // إغلاق بالسحب/الرجوع بلا حفظ: لا نُبقي صورة يتيمة في السلة.
        if (didPop && !_kept) _uploads.discard();
      },
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'تعديل ملف الطبيب',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'الصورة والنبذة والدوام والملاحظات والموقع',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              AdminImageUploader(
                folder: 'doctors',
                height: 130,
                uploads: _uploads,
                initialUrl: _imagePath,
                icon: Icons.person_rounded,
                placeholder: 'اختار صورة الطبيب من المعرض (تُرفع للسيرفر)',
                handleRemovalExternally: true,
                onChanged: (url) => _imagePath = url,
                onRemovedExisting: (url) => _removed.add(url),
                onFailed: (msg) => setState(() => _error = msg),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _addressCtrl,
                textAlign: TextAlign.right,
                maxLength: 120,
                decoration: deco('عنوان العيادة (الموقع)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _bioCtrl,
                textAlign: TextAlign.right,
                maxLength: 800,
                minLines: 3,
                maxLines: 5,
                decoration: deco('نبذة مهنية'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _hoursCtrl,
                textAlign: TextAlign.right,
                maxLength: 200,
                minLines: 2,
                maxLines: 4,
                decoration: deco('أوقات الدوام الرسمي (أيام/ساعات)'),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () async {
                    final picked = await showWorkingHoursPicker(
                      context,
                      initialText: _hoursCtrl.text,
                      title: 'أيام وساعات دوام الطبيب',
                    );
                    if (picked == null || !mounted) return;
                    setState(() => _hoursCtrl.text = picked.text);
                  },
                  icon: const Icon(Icons.calendar_month_rounded, size: 18),
                  label: Text(
                    'تحديد الأيام والساعة',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesCtrl,
                textAlign: TextAlign.right,
                maxLength: 300,
                minLines: 2,
                maxLines: 4,
                decoration: deco('ملاحظات (أجهزة متوفرة، تعليمات...)'),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _error,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.danger,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : _cancel,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        'إلغاء',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _saving ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              'حفظ التعديل',
                              style: GoogleFonts.cairo(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
