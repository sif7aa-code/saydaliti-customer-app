import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// ★ «الاستقطاعات» — الأدمن وحده يحدد استقطاع كل عيادة وكل صيدلية.
///
///   عيادة (طبيب/ممرض): استقطاع واحد لكل كشفية.
///   صيدلية: استقطاع واحد لكل طلب مسلَّم.
///   الطريقة لكل حساب على حدة: مبلغ ثابت (250/500/750…) أو نسبة (10%…).
///
///   كل الأرقام تأتي من `deduction_settings` عبر دوال القاعدة الواحدة،
///   ولا يوجد رقم مكتوب في التطبيق. تغيير هنا يسري على الحجوزات
///   والتسويات القادمة؛ القيود السابقة تبقى كما كُتبت.
class AdminDeductionsScreen extends StatefulWidget {
  const AdminDeductionsScreen({super.key});

  @override
  State<AdminDeductionsScreen> createState() => _AdminDeductionsScreenState();
}

class _AdminDeductionsScreenState extends State<AdminDeductionsScreen> {
  bool _loading = true;
  String? _error;
  int _tab = 0;
  List<Map<String, dynamic>> _doctors = const [];
  List<Map<String, dynamic>> _shops = const [];
  Map<String, dynamic> _doctorDefault = const {};
  Map<String, dynamic> _shopDefault = const {};
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await SupabaseService.instance.adminListDeductions();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res == null) {
        _error = SupabaseService.instance.lastDeductionError ??
            'تعذّر تحميل الاستقطاعات';
        return;
      }
      // الافتراضي يأتي من القاعدة وحدها (deduction_default) — لا ثابت
      // مكرَّر في الواجهة؛ غيابه يعني أن ملف SQL غير مثبَّت.
      final dd = res['doctor_default'];
      final sd = res['shop_default'];
      if (dd is! Map || sd is! Map) {
        _error = SupabaseService.instance.lastDeductionError ??
            'افتراضيات الاستقطاع غير مثبَّتة — شغّل SQL_ADMIN_DEDUCTIONS.sql';
        return;
      }
      _doctorDefault = Map<String, dynamic>.from(dd);
      _shopDefault = Map<String, dynamic>.from(sd);
      _doctors = _rows(res['doctors']);
      _shops = _rows(res['shops']);
    });
  }

  static List<Map<String, dynamic>> _rows(Object? v) => v is List
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const [];

  static String _text(Object? v) => '${v ?? ''}'.trim();

  static double _num(Object? v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  static bool _isDefault(Map<String, dynamic> item) => item['is_default'] == true;

  static String _method(Map<String, dynamic> item) =>
      _text(item['method']).isEmpty ? 'fixed' : _text(item['method']);

  static String _label(Map<String, dynamic> item, bool doctor, {bool short = false}) {
    final method = _method(item);
    final value = _num(item['value']);
    final v = value == value.roundToDouble()
        ? value.round().toString()
        : value.toString();
    final base = method == 'percent'
        ? (short ? '$v%' : 'نسبة $v% من كل ${doctor ? 'كشفية' : 'طلب'}')
        : (short
            ? '$v د.ع'
            : 'ثابت $v د.ع لكل ${doctor ? 'كشفية' : 'طلب'}');
    return _isDefault(item) ? 'افتراضي · $base' : base;
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

  Future<void> _edit(Map<String, dynamic> item, bool doctor) async {
    final party = doctor ? 'doctor' : 'shop';
    final id = _text(item['id']);
    if (id.isEmpty) return;
    final name = _text(item['name']);
    final def = doctor ? _doctorDefault : _shopDefault;
    final currentMethod = _method(item);
    final currentValue = _num(item['value']);

    final method = ValueNotifier<String>(currentMethod);
    final valueCtrl = TextEditingController(
      text: currentValue == currentValue.roundToDouble()
          ? currentValue.round().toString()
          : currentValue.toString(),
    );
    var saving = false;
    String? inlineError;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> save(String m, {bool reset = false}) async {
            setSheet(() {
              saving = true;
              inlineError = null;
            });
            final value = reset ? null : double.tryParse(valueCtrl.text.trim());
            if (!reset && value == null) {
              setSheet(() {
                saving = false;
                inlineError = 'اكتب قيمة الاستقطاع';
              });
              return;
            }
            if (!reset && m == 'percent' && (value! < 0 || value > 100)) {
              setSheet(() {
                saving = false;
                inlineError = 'النسبة بين 0 و100';
              });
              return;
            }
            final res = await SupabaseService.instance.adminSetDeduction(
              party: party,
              refId: id,
              method: reset ? 'default' : m,
              value: reset ? null : value,
            );
            if (!mounted) return;
            if (res == null) {
              setSheet(() {
                saving = false;
                inlineError = SupabaseService.instance.lastDeductionError ??
                    'تعذّر الحفظ';
              });
              return;
            }
            Navigator.of(ctx).pop(true);
          }

          final isFixed = method.value == 'fixed';
          final quick = isFixed
              ? const [250.0, 500.0, 750.0, 1000.0]
              : const [5.0, 10.0, 15.0, 20.0];
          return Padding(
            padding: EdgeInsets.only(
              left: 18,
              right: 18,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        doctor ? 'استقطاع العيادة' : 'استقطاع الصيدلية',
                        style: GoogleFonts.cairo(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Text(
                  name.isEmpty ? '' : name,
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _MethodChip(
                      label: 'مبلغ ثابت',
                      selected: isFixed,
                      onTap: () {
                        method.value = 'fixed';
                        valueCtrl.text =
                            _num(def['value']).round().toString();
                        setSheet(() {});
                      },
                    ),
                    const SizedBox(width: 8),
                    _MethodChip(
                      label: 'نسبة %',
                      selected: !isFixed,
                      onTap: () {
                        method.value = 'percent';
                        valueCtrl.text = _num(def['value']).toString();
                        setSheet(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: valueCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: isFixed
                        ? 'المبلغ لكل ${doctor ? 'كشفية' : 'طلب'} (د.ع)'
                        : 'النسبة من كل ${doctor ? 'كشفية' : 'طلب'} (%)',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final q in quick)
                      ActionChip(
                        label: Text(
                          q == q.roundToDouble()
                              ? q.round().toString()
                              : q.toString(),
                        ),
                        onPressed: saving
                            ? null
                            : () {
                                valueCtrl.text = q == q.roundToDouble()
                                    ? q.round().toString()
                                    : q.toString();
                                setSheet(() {});
                              },
                      ),
                  ],
                ),
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
                    onPressed: saving ? null : () => save(method.value),
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(
                      'حفظ الاستقطاع',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                ),
                if (!_isDefault(item)) ...[
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: saving ? null : () => save('default', reset: true),
                      child: Text(
                        'العودة للافتراضي (${_label(def, doctor, short: true)})',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'يسري على ${doctor ? 'الحجوزات' : 'الطلبات'} القادمة. '
                  'القيود السابقة تبقى كما هي.',
                  style: GoogleFonts.cairo(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textHint,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    valueCtrl.dispose();
    method.dispose();
    if (saved == true) {
      await _load();
      _toast('تم حفظ الاستقطاع — ${name.isEmpty ? 'الحساب' : name}');
    }
  }

  List<Map<String, dynamic>> get _visible {
    final q = _search.text.trim().toLowerCase();
    final src = _tab == 0 ? _doctors : _shops;
    if (q.isEmpty) return src;
    return src.where((e) {
      final hay = '${_text(e['name'])} ${_text(e['phone'])} '
              '${_text(e['secretary_phone'])} ${_text(e['owner_phone'])}'
          .toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final doctor = _tab == 0;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          'الاستقطاعات',
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
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView()
                : Column(
                    children: [
                      _header(),
                      _tabs(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: doctor
                                ? 'ابحث باسم الطبيب أو رقمه'
                                : 'ابحث باسم الصيدلية أو رقم صاحبها',
                            prefixIcon: const Icon(Icons.search_rounded),
                            filled: true,
                            fillColor: AppColors.surface,
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
                      ),
                      Expanded(
                        child: _visible.isEmpty
                            ? _empty()
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                                itemCount: _visible.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) => _tile(_visible[i], doctor),
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
          'أنت وحدك تحدد استقطاع كل حساب: مبلغ ثابت أو نسبة. '
          'العيادة (الطبيب والممرض) استقطاعها واحد لكل كشفية، '
          'والصيدلية استقطاعها واحد لكل طلب مسلَّم.',
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
            Expanded(
              child: _TabButton(
                label: 'العيادات (${_doctors.length})',
                selected: _tab == 0,
                onTap: () => setState(() => _tab = 0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TabButton(
                label: 'الصيدليات (${_shops.length})',
                selected: _tab == 1,
                onTap: () => setState(() => _tab = 1),
              ),
            ),
          ],
        ),
      );

  Widget _tile(Map<String, dynamic> item, bool doctor) {
    final name = _text(item['name']);
    final phone = _text(item['phone']);
    final secretary = _text(item['secretary_phone']);
    final owner = _text(item['owner_phone']);
    final inactive = doctor && item['is_active'] == false;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _edit(item, doctor),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                child: Icon(
                  doctor
                      ? Icons.local_hospital_rounded
                      : Icons.medication_rounded,
                  color: AppColors.primary,
                  size: 21,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name.isEmpty ? 'بلا اسم' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (inactive) ...[
                          const SizedBox(width: 6),
                          Text(
                            'موقوف',
                            style: GoogleFonts.cairo(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: AppColors.danger,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (doctor && phone.isNotEmpty)
                      Text(
                        'الطبيب: $phone',
                        style: GoogleFonts.cairo(
                          fontSize: 10.5,
                          color: AppColors.textHint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (doctor && secretary.isNotEmpty)
                      Text(
                        'الممرض: $secretary',
                        style: GoogleFonts.cairo(
                          fontSize: 10.5,
                          color: AppColors.textHint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (!doctor && owner.isNotEmpty)
                      Text(
                        'صاحب الصيدلية: $owner',
                        style: GoogleFonts.cairo(
                          fontSize: 10.5,
                          color: AppColors.textHint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _label(item, doctor, short: true),
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w900,
                      color: _isDefault(item)
                          ? AppColors.textSecondary
                          : AppColors.primary,
                    ),
                  ),
                  Text(
                    _isDefault(item) ? 'افتراضي' : 'مخصص',
                    style: GoogleFonts.cairo(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.edit_outlined,
                size: 18,
                color: AppColors.textHint,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
        children: [
          Icon(
            _tab == 0 ? Icons.local_hospital_outlined : Icons.medication_outlined,
            size: 48,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 10),
          Text(
            _search.text.trim().isEmpty
                ? (_tab == 0 ? 'لا عيادات بعد' : 'لا صيدليات بعد')
                : 'لا نتيجة للبحث',
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
          const Icon(Icons.error_outline_rounded,
              size: 48, color: AppColors.danger),
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
            fontSize: 12.5,
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
