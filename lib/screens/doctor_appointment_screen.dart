import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/auth_fields.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/session_gate.dart';
import '../services/auth_service.dart';
import '../services/doctor_service.dart';
import '../services/location_service.dart';
import '../widgets/doctor_appointment_details.dart';
import '../widgets/location_map_picker.dart';
import 'my_doctor_appointments_screen.dart';

/// ★ حجز موعد دكتور/ة — الخدمة الثانية في تبويب **خدمات**.
///
///   الحقول كما حدّدها الأدمن (10-31): نوع التخصص (قائمة منسدلة) · اسم
///   الدكتور · اسم المريض أو صاحب الحجز · رقم هاتف المريض · تاريخ
///   الحجز · الموقع · زر «تثبيت الحجز».
///
///   ★ الحجز من دليل الأطباء (2026-11-19): اسم الدكتور يصل من البطاقة
///     **مقفولاً** لا يُعدَّل، وحقل الهاتف هو **رقم المريض** يُعبَّأ برقم
///     صاحب الحساب ويبقى قابلاً للتعديل. قبل هذا كان رقم الطبيب/السكرتير
///     هو ما يُعبَّأ في حقل الهاتف، فيظهر رقم السكرتير في الحجز الموافق
///     عليه ويتصل السكرتير بنفسه بدل المريض.
///
///   ما يُميَّز هنا عن «طلب مندوب» أن الحجز **لا يُمثَّل كطلب شراء**:
///   يُكتب في `doctor_appointments` وحده برقم من سلسلته الخاصة، فلا هو
///   يُعدّ في دورة الخصم ولا في محفظة صيدلية ولا في لوحة الطلبات المكررة.
class DoctorAppointmentScreen extends StatefulWidget {
  const DoctorAppointmentScreen({
    super.key,
    this.prefillDoctorName,
    this.prefillSpecialty,
  });

  /// تعبئة مبدئية من دليل الأطباء: نقرة بطاقة الطبيب تنقل اسمه وتخصصه
  /// إلى نموذج الحجز مباشرة، **والاسم يُقفل** لأن الطبيب مختار من دليل
  /// التطبيق فعلاً. رقم العيادة لا يدخل هذا النموذج: الحقل هنا هاتف
  /// المريض الذي تتصل به العيادة.
  final String? prefillDoctorName;
  final String? prefillSpecialty;

  @override
  State<DoctorAppointmentScreen> createState() =>
      _DoctorAppointmentScreenState();
}

