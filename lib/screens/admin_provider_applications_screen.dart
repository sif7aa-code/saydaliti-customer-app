import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/city_store.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ طلبات الانضمام (طبيب/ممرض/صيدلاني) — SQL_PROVIDER_APPLICATIONS.sql.
///   الأدمن يعتمد فيُنشئ الخادم الملف الرسمي ويضبط الاستقطاع بمعاملة واحدة،
///   أو يرفض مع سبب يظهر لصاحب الطلب.
class AdminProviderApplicationsScreen extends StatefulWidget {
  const AdminProviderApplicationsScreen({super.key});

  @override
  State<AdminProviderApplicationsScreen> createState() =>
      _AdminProviderApplicationsScreenState();
}

class _AdminProviderApplicationsScreenState
    extends State<AdminProviderApplicationsScreen> {
  bool _loading = true;
  String? _error;
  int _tab = 0;
  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _clinics = const [];

  static const _statuses = ['pending', 'approved', 'rejected'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final rows =
        await SupabaseService.instance.adminProviderApplications(
      status: _statuses[_tab],
    );
    if (_tab == 0 && _clinics.isEmpty) {
      _clinics = await SupabaseService.instance.fetchDoctors();
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = rows;
      if (rows.isEmpty && SupabaseService.instance.lastAdminError.isNotEmpty) {
        _error = SupabaseService.instance.lastAdminError;
      }
    });
  }

  Future<void> _switchTab(int tab) async {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _rows = const [];
    });
    await _load();
  }

  static String _text(Object? v) => '${v ?? ''}'.trim();

  static String _categoryLabel(String c) => switch (c) {
        'doctor' => 'طبيب',
        'nurse' => 'ممرض',
        'pharmacist' => 'صيدلاني',
        _ => c,
      };

  static IconData _categoryIcon(String c) => switch (c) {
        'doctor' => Icons.medical_services_rounded,
        'nurse' => Icons.health_and_safety_rounded,
        'pharmacist' => Icons.medication_rounded,
        _ => Icons.person_rounded,
      };

  static String _date(Object? v) {
    final s = _text(v);
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  void _toast(String msg, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.primary : AppColors.danger,
        ),
      );
  }

  Future<void> _preview(String url, String title) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.background,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                maxScale: 5,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'تعذّر تحميل الصورة',
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _reject(Map<String, dynamic> app) async {
    final id = _text(app['id']);
    if (id.isEmpty) return;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.background,
        title: Text(
          'رفض الطلب',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'السبب يظهر لصاحب الطلب في التطبيق.',
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: reason,
              maxLines: 3,
              maxLength: 300,
              decoration: InputDecoration(
                hintText: 'مثال: صورة الإثبات غير واضحة',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'إلغاء',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'رفض',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (ok != true) {
      reason.dispose();
      return;
    }
    final res = await SupabaseService.instance.adminReviewProvider(
      id: id,
      approve: false,
      reason: reason.text,
    );
    reason.dispose();
    if (!mounted) return;
    if (res['ok'] == true) {
      _toast('تم رفض الطلب');
      await _load();
    } else {
      _toast('${res['error'] ?? 'تعذّر الرفض'}', ok: false);
    }
  }

  Future<void> _approve(Map<String, dynamic> app) async {
    final id = _text(app['id']);
    if (id.isEmpty) return;
    final category = _text(app['category']);
    final name = _text(app['full_name']);
    final phone = _text(app['phone']);

    String city = _text(app['city']);
    if (city.isEmpty) city = CityStore.instance.chosen ?? CityStore.cities.first;
    String clinicId = '';
    var method = '';
    final valueCtrl = TextEditingController();
    var saving = false;
    String? inlineError;

    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> save() async {
            if (category == 'nurse' && clinicId.isEmpty) {
              setSheet(() => inlineError = 'اختر العيادة التي ينضم إليها الممرض');
              return;
            }
            double? value;
            if (method.isNotEmpty) {
              value = double.tryParse(valueCtrl.text.trim());
              if (value == null || value <= 0) {
                setSheet(() => inlineError = 'اكتب قيمة الاستقطاع');
                return;
              }
              if (method == 'percent' && value > 100) {
                setSheet(() => inlineError = 'النسبة بين 0 و100');
                return;
              }
            }
            setSheet(() {
              saving = true;
              inlineError = null;
            });
            final res = await SupabaseService.instance.adminReviewProvider(
              id: id,
              approve: true,
              city: category == 'doctor' ? city : '',
              clinicId: category == 'nurse' ? clinicId : '',
              deductionMethod: method,
              deductionValue: value,
            );
            if (!ctx.mounted) return;
            if (res['ok'] != true) {
              setSheet(() {
                saving = false;
                inlineError = '${res['error'] ?? 'تعذّر الاعتماد'}';
              });
              return;
            }
            Navigator.of(ctx).pop(true);
          }

          final isDoctor = category == 'doctor';
          final isPharmacist = category == 'pharmacist';
          return Padding(
            padding: EdgeInsets.only(
              left: 18,
              right: 18,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'اعتماد ${_categoryLabel(category)}',
                          style: GoogleFonts.cairo(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed:
                            saving ? null : () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  Text(
                    name,
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (phone.isNotEmpty) _phoneLine(phone),
                  const SizedBox(height: 12),
                  if (isDoctor) ...[
                    Text(
                      'مدينة العيادة (تحدد ظهورها في دليل المدينة)',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: CityStore.cities.contains(city)
                          ? city
                          : CityStore.cities.first,
                      items: [
                        for (final c in CityStore.cities)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: saving
                          ? null
                          : (v) => setSheet(() => city = v ?? city),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (category == 'nurse') ...[
                    Text(
                      'العيادة التي ينضم إليها كسكرتير',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: clinicId.isEmpty ? null : clinicId,
                      isExpanded: true,
                      hint: Text(
                        'اختر العيادة',
                        style: GoogleFonts.cairo(fontSize: 12.5),
                      ),
                      items: [
                        for (final d in _clinics)
                          DropdownMenuItem(
                            value: _text(d['id']),
                            child: Text(
                              _text(d['name']).isEmpty
                                  ? 'بلا اسم'
                                  : _text(d['name']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.cairo(fontSize: 12.5),
                            ),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (v) => setSheet(() => clinicId = v ?? ''),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (isDoctor || isPharmacist) ...[
                    Text(
                      'الاستقطاع (${isDoctor ? 'لكل كشفية' : 'لكل طلب مسلَّم'})',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        _MethodChip(
                          label: 'الافتراضي',
                          selected: method.isEmpty,
                          onTap: () => setSheet(() => method = ''),
                        ),
                        _MethodChip(
                          label: 'مبلغ ثابت',
                          selected: method == 'fixed',
                          onTap: () => setSheet(() => method = 'fixed'),
                        ),
                        _MethodChip(
                          label: 'نسبة %',
                          selected: method == 'percent',
                          onTap: () => setSheet(() => method = 'percent'),
                        ),
                      ],
                    ),
                    if (method.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: valueCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          labelText: method == 'fixed'
                              ? 'المبلغ (د.ع)'
                              : 'النسبة (%)',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      '«الافتراضي» يعني استقطاع الاستقطاعات المعتمد لذلك النوع.',
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                  if (inlineError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      inlineError!,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: saving ? null : save,
                      icon: saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.verified_rounded, size: 18),
                      label: Text(
                        'اعتماد ونشر في التطبيق',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    valueCtrl.dispose();
    if (done == true) {
      await _load();
      _toast(category == 'nurse'
          ? 'تم اعتماد الممرض وربطه بالعيادة'
          : 'تم الاعتماد — ظهر الحساب في التطبيق رسمياً');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'طلبات الانضمام',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: Column(
          children: [
            _header(),
            _tabs(),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _errorView()
                      : _rows.isEmpty
                          ? _empty()
                          : ListView.separated(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              itemCount: _rows.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, i) => _card(_rows[i]),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          'طلبات الطبيب والممرض والصيدلاني من شاشة التسجيل. '
          'بالاعتماد يُنشأ الحساب الرسمي ويظهر في التطبيق فوراً، '
          'وتُضبط الكشفية أو النسبة من هنا.',
          style: GoogleFonts.cairo(
            fontSize: 12,
            height: 1.7,
            fontWeight: FontWeight.w700,
            color: AppColors.primaryDark,
          ),
        ),
      );

  Widget _tabs() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: _TabButton(
                  label: const ['بالانتظار', 'معتمدة', 'مرفوضة'][i],
                  selected: _tab == i,
                  onTap: () => _switchTab(i),
                ),
              ),
            ],
          ],
        ),
      );

  Widget _card(Map<String, dynamic> app) {
    final category = _text(app['category']);
    final name = _text(app['full_name']);
    final phone = _text(app['phone']);
    final specialty = _text(app['specialty']);
    final bio = _text(app['bio']);
    final hours = _text(app['working_hours']);
    final city = _text(app['city']);
    final shopName = _text(app['shop_name']);
    final photo = _text(app['photo_url']);
    final proof = _text(app['proof_url']);
    final note = _text(app['admin_note']);
    final status = _text(app['status']);
    final pending = status == 'pending';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                backgroundImage: photo.isEmpty ? null : NetworkImage(photo),
                child: photo.isEmpty
                    ? Icon(_categoryIcon(category), color: AppColors.primary)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'بلا اسم' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _categoryLabel(category),
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (specialty.isNotEmpty)
                      Text(
                        specialty,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textHint,
                        ),
                      ),
                  ],
                ),
              ),
              _StatusPill(status: status),
            ],
          ),
          const SizedBox(height: 10),
          if (phone.isNotEmpty) _phoneLine(phone),
          if (shopName.isNotEmpty)
            _line(Icons.storefront_rounded, 'اسم الصيدلية: $shopName'),
          if (city.isNotEmpty) _line(Icons.place_rounded, 'المدينة: $city'),
          if (hours.isNotEmpty)
            _line(Icons.schedule_rounded, 'أوقات العمل: $hours'),
          if (bio.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              bio,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                height: 1.6,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          if (note.isNotEmpty && status == 'rejected') ...[
            const SizedBox(height: 6),
            Text(
              'سبب الرفض: $note',
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.danger,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (proof.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _preview(proof, 'إثبات المهنة'),
                  icon: const Icon(Icons.badge_outlined, size: 16),
                  label: Text(
                    'الإثبات',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              if (photo.isNotEmpty) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _preview(photo, 'الصورة الشخصية'),
                  icon: const Icon(Icons.person_outline_rounded, size: 16),
                  label: Text(
                    'الصورة',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (pending) ...[
                TextButton(
                  onPressed: () => _reject(app),
                  child: Text(
                    'رفض',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.danger,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => _approve(app),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  child: Text(
                    'اعتماد',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (status != 'pending')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${status == 'approved' ? 'اعتُمد في' : 'رُفض في'} '
                '${_date(app['reviewed_at'])}',
                style: GoogleFonts.cairo(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textHint,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// رقم مقدم الطلب ظاهراً بخط واضح مع زر نسخ — يحتاجه الأدمن للتواصل
  /// قبل الاعتماد أو بعد الرفض.
  Widget _phoneLine(String phone) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            const Icon(Icons.phone_rounded, size: 15, color: AppColors.primary),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                'هاتف مقدم الطلب: $phone',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.cairo(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: phone));
                _toast('تم نسخ رقم المقدم');
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  'نسخ',
                  style: GoogleFonts.cairo(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _line(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Icon(icon, size: 14, color: AppColors.textHint),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.cairo(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _empty() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
        children: [
          const Icon(
            Icons.inbox_rounded,
            size: 48,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 10),
          Text(
            const ['لا طلبات بالانتظار', 'لا طلبات معتمدة', 'لا طلبات مرفوضة'][_tab],
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );

  Widget _errorView() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: AppColors.danger,
          ),
          const SizedBox(height: 10),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: FilledButton(
              onPressed: _load,
              child: Text(
                'إعادة المحاولة',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'approved' => ('معتمد', AppColors.primary),
      'rejected' => ('مرفوض', AppColors.danger),
      _ => ('بالانتظار', AppColors.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.cairo(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.cairo(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
