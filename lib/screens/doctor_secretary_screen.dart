import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';

/// ★ «سكرتير العيادة» — إدارة الطبيب لسكرتيره من حسابه.
///
///   الطلب (11-25): الطبيب يضيف/يغيّر سكرتيراً يقبل حجوزات عيادته
///   ويرفضها، وإذا بطل السكرتير يحذفه — والطبيب والأدمن فقط من يملك
///   ذلك. القاعدة تحرس هذا في `doctor_secretary_set`: رقم الجلسة يجب أن
///   يكون رقم الطبيب المسؤول عن العيادة أو أدمن.
///
///   لا إنشاء حساب هنا: السكرتير يثبّت التطبيق ويسجّل الدخول بكود
///   واتساب على الرقم المضبوط، فيفتح له دور السكرتير تلقائياً. والحذف
///   يصفّر الرقم في القاعدة فيفقد الوصول فوراً (ويسقط دوره في التطبيق
///   خلال دورة الفحص، دقيقة على الأكثر).
class DoctorSecretaryScreen extends StatefulWidget {
  const DoctorSecretaryScreen({super.key});

  @override
  State<DoctorSecretaryScreen> createState() => _DoctorSecretaryScreenState();
}

class _DoctorSecretaryScreenState extends State<DoctorSecretaryScreen> {
  List<DoctorRoleEntry> _clinics = const <DoctorRoleEntry>[];
  final Map<String, DoctorSecretaryInfo> _info =
      <String, DoctorSecretaryInfo>{};
  final Map<String, TextEditingController> _editors =
      <String, TextEditingController>{};
  bool _loading = true;
  String _failure = '';
  String? _editingId;
  String? _busyId;