class _DoctorAppointmentScreenState extends State<DoctorAppointmentScreen> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  final TextEditingController _doctorCtrl = TextEditingController();
  final TextEditingController _patientCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();

  String _specialty = DoctorService.specialties.first;
  DateTime? _date;
  TimeOfDay? _time;

  /// ★ الموعد بطائق لا منتقيات (2026-11-23): «التاريخ» صفّ بطائق اسم
  ///   اليوم فوق وتاريخه تحته، و«الوقت» بطائق ساعات — بلا منتقي يدوي.
  static const List<String> _weekdayNames = [
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];
  static const List<int> _slotHours = [
    9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
  ];
  /// أسبوع كامل يبدأ من اليوم — سبع بطائق باسم اليوم وتاريخه.
  static const int _daysAhead = 7;

  bool _locating = false;
  bool _booking = false;
  String _error = '';

  /// ★ أوقات الطبيب للأسبوع كله كما في القاعدة (2026-11-24):
  ///   بطاقة اليوم تُلوَّن من توفر يومها، والساعات من يومها.
  ///   `null` = تعذّرت القراءة (دالة غير مثبّتة أو بلا شبكة) فتعود
  ///   الساعات المستقبلية متاحة كما كانت — والقاعدة تبقى الحارس.
  DoctorWeekAvailability? _week;
  bool _availabilityLoading = false;
  int _availabilityToken = 0;
  Timer? _nameDebounce;

  /// اسم الدكتور قادم من بطاقة الدليل ⇒ حقل مقفول.
  bool get _doctorLocked => (widget.prefillDoctorName?.trim() ?? '').isNotEmpty;

  /// رقم صاحب الحساب: التعبئة الافتراضية لحقل «رقم المريض». يُعاد بعد
  /// كل حجز بدل تركه فارغاً، ويبقى قابلاً للتعديل (حجز لغيره).
  String get _ownPhone {
    final d = AuthFields.digits(AuthService.instance.phone ?? '');
    return d.length == AuthFields.phoneLength ? d : '';
  }

  @override
  void initState() {
    super.initState();
    // تعبئة الدليل: اسم الطبيب المعروض مسبقاً مقفول، والتخصص يُقبل فقط
    // إن كان من قائمة الأدمن وإلا يبقى الافتراضي.
    final preName = widget.prefillDoctorName?.trim() ?? '';
    if (preName.isNotEmpty) _doctorCtrl.text = preName;
    final preSpec = widget.prefillSpecialty?.trim() ?? '';
    if (DoctorService.specialties.contains(preSpec)) {
      _specialty = preSpec;
    }
    // ★ حقل الهاتف للمريض لا للعيادة: رقم الطبيب/السكرتير لا يُعبَّأ هنا
    //   أبداً، وإلا ظهر رقم السكرتير في الحجز الموافق عليه.
    final own = _ownPhone;
    if (own.isNotEmpty) _phoneCtrl.text = own;
    // ★ اليوم الافتراضي بطاقة مختارة مسبقاً (اليوم إن بقيت فيه ساعة،
    //   وإلا الغد) فيبدأ الزبون من قائمة واضحة لا من فراغ.
    _date = _defaultDay;
    // اسم الطبيب يُعاد كتابته يدوياً أحياناً: تغيّره يعيد جلب أوقاته.
    _doctorCtrl.addListener(_onDoctorNameChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detectLocation();
      _loadAvailability();
    });
  }

  @override
  void dispose() {
    _nameDebounce?.cancel();
    _doctorCtrl.removeListener(_onDoctorNameChanged);
    _doctorCtrl.dispose();
    _patientCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _onDoctorNameChanged() {
    _nameDebounce?.cancel();
    _nameDebounce = Timer(
      const Duration(milliseconds: 500),
      _loadAvailability,
    );
  }

  /// أوقات الطبيب للأسبوع المعروض من نداء واحد (`doctor_week_availability`).
  /// ردّ متأخر لاسم سابق يُتجاهل بمقارنة الرمز حتى لا تُلوَّن الأيام
  /// بأوقات طبيب آخر.
  Future<void> _loadAvailability() async {
    final name = _doctorCtrl.text.trim();
    final token = ++_availabilityToken;
    if (mounted) setState(() => _availabilityLoading = true);
    DoctorWeekAvailability? week;
    if (name.isNotEmpty) {
      week = await DoctorService.instance.weekAvailability(name, _today);
    }
    if (!mounted || token != _availabilityToken) return;
    setState(() {
      _week = week;
      _availabilityLoading = false;
      // ساعة صارت غير متاحة لا تبقى مختارة بصمت.
      final d = _date;
      if (_time != null && d != null && !_slotAvailable(d, _time!.hour)) {
        _time = null;
      }
    });
  }

  Future<void> _detectLocation({bool manual = false}) async {
    if (_locating) return;
    setState(() => _locating = true);
    await LocationService.instance.determinePosition(overridePin: manual);
    if (!mounted) return;
    setState(() => _locating = false);
  }

  /// نفس خريطة السلة وطلب المندوب: دبوس + «تأكيد موقعي».
  Future<void> _pickOnMap() async {
    final ok = await LocationMapPicker.open(context);
    if (!ok || !mounted) return;
    setState(() {});
  }

  /// اليوم بلا وقت — بداية الأسبوع المعروض.
  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// الأيام المعروضة: أسبوع كامل يبدأ من اليوم.
  List<DateTime> get _days {
    final today = _today;
    return List.generate(_daysAhead, (i) => today.add(Duration(days: i)));
  }

  /// اليوم الافتراضي: اليوم إن بقيت فيه ساعة لم تأتِ، وإلا الغد.
  DateTime get _defaultDay =>
      _dayHasFutureSlot(_today) ? _today : _today.add(const Duration(days: 1));

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _dayHasFutureSlot(DateTime day) {
    // آخر ساعة معروضة (9 مساءً) هي الفيصل: بعدها اليوم بلا ساعة متاحة.
    final last = DateTime(day.year, day.month, day.day, _slotHours.last);
    return last.isAfter(DateTime.now());
  }

  static bool _slotFuture(DateTime day, int hour) =>
      DateTime(day.year, day.month, day.day, hour)
          .isAfter(DateTime.now());

  /// ★ أطفأ الطبيب زر الحجز: لا خيار واحد أخضر، والقاعدة ترفض أيضاً.
  bool get _bookingClosed => _week?.bookingOpen == false;

  /// الساعة قابلة للحجز: وقتها لم يمضِ، والطبيب يقبلها أسبوعياً
  /// إن كان قد ضبط أوقاته، ولا يوجد عليها حجز قائم.
  bool _slotAvailable(DateTime day, int hour) {
    if (!_slotFuture(day, hour)) return false;
    final week = _week;
    if (week == null) return true;
    final av = week.on(day);
    if (av == null) return true;
    return av.isOpen(hour);
  }

  /// هل في اليوم ساعة خضراء واحدة على الأقل؟ بطاقة اليوم تُلوَّن منها.
  bool _dayOpen(DateTime day) {
    for (final h in _slotHours) {
      if (_slotAvailable(day, h)) return true;
    }
    return false;
  }

  static String _weekdayName(DateTime d) => _weekdayNames[d.weekday - 1];

  /// شارة البطاقة: «اليوم» و«غداً» فقط — وما بعدهما باسم اليوم وحده.
  static String _dayBadge(DateTime d) {
    final diff = DateTime(d.year, d.month, d.day).difference(_today).inDays;
    if (diff == 0) return 'اليوم';
    if (diff == 1) return 'غداً';
    return '';
  }

  static String _slotLabel(int hour) {
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$h12:00 ${hour >= 12 ? 'م' : 'ص'}';
  }

  void _selectDay(DateTime d) {
    setState(() {
      _date = d;
      // ساعة اليوم السابق قد تكون مضت في اليوم الجديد: تُلغى بدل
      // أن يبقى الموعد ماضياً بصمت.
      if (_time != null && !_slotAvailable(d, _time!.hour)) _time = null;
      _error = '';
    });
  }

  void _selectTime(int hour) {
    final d = _date;
    if (d == null) {
      setState(() => _error = 'اختر اليوم أولاً ثم أختر الساعة');
      return;
    }
    if (!_slotAvailable(d, hour)) {
      setState(() => _error = 'هذا الوقت غير متاح عند الطبيب — اختر ساعة خضراء');
      return;
    }
    setState(() {
      _time = TimeOfDay(hour: hour, minute: 0);
      _error = '';
    });
  }

  /// الموعد الذي يُرسل للقاعدة: اليوم المختار من البطائق وساعته.
  /// بلا ساعة لا موعد — لا تخمين وقت من عندنا.
  DateTime? get _appointmentAt {
    final d = _date;
    final t = _time;
    if (d == null || t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<void> _book() async {
    if (_booking) return;
    // ★ الدخول إجباري: لا يثبت حجز بلا حساب، وبعد نجاح الدخول يكمل
    //   التثبيت نفسه بالبيانات التي كتبها الزبون.
    if (!hasAppSession) {
      pushAppLogin(context, onSuccess: () {
        _book();
      });
      return;
    }
    // الطبيب أطفأ الاستقبال: لا إرسال، والرسالة تسمّي السبب.
    if (_bookingClosed) {
      setState(() =>
          _error = 'الطبيب أطفأ استقبال الحجوزات حالياً — جرّب لاحقاً');
      _loadAvailability();
      return;
    }
    if (!(_form.currentState?.validate() ?? false)) return;
    // ★ الموعد بطائق لا `TextFormField`، فلا يدخل في `validate()`:
    //   من ضغط «تثبيت الحجز» قبل اختيار الساعة كان ينهار على check-null.
    final when = _appointmentAt;
    if (when == null) {
      setState(() => _error = 'اختر وقت الحجز من البطائق قبل التثبيت');
      return;
    }
    // ★ لا حجز بوقت أو تاريخ مضى: اليوم مسموح فقط بساعة لم تأتِ بعد.
    if (!when.isAfter(DateTime.now())) {
      setState(() => _error = 'الموعد مضى — اختر وقتاً لاحقاً');
      return;
    }
    // وقته من القاعدة بين اليدين: لا إرسال لساعة حمراء حتى لا يرتد
    // الحجز برسالة المشغّل.
    final dayAv = _week?.on(when);
    if (dayAv != null && !dayAv.isOpen(when.hour)) {
      setState(() => _error = 'هذا الوقت غير متاح عند الطبيب — اختر ساعة خضراء');
      _loadAvailability();
      return;
    }

    setState(() {
      _booking = true;
      _error = '';
    });

    final loc = LocationService.instance;
    final res = await DoctorService.instance.book(
      specialty: _specialty,
      doctorName: _doctorCtrl.text,
      patientName: _patientCtrl.text,
      contactPhone: _phoneCtrl.text,
      appointmentAt: when,
      address: loc.currentAddress,
      latitude: loc.currentLat,
      longitude: loc.currentLng,
    );

    if (!mounted) return;
    setState(() => _booking = false);
    if (!res.ok) {
      // ★ نصّ الخادم كما هو: «رقم الهاتف للحجز يجب أن يكون 11 رقماً…»
      //   أو «الدالة غير مثبّتة على الخادم — شغّل ملف SQL الخاص بها».
      //   الثانية هي الدليل الوحيد أن `SQL_DOCTOR_APPOINTMENTS.sql` لم
      //   يُضغط عليه Run بعد، فتُقال ولا تُغطّى بكلام عام.
      setState(() => _error = res.error);
      _toast(res.error, false);
      return;
    }
    // ★ نسخة الحجز كما ملأها الآن: تُعرض فوراً إن سقطت القراءة من القاعدة،
    //   فلا يذهب «تثبيت الحجز» في نظر الزبون بلا أثر.
    await _showBookedDialog(
      DoctorAppointment(
        id: res.id,
        serial: res.serial,
        specialty: _specialty,
        doctorName: _doctorCtrl.text.trim(),
        patientName: _patientCtrl.text.trim(),
        contactPhone: _phoneCtrl.text.trim(),
        address: loc.currentAddress,
        // ★ حالة الخادم لا حالة مفترضة: حجزُ طبيب له سكرتير يعود
        //   `pending` (بانتظار الموافقة)، وطبيب بلا سكرتير يعود
        //   `approved` مباشرة.
        status: res.status.isEmpty ? 'pending' : res.status,
        bookedName: AuthService.instance.name ?? '',
        driverName: '',
        examFee: res.examFee > 0 ? res.examFee : 15000,
        appointmentAt: when,
        latitude: loc.currentLat,
        longitude: loc.currentLng,
        createdAt: DateTime.now(),
      ),
      pendingApproval: res.pendingApproval,
    );
  }

  /// تفاصيل الحجز من القاعدة حيث تُقرأ أوقاتها، لا من الذاكرة.
  ///
  /// `my_doctor_appointments` تعزل برقم الجلسة، فسطر المراقبة (متى ثُبّت،
  /// ومن أخذه) يمشي على الصفّ الذي كتبته `book_doctor_appointment` بنفسها.
  Future<void> _openDetails(DoctorAppointment booked) async {
    final rows = await DoctorService.instance.mine();
    if (!mounted) return;
    var chosen = booked;
    for (final r in rows) {
      if (r.id == booked.id) {
        chosen = r;
        break;
      }
    }
    await DoctorAppointmentDetails.show(context, appointment: chosen);
  }

  Future<void> _showBookedDialog(
    DoctorAppointment booked, {
    bool pendingApproval = false,
  }) async {
    final serial = booked.serial;
    final fee = CurrencyFormatter.format(booked.examFee);
    final wantDetails = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: Icon(
          pendingApproval
              ? Icons.hourglass_top_rounded
              : Icons.event_available_rounded,
          color: AppColors.primary,
          size: 42,
        ),
        title: Text(
          'تم تثبيت الحجز',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (serial.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'رقم الحجز $serial',
                  style: GoogleFonts.cairo(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              pendingApproval
                  // ★ الحجز عند العيادة: لا رقم قبل الموافقة، والكشفية
                  //   لا تُقيَّد إلا بها وبعد الاستقطاع الثابت.
                  ? 'حجزك الآن عند العيادة بانتظار الموافقة. عند موافقة '
                        'السكرتير يكتب رقم حجزك ويصلك إشعار به، وإن رُفض '
                        'يُبلَّغك التطبيق. كشفية الحجز $fee تُقيَّد في '
                        'محفظة العيادة عند الموافقة بعد خصم ثابت 500 دينار.'
                  : 'حجزك عند العيادة برقمه الخاص. كشفية الحجز $fee.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'حسناً',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          // ★ «تفاصيل الحجز» من داخل الحوار: الأدمن سأل لا تظهر التفاصيل
          //   بعد الحجز — فالبوابة تكون حيث ينتهي الحجز نفسه.
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(
              'تفاصيل الحجز',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // الحجز صار في القاعدة: تُفرَّغ الحقول حتى لا يُثبَّت الحجز نفسه
    // مرتين بنقرة ثانية، ويبقى التخصص مختاراً لأنه هو المقصود غالباً.
    // ★ الاسم المقفول لا يُفرَّغ: الاسم لا يُكتب بيد المستخدم فلا وسيلة
    //   لإعادته بعد المسح، ويبقى هاتف المريض معبّأً برقم صاحب الحساب.
    if (!_doctorLocked) _doctorCtrl.clear();
    _patientCtrl.clear();
    _phoneCtrl.text = _ownPhone;
    setState(() {
      _date = _defaultDay;
      _time = null;
      _error = '';
    });
    // الساعة الآن محجوزة: تُقرأ الأوقات من جديد فتصير حمراء للجميع.
    _loadAvailability();
    if (wantDetails == true) await _openDetails(booked);
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
        title: const Text('حجز موعد دكتور/ة'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const MyDoctorAppointmentsScreen(),
              ),
            ),
            tooltip: 'حجوزاتي',
            icon: const Icon(Icons.event_note_outlined),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _IntroCard(specialty: _specialty),
            const SizedBox(height: 14),

            // [1] نوع التخصص — قائمة منسدلة بأسماء الأدمن التسعة
            DropdownButtonFormField<String>(
              initialValue: _specialty,
              items: [
                for (final s in DoctorService.specialties)
                  DropdownMenuItem<String>(value: s, child: Text(s)),
              ],
              onChanged: (v) => setState(() => _specialty = v ?? _specialty),
              decoration: _inputDecoration('نوع التخصص'),
            ),
            const SizedBox(height: 12),

            // [2] اسم الدكتور — مقفول إن جاء من بطاقة الدليل
            TextFormField(
              controller: _doctorCtrl,
              readOnly: _doctorLocked,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                'اسم الدكتور',
                hint: 'مثال: د. علي الحسيني',
                helper: _doctorLocked
                    ? 'الطبيب المختار من الدليل — لا يُعدَّل'
                    : null,
                suffix: _doctorLocked
                    ? const Icon(
                        Icons.lock_outline_rounded,
                        color: AppColors.textSecondary,
                        size: 20,
                      )
                    : null,
              ),
              validator: (v) {
                final s = (v ?? '').trim();
                if (s.isEmpty) return 'أدخل اسم الدكتور';
                if (s.runes.length < 2) return 'اكتب اسمه كاملاً';
                return null;
              },
            ),
            const SizedBox(height: 12),

            // [3] اسم المريض أو صاحب الحجز
            TextFormField(
              controller: _patientCtrl,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                'اسم المريض أو صاحب الحجز',
                hint: 'الاسم الذي يُعرف به عند العيادة',
              ),
              validator: (v) {
                final s = (v ?? '').trim();
                if (s.isEmpty) return 'أدخل اسم المريض أو صاحب الحجز';
                if (s.runes.length < 2) return 'اكتب الاسم كاملاً';
                if (DoctorService.specialties.contains(s)) {
                  return 'هذا اسم تخصص — اكتب اسم الشخص';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),

            // [4] رقم المريض الشغال — العيادة تتصل به، فهو صاحب الحجز.
            //     لا يُعبَّأ برقم الطبيب/السكرتير أبداً، ويبقى قابلاً
            //     للتعديل لمن يحجز لشخص آخر.
            TextFormField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                'رقم المريض الشغال',
                hint: '07xxxxxxxxx',
                helper: 'هذا الرقم تتصل به العيادة لتأكيد الحجز',
              ),
              validator: (v) =>
                  AuthFields.phoneError(v ?? '', requireMobilePrefix: true),
            ),
            const SizedBox(height: 12),

            // [5] تاريخ الحجز ووقته — بطائق واضحة لا منتقيات يدوية
            _ScheduleSection(
              days: _days,
              slotHours: _slotHours,
              selectedDay: _date,
              selectedTime: _time,
              weekdayName: _weekdayName,
              dayBadge: _dayBadge,
              isSameDay: _sameDay,
              dayOpen: _dayOpen,
              weekLoaded: _week != null,
              closed: _bookingClosed,
              slotOpen: (h) => _date != null && _slotAvailable(_date!, h),
              slotLabel: _slotLabel,
              loading: _availabilityLoading,
              onDay: _selectDay,
              onTime: _selectTime,
              onClear: (_time == null)
                  ? null
                  : () => setState(() {
                      _time = null;
                      _error = '';
                    }),
            ),
            const SizedBox(height: 12),

            // [6] الموقع: تلقائي + تحديث + خريطة (نفس كتلة طلب المندوب)
            _LocationRow(
              locating: _locating,
              address: LocationService.instance.currentAddress,
              pinned: LocationService.instance.manualPinActive,
              onRefresh: () => _detectLocation(manual: true),
              onMap: _pickOnMap,
            ),

            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: AppColors.danger,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error,
                      style: GoogleFonts.cairo(
                        color: AppColors.danger,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _booking ? null : _book,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: _booking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  // ★ «تثبيت الحجز» = تقويم فيه علامة صح، لا قفل: القفل يوحي
                  //   للمستخدم أن الزر مغلق وهو يعمل.
                  : const Icon(Icons.event_available_rounded, size: 20),
              label: Text(
                _booking ? 'جاري التثبيت...' : 'تثبيت الحجز',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'ملاحظة: يُعرض الحجز على عيادة الطبيب للموافقة أولاً. عند '
              'الموافقة يكتب السكرتير رقم حجزك ويصلك إشعار به. كشفية الحجز '
              '15,000 د.ع تُقيَّد في محفظة العيادة عند الموافقة بعد خصم '
              'ثابت 500 دينار، ولا يدخل الحجز في طلبات الصيدليات ولا في '
              'الخصومات.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 11,
                height: 1.5,
                color: AppColors.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static InputDecoration _inputDecoration(
    String label, {
    String? hint,
    String? helper,
    Widget? suffix,
  }) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        suffixIcon: suffix,
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.all(14),
      );
}

/// سطر بطاقي صغير يذكر بالخدمة — بنفس روح بطاقة طلب المندوب.
class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.specialty});

  final String specialty;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.medical_services_outlined,
                color: AppColors.primary,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'تحتاج موعداً عند دكتور؟',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'اكتب اسم المريض ورقم هاتفه الشغال والموعد والموقع — العيادة '
            'تتصل بالمريض على هذا الرقم لا على رقم الطبيب. يوافق '
            'سكرتير العيادة على الحجز ويكتب رقمه الخاص فيصل إشعارك به — '
            'وكشفية الحجز 15,000 د.ع تُقيَّد في محفظة العيادة عند الموافقة '
            'بعد خصم ثابت 500 دينار.',
            style: GoogleFonts.cairo(
              fontSize: 12.5,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              specialty,
              style: GoogleFonts.cairo(
                color: AppColors.primary,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ★ الموعد بطائق صريحة: صفّ أيام (اسم اليوم الكامل فوق والوسم والتاريخ
///   تحته) ثم بطائق ساعات — لا منتقي تاريخ ولا منتقي وقت يدوي.
///
///   ★ الأسبوع من اليوم (2026-11-24): سبع بطائق تبدأ باليوم، كل واحدة
///     باسم يومها الكامل وتاريخه ووسم «اليوم»/«غداً»، وتُلوَّن من توفر
///     يومها كما في القاعدة.
///
///   ★ الأخضر/الأحمر (2026-11-23): الساعة المتاحة خضراء تُضغط، وغير
///     المتاحة (خارج أوقات الطبيب أو محجوزة أو مضت) حمراء لا تُضغط.
///     اليوم لا يُقفل أبداً: قد يبقى فيه حجز متاح أو تظهر كل ساعاته حمراء.
class _ScheduleSection extends StatelessWidget {
  const _ScheduleSection({
    required this.days,
    required this.slotHours,
    required this.selectedDay,
    required this.selectedTime,
    required this.weekdayName,
    required this.dayBadge,
    required this.isSameDay,
    required this.dayOpen,
    required this.weekLoaded,
    required this.closed,
    required this.slotOpen,
    required this.slotLabel,
    required this.loading,
    required this.onDay,
    required this.onTime,
    required this.onClear,
  });

  final List<DateTime> days;
  final List<int> slotHours;
  final DateTime? selectedDay;
  final TimeOfDay? selectedTime;
  final String Function(DateTime) weekdayName;
  final String Function(DateTime) dayBadge;
  final bool Function(DateTime, DateTime) isSameDay;
  final bool Function(DateTime) dayOpen;
  final bool weekLoaded;
  final bool closed;
  final bool Function(int) slotOpen;
  final String Function(int) slotLabel;
  final bool loading;
  final ValueChanged<DateTime> onDay;
  final ValueChanged<int> onTime;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final day = selectedDay;
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
          if (closed) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.event_busy_rounded,
                    color: AppColors.danger,
                    size: 18,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'الطبيب أطفأ استقبال الحجوزات — لا يمكن تثبيت موعد الآن، '
                      'وتعود الساعات فور تشغيله للحجز.',
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        height: 1.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              const Icon(
                Icons.event_note_outlined,
                color: AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'تاريخ الحجز',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (onClear != null)
                IconButton(
                  onPressed: onClear,
                  tooltip: 'مسح الوقت المختار',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  color: AppColors.textHint,
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final d = days[i];
                return _DayCard(
                  weekday: weekdayName(d),
                  badge: dayBadge(d),
                  date: '${d.day}/${d.month}',
                  selected: day != null && isSameDay(day, d),
                  open: !weekLoaded || dayOpen(d),
                  onTap: () => onDay(d),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(
                Icons.schedule_rounded,
                color: AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'وقت الحجز',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (day == null)
            Text(
              'اختر اليوم أولاً ثم اختر الساعة.',
              style: GoogleFonts.cairo(
                fontSize: 12,
                color: AppColors.textHint,
              ),
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final h in slotHours)
                  _TimeCard(
                    label: slotLabel(h),
                    selected: selectedTime?.hour == h &&
                        selectedTime?.minute == 0,
                    open: slotOpen(h),
                    onTap: () => onTime(h),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _LegendDot(color: AppColors.primary, label: 'متاح'),
                const SizedBox(width: 12),
                _LegendDot(color: AppColors.danger, label: 'غير متاح'),
                const Spacer(),
                Flexible(
                  child: Text(
                    loading ? 'جاري قراءة أوقات الطبيب...' : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      color: AppColors.textHint,
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

/// بطاقة يوم: اسم اليوم الكامل، وسم «اليوم»/«غداً» عند أولهما، وتاريخه.
/// خضراء إن بقي فيها وقت متاح، حمراء إن لم يبقَ فيها وقت. لا تُقفل أبداً.
class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.weekday,
    required this.badge,
    required this.date,
    required this.selected,
    required this.open,
    required this.onTap,
  });

  final String weekday;
  final String badge;
  final String date;
  final bool selected;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color border;
    if (!open) {
      bg = AppColors.danger.withValues(alpha: selected ? 0.14 : 0.07);
      fg = AppColors.danger;
      border = AppColors.danger.withValues(alpha: 0.55);
    } else if (selected) {
      bg = AppColors.primary;
      fg = Colors.white;
      border = AppColors.primary;
    } else {
      bg = AppColors.primaryLight;
      fg = AppColors.primaryDark;
      border = AppColors.primary.withValues(alpha: 0.35);
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 16,
              child: badge.isEmpty
                  ? null
                  : Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: selected && open
                            ? Colors.white.withValues(alpha: 0.22)
                            : fg.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        badge,
                        style: GoogleFonts.cairo(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: selected && open ? Colors.white : fg,
                        ),
                      ),
                    ),
            ),
            Text(
              weekday,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: fg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              date,
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة ساعة: «9:00 ص» … «9:00 م» — خضراء متاحة، حمراء لا تُضغط.
class _TimeCard extends StatelessWidget {
  const _TimeCard({
    required this.label,
    required this.selected,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color border;
    if (!open) {
      bg = AppColors.danger.withValues(alpha: 0.08);
      fg = AppColors.danger;
      border = AppColors.danger.withValues(alpha: 0.55);
    } else if (selected) {
      bg = AppColors.primary;
      fg = Colors.white;
      border = AppColors.primary;
    } else {
      bg = AppColors.primaryLight;
      fg = AppColors.primaryDark;
      border = AppColors.primary.withValues(alpha: 0.55);
    }
    return GestureDetector(
      onTap: open ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: GoogleFonts.cairo(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// نقطة دليل لون: أخضر متاح / أحمر غير متاح.
class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: GoogleFonts.cairo(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// كتلة الموقع: تُطابق كتلة «طلب مندوب» حرفياً في الشكل والتصرف، فالاختلاف
/// بينهما كان يربك المندوب («لماذا الموقع هنا لا يُحدَّث؟»).
class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.locating,
    required this.address,
    required this.pinned,
    required this.onRefresh,
    required this.onMap,
  });

  final bool locating;
  final String address;
  final bool pinned;
  final VoidCallback onRefresh;
  final VoidCallback onMap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                locating
                    ? Icons.location_searching_rounded
                    : Icons.location_on_rounded,
                color: AppColors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pinned
                          ? 'الموقع المثبّت على الخريطة'
                          : (locating ? 'جاري تحديد الموقع...' : 'موقع الحجز'),
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: locating ? null : onRefresh,
                child: Text(
                  'تحديث',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: locating ? null : onMap,
              icon: const Icon(Icons.pin_drop_rounded, size: 18),
              label: Text(
                'حدد الموقع على الخريطة',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                visualDensity: VisualDensity.compact,
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.45),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
