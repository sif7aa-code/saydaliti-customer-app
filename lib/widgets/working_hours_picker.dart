import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/shop_status.dart';

/// نتيجة اختيار الأيام والساعة: قيم الصيدلية (HH:mm) ونص جاهز للعرض
/// يُحفظ في `working_hours` للطبيب أو يُعرض كما هو.
class WorkingHoursChoice {
  const WorkingHoursChoice({
    required this.open,
    required this.close,
    required this.days,
    required this.text,
  });

  /// «HH:mm» — صيغة الوقت التي تفهمها شاشة الصيدلية.
  final String open;
  final String close;

  /// «يومياً» أو قائمة الأيام بالعربية.
  final String days;

  /// «الأيام · 09:00 ص – 02:00 م» — يظهر كما هو في البروفايل.
  final String text;
}

/// ورقة اختيار أيام وساعات الدوام.
///
/// [fullWeek] = سبعة أيام قابلة للاختيار (ملف الطبيب)؛ وبإيقافها تُعرض
/// الخيارات الأربعة نفسها المستخدمة في أوقات الصيدليات حتى يبقى
/// تخزين `working_days` مفهوماً لكل الشاشات.
///
/// يُقرأ النص السابق عبر [ShopSchedule.parse] نفسه، فلا تنشأ صيغة ثانية
/// للوقت في التطبيق.
Future<WorkingHoursChoice?> showWorkingHoursPicker(
  BuildContext context, {
  String initialText = '',
  String initialDays = '',
  bool fullWeek = true,
  String title = 'أيام وساعات الدوام',
}) {
  return showModalBottomSheet<WorkingHoursChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _WorkingHoursSheet(
      initialText: initialText,
      initialDays: initialDays,
      fullWeek: fullWeek,
      title: title,
    ),
  );
}

class _WorkingHoursSheet extends StatefulWidget {
  const _WorkingHoursSheet({
    required this.initialText,
    required this.initialDays,
    required this.fullWeek,
    required this.title,
  });

  final String initialText;
  final String initialDays;
  final bool fullWeek;
  final String title;

  @override
  State<_WorkingHoursSheet> createState() => _WorkingHoursSheetState();
}

class _WorkingHoursSheetState extends State<_WorkingHoursSheet> {
  /// ترتيب أيام الأسبوع العربي: السبت أولاً.
  static const List<int> _weekOrder = <int>[6, 7, 1, 2, 3, 4, 5];

  static const Map<int, String> _dayNames = <int, String>{
    1: 'الاثنين',
    2: 'الثلاثاء',
    3: 'الأربعاء',
    4: 'الخميس',
    5: 'الجمعة',
    6: 'السبت',
    7: 'الأحد',
  };

  static const List<String> _presets = <String>[
    'يومياً',
    'السبت - الخميس',
    'الجمعة فقط',
    'عطلة أسبوعية',
  ];

  late Set<int> _days;
  late String _preset;
  late TimeOfDay _open;
  late TimeOfDay _close;

  @override
  void initState() {
    super.initState();
    final schedule = ShopSchedule.parse(
      workingHours: widget.initialText,
      workingDays: widget.initialDays.trim().isEmpty
          ? widget.initialText
          : widget.initialDays,
      manualOpen: true,
    );
    _days = {...schedule.openDays};
    _preset = _presets.contains(widget.initialDays.trim())
        ? widget.initialDays.trim()
        : 'يومياً';
    _open = schedule.hoursKnown
        ? TimeOfDay(
            hour: schedule.openMinutes ~/ 60,
            minute: schedule.openMinutes % 60,
          )
        : const TimeOfDay(hour: 9, minute: 0);
    _close = schedule.hoursKnown
        ? TimeOfDay(
            hour: schedule.closeMinutes ~/ 60,
            minute: schedule.closeMinutes % 60,
          )
        : const TimeOfDay(hour: 14, minute: 0);
  }

  String get _daysLabel {
    if (!widget.fullWeek) return _preset;
    if (_days.length >= 7) return 'يومياً';
    return _weekOrder
        .where(_days.contains)
        .map((d) => _dayNames[d]!)
        .join('، ');
  }

  String get _hoursLabel =>
      '${formatClock(_open.hour * 60 + _open.minute)} – '
      '${formatClock(_close.hour * 60 + _close.minute)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  String get _openValue => '${_two(_open.hour)}:${_two(_open.minute)}';

  String get _closeValue => '${_two(_close.hour)}:${_two(_close.minute)}';

  Future<void> _pickTime({required bool isOpen}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isOpen ? _open : _close,
      helpText: isOpen ? 'وقت بداية الدوام' : 'وقت نهاية الدوام',
    );
    if (picked == null) return;
    setState(() {
      if (isOpen) {
        _open = picked;
      } else {
        _close = picked;
      }
    });
  }

  void _save() {
    final days = _daysLabel.trim().isEmpty ? 'يومياً' : _daysLabel;
    Navigator.of(context).pop(
      WorkingHoursChoice(
        open: _openValue,
        close: _closeValue,
        days: days,
        text: '$days · $_hoursLabel',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _TimeBox(
                        label: 'وقت البداية',
                        value: formatClock(_open.hour * 60 + _open.minute),
                        icon: Icons.wb_sunny_outlined,
                        onTap: () => _pickTime(isOpen: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TimeBox(
                        label: 'وقت النهاية',
                        value: formatClock(_close.hour * 60 + _close.minute),
                        icon: Icons.nights_stay_outlined,
                        onTap: () => _pickTime(isOpen: false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  widget.fullWeek ? 'أيام الدوام' : 'أيام العمل',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.fullWeek)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final day in _weekOrder)
                        _DayChip(
                          label: _dayNames[day]!,
                          selected: _days.contains(day),
                          onTap: () => setState(() {
                            if (!_days.remove(day)) _days.add(day);
                          }),
                        ),
                    ],
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in _presets)
                        ChoiceChip(
                          label: Text(
                            preset,
                            style: GoogleFonts.cairo(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: _preset == preset
                                  ? Colors.white
                                  : AppColors.textPrimary,
                            ),
                          ),
                          selected: _preset == preset,
                          selectedColor: AppColors.primary,
                          backgroundColor: AppColors.surface,
                          side: BorderSide(
                            color: _preset == preset
                                ? AppColors.primary
                                : AppColors.divider,
                          ),
                          onSelected: (_) =>
                              setState(() => _preset = preset),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$_daysLabel · $_hoursLabel',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.cairo(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: AppColors.primaryDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          'إلغاء',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          'حفظ الأيام والساعة',
                          style: GoogleFonts.cairo(
                            fontSize: 13.5,
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
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.divider,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeBox extends StatelessWidget {
  const _TimeBox({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: GoogleFonts.cairo(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
