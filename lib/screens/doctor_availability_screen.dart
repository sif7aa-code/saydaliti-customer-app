import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ «حجز الزبائن» — زر تشغيل/إطفاء واحد للعيادة (طلب الأدمن 2026-11-24):
///
///   مفتوح ⇒ الحجز متاح كل أيام الأسبوع، والساعة نفسها لا تُحجز مرتين.
///   مغلق  ⇒ لا يستطيع أي زبون حجز موعد مهما كان السبب — والقاعدة نفسها
///            ترفض الحجز، فحتى نسخ التطبيق القديمة لا تتجاوز الإطفاء.
class DoctorAvailabilityScreen extends StatefulWidget {
  const DoctorAvailabilityScreen({super.key});

  @override
  State<DoctorAvailabilityScreen> createState() =>
      _DoctorAvailabilityScreenState();
}

class _DoctorAvailabilityScreenState extends State<DoctorAvailabilityScreen>
    with TabRefreshTarget<DoctorAvailabilityScreen> {
  /// تبويب واجهة الطبيب: النقرة تعيد الجلب.
  @override
  String get tabId => 'clinic_hours';

  @override
  Future<void> Function() onTabRefresh() => _load;

  List<DoctorAvailabilityEntry> _entries = const [];
  String? _selectedId;
  bool _loading = true;
  bool _saving = false;
  bool _readFailed = false;
  String _failure = '';

  DoctorAvailabilityEntry? get _current {
    for (final e in _entries) {
      if (e.id == _selectedId) return e;
    }
    return _entries.isEmpty ? null : _entries.first;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await DoctorService.instance.myAvailability();
    if (!mounted) return;
    final why = (SupabaseService.instance.lastRpcError ?? '').trim();
    setState(() {
      _loading = false;
      _entries = list;
      _readFailed = list.isEmpty && why.isNotEmpty;
      _failure = _readFailed ? why : '';
      if (list.isNotEmpty) {
        final keep = _selectedId;
        _selectedId = (keep != null && list.any((e) => e.id == keep))
            ? keep
            : list.first.id;
      }
    });
  }

  void _pickDoctor(String id) {
    if (id == _selectedId) return;
    setState(() => _selectedId = id);
  }

  Future<void> _toggle(bool open) async {
    final entry = _current;
    if (_saving || entry == null) return;
    setState(() => _saving = true);
    final res = await DoctorService.instance.setBookingOpen(entry.id, open);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (res.ok) {
        _entries = [
          for (final e in _entries)
            if (e.id == entry.id)
              DoctorAvailabilityEntry(
                id: e.id,
                name: e.name,
                isDoctor: e.isDoctor,
                isSecretary: e.isSecretary,
                bookingOpen: res.open,
              )
            else
              e,
        ];
      }
    });
    if (!res.ok) {
      _toast(res.error, false);
      return;
    }
    // الحالة النهائية من الخادم نفسه لا من الزر — تُقال في التأكيد.
    _toast(
      res.open
          ? 'تم تشغيل الحجز — كل أيام الأسبوع متاحة للزبائن'
          : 'تم إطفاء الحجز — لن يستطيع أي زبون حجز موعد',
      true,
    );
  }

  void _toast(String msg, bool ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, textAlign: TextAlign.center),
          backgroundColor: ok ? AppColors.success : AppColors.danger,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('حجز الزبائن'),
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
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _body(),
            ),
    );
  }

  Widget _body() {
    if (_entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _NoticeCard(
            icon: _readFailed
                ? Icons.error_outline_rounded
                : Icons.link_off_rounded,
            color: _readFailed ? AppColors.danger : AppColors.textSecondary,
            title: _readFailed
                ? 'تعذّرت قراءة حالة العيادة'
                : 'لا عيادة مرتبطة بهذا الحساب',
            body: _readFailed
                ? _failure
                : 'حالة الحجز تُضبط لعيادة مرتبطة برقم هذا الحساب. '
                    'إن كان رقمك هو رقم العيادة أو سكرتيرها فحدّث الصفحة، '
                    'وإلا يربطه الأدمن من لوحة التحكم.',
          ),
        ],
      );
    }

    final entry = _current!;
    final open = entry.bookingOpen;
    final multi = _entries.length > 1;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _NoticeCard(
          icon: Icons.health_and_safety_outlined,
          color: AppColors.primary,
          title: entry.name.isEmpty ? 'عيادة الطبيب' : entry.name,
          body: 'زر واحد يحكم حجز الزبائن عند العيادة: '
              'مفتوح فيستطيعون الحجز في كل أيام الأسبوع — '
              'ولن يُحجز الوقت نفسه مرتين — ومغلق فلا يصل أي حجز '
              'مهما كان السبب.',
        ),
        if (multi) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedId,
                isExpanded: true,
                borderRadius: BorderRadius.circular(14),
                items: [
                  for (final e in _entries)
                    DropdownMenuItem<String>(
                      value: e.id,
                      child: Text(
                        e.name.isEmpty ? 'عيادة' : e.name,
                        style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) _pickDoctor(v);
                },
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _SwitchCard(
          open: open,
          busy: _saving,
          onChanged: _toggle,
        ),
        const SizedBox(height: 16),
        _NoteLine(
          icon: Icons.calendar_month_rounded,
          color: open ? AppColors.primary : AppColors.danger,
          text: open
              ? 'الحجز متاح كل أيام الأسبوع. الساعة التي فيها حجز قائم '
                  'تبقى حمراء حتى يُلغى الحجز.'
              : 'الحجز مغلق الآن: لا يستطيع أي زبون تثبيت موعد. '
                  'المشغّل في القاعدة يرفض الحجوزات حتى من النسخ القديمة.',
        ),
        const SizedBox(height: 10),
        _NoteLine(
          icon: Icons.bolt_rounded,
          color: AppColors.textSecondary,
          text: 'التغيير يسري فوراً على كل الزبائن بلا حفظ إضافي.',
        ),
      ],
    );
  }
}

