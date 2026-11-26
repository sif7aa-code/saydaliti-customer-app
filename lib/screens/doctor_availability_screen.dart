import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ «حجز الزبائن» — تحكّم مزدوج اختاره الأدمن (2026-11-24):
///
///   1) زر تشغيل/إطفاء عام: مغلق ⇒ لا حجز لأي زبون مهما كان السبب،
///      والمشغّل في القاعدة يرفض حتى نسخ التطبيق القديمة.
///   2) ساعات أسبوعية يختارها الطبيب أو سكرتير العيادة (يوم × ساعة):
///      عند فتح الزر لا يُحجز إلا في الساعة المختارة وغير المحجوزة.
///
///   ★ لا نطفئ ساعة من أنفسنا: ما يختاره هو يُحفظ كما هو، وتشغيل
///     الزر أو إطفاؤه لا يمسّ الأوقات المحفوظة.
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

  /// الساعات المعروضة للزبائن في شاشة الحجز نفسها (9 ص – 9 م).
  static const List<int> _bookableHours = [
    9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
  ];

  /// أسماء الأيام بترتيب `extract(isodow)`: 1=الاثنين … 7=الأحد.
  static const List<String> _weekdayNames = [
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];

  List<DoctorAvailabilityEntry> _entries = const [];
  String? _selectedId;
  bool _loading = true;
  bool _saving = false;
  bool _hoursSaving = false;
  bool _readFailed = false;
  String _failure = '';

  /// مسودّة الاختيار الحالية (يوم ⇒ ساعات) قبل الحفظ.
  Map<int, Set<int>> _draft = <int, Set<int>>{};
  int _day = DateTime.now().weekday;

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
      final hadDraft = _isDirty;
      _entries = list;
      _readFailed = list.isEmpty && why.isNotEmpty;
      _failure = _readFailed ? why : '';
      if (list.isNotEmpty) {
        final keep = _selectedId;
        _selectedId = (keep != null && list.any((e) => e.id == keep))
            ? keep
            : list.first.id;
        // تحديث من الخادم لا يمسّ اختياراً لم يُحفظ بعد.
        if (!hadDraft) _resetDraft();
      }
    });
  }

  void _resetDraft() {
    final entry = _current;
    _draft = entry == null
        ? <int, Set<int>>{}
        : {
            for (final e in entry.hours.entries) e.key: Set<int>.of(e.value),
          };
  }

  void _pickDoctor(String id) {
    if (id == _selectedId) return;
    setState(() {
      _selectedId = id;
      _resetDraft();
    });
  }

  /// هل تختلف المسودّة عن المحفوظ على الخادم؟
  bool get _isDirty {
    final entry = _current;
    if (entry == null) return false;
    for (var d = 1; d <= 7; d++) {
      final draft = _draft[d] ?? const <int>{};
      final saved = entry.hours[d] ?? const <int>{};
      if (draft.length != saved.length || !draft.containsAll(saved)) {
        return true;
      }
    }
    return false;
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
              e.copyWith(bookingOpen: res.open)
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
          ? 'تم تشغيل الحجز — الحجز صار متاحاً في الساعات المحددة'
          : 'تم إطفاء الحجز — لن يستطيع أي زبون حجز موعد',
      true,
    );
  }

  Future<void> _saveHours() async {
    final entry = _current;
    if (entry == null || _hoursSaving || !_isDirty) return;
    setState(() => _hoursSaving = true);
    final res = await DoctorService.instance.saveAvailability(entry.id, _draft);
    if (!mounted) return;
    setState(() {
      _hoursSaving = false;
      if (res.ok) {
        _entries = [
          for (final e in _entries)
            if (e.id == entry.id)
              e.copyWith(hours: {
                for (final x in _draft.entries) x.key: Set<int>.of(x.value),
              })
            else
              e,
        ];
        _resetDraft();
      }
    });
    _toast(
      res.ok
          ? 'تم حفظ أوقات الحجز — ${res.count} ساعة في الأسبوع'
          : res.error,
      res.ok,
    );
  }

  void _toggleHour(int hour) {
    if (_hoursSaving) return;
    setState(() {
      final set = _draft.putIfAbsent(_day, () => <int>{});
      if (!set.remove(hour)) set.add(hour);
      if (set.isEmpty) _draft.remove(_day);
    });
  }

  void _selectAllHours() {
    if (_hoursSaving) return;
    setState(() => _draft[_day] = <int>{..._bookableHours});
  }

  void _clearDay() {
    if (_hoursSaving) return;
    setState(() => _draft.remove(_day));
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

  static String _hourLabel(int h) {
    final suffix = h < 12 ? 'ص' : 'م';
    final base = h % 12 == 0 ? 12 : h % 12;
    return '$base $suffix';
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
          body: 'زر واحد يفتح الحجز أو يغلقه كله، وجدول أسبوعي يحدد '
              'أي الأيام والساعات يستقبل فيها الطبيب. '
              'والساعة نفسها لا تُحجز مرتين.',
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
        _HoursCard(
          weekdayNames: _weekdayNames,
          hours: _bookableHours,
          selectedDay: _day,
          draft: _draft,
          closed: !open,
          saving: _hoursSaving,
          dirty: _isDirty,
          onDay: (d) => setState(() => _day = d),
          onHour: _toggleHour,
          onSelectAll: _selectAllHours,
          onClearDay: _clearDay,
          onSave: _saveHours,
          hourLabel: _hourLabel,
        ),
        const SizedBox(height: 16),
        _NoteLine(
          icon: Icons.calendar_month_rounded,
          color: open ? AppColors.primary : AppColors.danger,
          text: open
              ? 'الحجز متاح الآن. الساعة تصير خضراء للزبون إذا كانت '
                  'مختارة هنا وغير محجوزة، والحمراء لا تُضغط.'
              : 'الحجز مغلق الآن: لا يستطيع أي زبون تثبيت موعد. '
                  'أوقاتك المحفوظة تبقى كما هي وتعود مع التشغيل.',
        ),
        const SizedBox(height: 10),
        _NoteLine(
          icon: Icons.bolt_rounded,
          color: AppColors.textSecondary,
          text: 'تغيير الزر أو الأوقات يسري فوراً على كل الزبائن. '
              'ولا يغيّر أحدهما الآخر.',
        ),
      ],
    );
  }
}