  /// ★ فحص التسجيل أثناء الكتابة (2026-11-25): الرقم غير المسجّل لا يُحفظ،
  ///   والمسجّل يُظهر اسم صاحبه فوراً.
  final Map<String, DoctorSecretaryCheck?> _check =
      <String, DoctorSecretaryCheck?>{};
  final Map<String, String> _checkedPhone = <String, String>{};
  final Set<String> _checking = <String>{};
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    for (final c in _editors.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = '';
      });
    }
    final ctx = await DoctorService.instance.myRoles();
    final clinics = (ctx?.doctors ?? const <DoctorRoleEntry>[])
        .where((d) => d.isDoctor)
        .toList(growable: false);
    final info = <String, DoctorSecretaryInfo>{};
    for (final c in clinics) {
      final i = await DoctorService.instance.secretaryInfo(c.id);
      if (i != null) info[c.id] = i;
    }
    final why = (SupabaseService.instance.lastRpcError ?? '').trim();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _clinics = clinics;
      _info
        ..clear()
        ..addAll(info);
      _failure = clinics.isNotEmpty && info.length < clinics.length
          ? (why.isEmpty
                ? 'تعذّرت قراءة بيانات السكرتير — تحقّق من الاتصال'
                : why)
          : '';
    });
  }

  /// تطبيع مطابق للقاعدة: أرقام فقط، و9647xxxxxxxx أو 7xxxxxxxxx
  /// تصيران 07xxxxxxxx.
  String _normalise(String v) {
    var d = v.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 13 && d.startsWith('964')) d = d.substring(3);
    if (d.length == 10 && d.startsWith('7')) d = '0$d';
    return d;
  }

  TextEditingController _editorFor(String doctorId, String current) {
    return _editors.putIfAbsent(
      doctorId,
      () => TextEditingController(text: current),
    );
  }

  /// فحص الرقم في القاعدة (مؤجّل ٤٥٠ مللي أثناء الكتابة، وفوري عند
  /// فتح المحرّر). يمسح نتيجة الرقم السابق فوراً حتى لا يحجب الحفظ.
  void _scheduleCheck(String clinicId, String raw, {bool immediate = false}) {
    _checkTimer?.cancel();
    final phone = _normalise(raw);
    final valid = RegExp(r'^07\d{9}$').hasMatch(phone);
    setState(() {
      _check.remove(clinicId);
      _checkedPhone.remove(clinicId);
      if (!valid) _checking.remove(clinicId);
    });
    if (!valid) return;
    _checkTimer = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 450),
      () => _runCheck(clinicId, phone),
    );
  }

  Future<void> _runCheck(String clinicId, String phone) async {
    if (!mounted) return;
    setState(() => _checking.add(clinicId));
    final res = await DoctorService.instance.secretaryCheck(clinicId, phone);
    if (!mounted) return;
    // نتيجة رقم قديم طارئة؟ نرميها ولا نعيدها.
    final now = _normalise(_editors[clinicId]?.text ?? '');
    if (now != phone) return;
    setState(() {
      _checking.remove(clinicId);
      if (res != null) {
        _check[clinicId] = res;
        _checkedPhone[clinicId] = phone;
      }
    });
  }

  bool _blocked(DoctorRoleEntry clinic) {
    final c = _check[clinic.id];
    return c != null &&
        !c.registered &&
        _checkedPhone[clinic.id] == _normalise(_editors[clinic.id]?.text ?? '');
  }

  void _toast(String msg, bool ok) {
    if (!mounted) return;
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  Future<void> _save(DoctorRoleEntry clinic) async {
    if (_busyId != null) return;
    final phone = _normalise(_editors[clinic.id]?.text ?? '');
    if (!RegExp(r'^07\d{9}$').hasMatch(phone)) {
      _toast('اكتب رقماً عراقياً صحيحاً من 11 رقماً يبدأ 07', false);
      return;
    }
    if (_blocked(clinic)) {
      _toast(
        'هذا الرقم غير مسجل في التطبيق — يثبّت التطبيق ويسجّل الدخول أولاً',
        false,
      );
      return;
    }
    setState(() => _busyId = clinic.id);
    final res = await DoctorService.instance.setSecretary(clinic.id, phone);
    if (!mounted) return;
    setState(() => _busyId = null);
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    _toast(res.message, true);
    setState(() => _editingId = null);
    await _load();
  }

  Future<void> _remove(DoctorRoleEntry clinic) async {
    if (_busyId != null) return;
    final info = _info[clinic.id];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف السكرتير',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        content: Text(
          info != null && info.name.isNotEmpty
              ? 'سيُلغى وصول «${info.name}» إلى حجوزات العيادة فوراً. '
                    'لن تُحذف أي حجوزات أو بيانات، ويمكنك إضافة رقمه أو '
                    'رقم غيره في أي وقت. هل تحذف السكرتير؟'
              : 'سيُلغى وصول هذا الرقم إلى حجوزات العيادة فوراً. لن تُحذف '
                    'أي حجوزات أو بيانات. هل تحذف السكرتير؟',
          style: GoogleFonts.cairo(
            fontSize: 13,
            height: 1.6,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'إلغاء',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'حذف السكرتير',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyId = clinic.id);
    final res = await DoctorService.instance.setSecretary(clinic.id, '');
    if (!mounted) return;
    setState(() {
      _busyId = null;
      _editingId = null;
    });
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    _toast(res.message, true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('سكرتير العيادة'),
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
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  if (_clinics.isEmpty) _empty(),
                  for (final c in _clinics) _clinicCard(c),
                  if (_clinics.isNotEmpty) _howItWorks(),
                  const SizedBox(height: 20),
                ],
              ),
      ),
    );
  }

  /// سطر تحت حقل الرقم: يتحقق / غير مسجل / مسجل باسمه.
  Widget _checkStatus(String clinicId) {
    if (_checking.contains(clinicId)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 7),
            Text(
              'نتحقق من الحساب...',
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }
    final c = _check[clinicId];
    if (c == null) return const SizedBox.shrink();
    final ok = c.registered;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            ok ? Icons.verified_user_outlined : Icons.person_off_outlined,
            size: 17,
            color: ok ? AppColors.success : AppColors.danger,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              ok
                  ? (c.name.isEmpty
                        ? 'الرقم مسجل في التطبيق'
                        : 'مسجل: ${c.name}')
                  : 'هذا الرقم غير مسجل في التطبيق — يثبّت التطبيق '
                        'ويسجّل الدخول أولاً',
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: ok ? AppColors.success : AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {    return Padding(
      padding: const EdgeInsets.only(top: 90, left: 12, right: 12),
      child: Column(
        children: [
          const Icon(
            Icons.support_agent_rounded,
            size: 60,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 14),
          Text(
            _failure.isNotEmpty
                ? _failure
                : 'هذه الشاشة لطبيب العيادة — الحساب الحالي ليس طبيباً',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _clinicCard(DoctorRoleEntry clinic) {
    final info = _info[clinic.id];
    final editing = _editingId == clinic.id;
    final busy = _busyId == clinic.id;
    final has = info?.hasSecretary == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_hospital_outlined,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  clinic.name.isEmpty ? 'عيادة' : clinic.name,
                  style: GoogleFonts.cairo(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: has ? AppColors.primaryLight : AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: info == null
                ? Text(
                    'تعذّرت قراءة السكرتير — تحقّق من الاتصال',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  )
                : has
                ? Row(
                    children: [
                      const Icon(
                        Icons.person_outline_rounded,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          info.name.isEmpty
                              ? 'سكرتير العيادة: ${info.phone}'
                              : 'السكرتير: ${info.name} — ${info.phone}',
                          style: GoogleFonts.cairo(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primaryDark,
                          ),
                        ),
                      ),
                      if (info.name.isEmpty)
                        Text(
                          'غير مسجل',
                          style: GoogleFonts.cairo(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.danger,
                          ),
                        ),
                    ],
                  )
                : Text(
                    'لا يوجد سكرتير لهذه العيادة — أضف رقمه ليستقبل '
                    'الحجوزات للموافقة أو الرفض',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
          ),
          if (editing) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _editorFor(clinic.id, info?.phone ?? ''),
              autofocus: true,
              keyboardType: TextInputType.phone,
              onChanged: (v) => _scheduleCheck(clinic.id, v),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 +]')),
                LengthLimitingTextInputFormatter(15),
              ],
              style: GoogleFonts.cairo(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: 'رقم هاتف السكرتير',
                hintText: '07XXXXXXXXX',
                hintStyle: GoogleFonts.cairo(
                  fontSize: 13,
                  color: AppColors.textHint,
                ),
                prefixIcon: const Icon(
                  Icons.phone_android_rounded,
                  color: AppColors.primary,
                ),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _checkStatus(clinic.id),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => setState(() => _editingId = null),
                    child: Text(
                      'إلغاء',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: busy || _blocked(clinic)
                        ? null
                        : () => _save(clinic),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                    ),
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded, size: 19),
                    label: Text(
                      has ? 'حفظ التغيير' : 'حفظ السكرتير',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      final current = info?.phone ?? '';
                      _editorFor(clinic.id, current).text = current;
                      setState(() => _editingId = clinic.id);
                      if (current.isNotEmpty) {
                        _scheduleCheck(clinic.id, current, immediate: true);
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                    ),
                    icon: Icon(
                      has
                          ? Icons.edit_outlined
                          : Icons.person_add_alt_1_rounded,
                      size: 18,
                    ),
                    label: Text(
                      has ? 'تغيير السكرتير' : 'إضافة سكرتير',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                if (has) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : () => _remove(clinic),
                      icon: const Icon(Icons.person_remove_outlined, size: 18),
                      label: Text(
                        'حذف',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: BorderSide(
                          color: AppColors.danger.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _howItWorks() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 19,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'كيف يفعّل السكرتير حسابه؟',
                style: GoogleFonts.cairo(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '1) يثبّت السكرتير تطبيق «اطباء ذي قار» ويسجّل الدخول برقمه '
            'أولاً — الأرقام غير المسجلة تُرفض ولا تُحفظ.\n'
            '2) اكتب رقمه هنا واحفظه؛ يظهر لك أثناء الكتابة «غير مسجل» أو '
            'اسم صاحب الحساب.\n'
            '3) يتحول تطبيق السكرتير لواجهة العيادة فوراً: الحجوزات '
            'للموافقة أو الرفض، والمحفظة، والدردشة.\n'
            '4) عند تغيير الرقم يفقد القديم الوصول فوراً، وعند الحذف يُلغى '
            'الوصول فوراً. لا تُحذف أي حجوزات أو بيانات.',
            style: GoogleFonts.cairo(
              fontSize: 12.5,
              height: 1.7,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