/// بطاقة الزر: كل البطاقة قابلة للنقر، والمفتاح يعكس الحالة من الخادم.
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.open,
    required this.busy,
    required this.onChanged,
  });

  final bool open;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final color = open ? AppColors.primary : AppColors.danger;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: busy ? null : () => onChanged(!open),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color, width: 1.4),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      open
                          ? Icons.event_available_rounded
                          : Icons.event_busy_rounded,
                      color: color,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          open ? 'الحجز مفتوح' : 'الحجز مغلق',
                          style: GoogleFonts.cairo(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            color: color,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          open
                              ? 'كل أيام الأسبوع — للزبائن'
                              : 'لا حجز من أي زبون',
                          style: GoogleFonts.cairo(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  busy
                      ? const SizedBox(
                          width: 42,
                          height: 26,
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        )
                      : Switch(
                          value: open,
                          onChanged: onChanged,
                          activeThumbColor: Colors.white,
                          activeTrackColor: AppColors.primary,
                          inactiveThumbColor: Colors.white,
                          inactiveTrackColor:
                              AppColors.danger.withValues(alpha: 0.55),
                          trackOutlineColor:
                              WidgetStateProperty.all(Colors.transparent),
                        ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      open ? 'إطفاء' : 'تشغيل',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: open ? AppColors.danger : AppColors.primary,
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 18,
                    color: AppColors.divider,
                  ),
                  Expanded(
                    child: Text(
                      open ? 'اضغط البطاقة للإطفاء' : 'اضغط البطاقة للتشغيل',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textHint,
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

class _NoteLine extends StatelessWidget {
  const _NoteLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.cairo(
                fontSize: 12,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
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
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
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
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: GoogleFonts.cairo(
              fontSize: 12,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