/// بطاقة الساعات: تبويب أسبوعي + شبكة ساعات اليوم + حفظ صريح.
class _HoursCard extends StatelessWidget {
  const _HoursCard({
    required this.weekdayNames,
    required this.hours,
    required this.selectedDay,
    required this.draft,
    required this.closed,
    required this.saving,
    required this.dirty,
    required this.onDay,
    required this.onHour,
    required this.onSelectAll,
    required this.onClearDay,
    required this.onSave,
    required this.hourLabel,
  });

  final List<String> weekdayNames;
  final List<int> hours;
  final int selectedDay;
  final Map<int, Set<int>> draft;
  final bool closed;
  final bool saving;
  final bool dirty;
  final ValueChanged<int> onDay;
  final ValueChanged<int> onHour;
  final VoidCallback onSelectAll;
  final VoidCallback onClearDay;
  final VoidCallback onSave;
  final String Function(int) hourLabel;

  int get _total => draft.values.fold(0, (sum, s) => sum + s.length);

  @override
  Widget build(BuildContext context) {
    final daySet = draft[selectedDay] ?? const <int>{};
    // ★ الشرائح تبدأ من بطاقة اليوم ثم ما بعده — لا من بطاقة أمس.
    final todayWeekday = DateTime.now().weekday;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule_rounded,
                  color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ساعات الحجز الأسبوعية',
                  style: GoogleFonts.cairo(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (dirty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'غير محفوظ',
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.danger,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'اختر اليوم ثم الساعات التي يستقبل فيها الطبيب. '
            'الساعات المعروضة للزبائن من 9 صباحاً حتى 9 مساءً.',
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 58,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: weekdayNames.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final day = ((todayWeekday - 1 + i) % 7) + 1;
                return _DayChip(
                  label: day == todayWeekday
                      ? 'اليوم'
                      : weekdayNames[day - 1],
                  count: (draft[day] ?? const <int>{}).length,
                  selected: day == selectedDay,
                  onTap: () => onDay(day),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: AppColors.divider),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${weekdayNames[selectedDay - 1]} — '
                  '${daySet.isEmpty ? 'بلا ساعات' : '${daySet.length} ساعة'}',
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              TextButton(
                onPressed: saving ? null : onSelectAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'تحديد الكل',
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
              TextButton(
                onPressed: saving ? null : onClearDay,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'مسح اليوم',
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final h in hours)
                _HourChip(
                  label: hourLabel(h),
                  selected: daySet.contains(h),
                  enabled: !saving,
                  onTap: () => onHour(h),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _total == 0
                      ? 'لا ساعات محددة — كل الساعات متاحة عند فتح الزر'
                      : 'المجموع: $_total ساعة في الأسبوع',
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: (saving || !dirty) ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor:
                      AppColors.divider.withValues(alpha: 0.6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'حفظ الأوقات',
                        style: GoogleFonts.cairo(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
              ),
            ],
          ),
          if (closed) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 15, color: AppColors.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'الحجز مغلق الآن — تعديل الساعات وحفظها مسموح، '
                    'ولن يفتح الزر تلقائياً.',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      height: 1.5,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.divider;
    return Material(
      color: selected
          ? AppColors.primary.withValues(alpha: 0.1)
          : AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 86,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color, width: selected ? 1.4 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.cairo(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: selected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                count == 0 ? '—' : '$count',
                style: GoogleFonts.cairo(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HourChip extends StatelessWidget {
  const _HourChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : AppColors.background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 62,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.divider,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      ),
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
                              ? 'الحجز في الساعات المحددة أدناه'
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
