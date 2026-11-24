import 'supabase_service.dart';

/// ★ خدمة «حجز موعد دكتور/ة» — كل شيء فيها يمرّ من داخل القاعدة.
///
///   الباب الوحيد للكتابة هو `book_doctor_appointment` في
///   `SQL_DOCTOR_APPOINTMENTS.sql`: الجدول **مقفول** بـ`revoke all` من
///   anon وauthenticated، فلا يستطيع من يملك مفتاح التطبيق أن يكتب صفّاً
///   مباشرة أو يقرأ حجوزات غيره — الرقم يُؤخذ من توكن الجلسة
///   (`app.current_phone()`) لا مما يرسله الجهاز.
///
///   كل دوال هنا **لا تخترع نجاحاً**: إن ردّت القاعدة برفض يُرجَع نصّ
///   الرفض كما هو، وإن سقطت الشبكة تُقال كلمة «تعذّر» ولا يُعرض رقم
///   حجز وهمي.
class DoctorService {
  DoctorService._();

  static final DoctorService instance = DoctorService._();

  /// أنواع التخصص — القائمة التي حدّدها الأدمن حرفياً (10-31)، وبترتيبها:
  /// باطنية · كسور · جراح · قلبية · اذن وحنجرة · اسنان · عيون · اعصاب ·
  /// غير ذلك.
  ///
  /// مصدر واحد: القائمة المنسدلة عند الزبون والبطاقة عند المندوب
  /// تقرآن منها، فلا يُكتب تخصص في شاشة بشكل وغيرها بشكل آخر.
  static const List<String> specialties = <String>[
    'باطنية',
    'كسور',
    'جراح',
    'قلبية',
    'اذن وحنجرة',
    'اسنان',
    'عيون',
    'اعصاب',
    'غير ذلك',
  ];

  /// تثبيت حجز — يعيد ما قاله الخادم وحده.
  Future<DoctorBookingResult> book({
    required String specialty,
    required String doctorName,
    required String patientName,
    required String contactPhone,
    required DateTime appointmentAt,
    String? address,
    double? latitude,
    double? longitude,
  }) async {
    // ★ حارس الخدمة: لا حجز بلا جلسة دخول، حتى لو وصل النداء من مسار
    //   لا يمرّ ببوابة الشاشة.
    if (!SupabaseService.instance.hasSession) {
      return DoctorBookingResult.failed('سجّل الدخول أولاً لتثبيت الحجز');
    }
    final res = await SupabaseService.instance
        .rpcCall('book_doctor_appointment', <String, dynamic>{
          'p_specialty': specialty.trim(),
          'p_doctor_name': doctorName.trim(),
          'p_patient_name': patientName.trim(),
          'p_contact_phone': contactPhone.trim(),
          'p_appointment_at': appointmentAt.toUtc().toIso8601String(),
          'p_address': address,
          'p_latitude': latitude,
          'p_longitude': longitude,
        }, timeoutSeconds: 20);
    if (res is! Map) {
      final why = (SupabaseService.instance.lastRpcError ?? '').trim();
      return DoctorBookingResult.failed(
        why.isEmpty ? 'تعذّر تثبيت الحجز — تحقق من الاتصال' : why,
      );
    }
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorBookingResult.failed(
        _text(map['error']) ?? 'تعذّر تثبيت الحجز',
      );
    }
    return DoctorBookingResult.success(
      id: _text(map['id']) ?? '',
      serial: _text(map['serial']) ?? '',
      pendingApproval: map['pending_approval'] == true,
      status: _text(map['status']) ?? '',
      examFee: _int(map['exam_fee']),
    );
  }

  /// ★ حجوزات صاحب الحساب نفسه — بكل حالاتها (منتظر/مؤكَّد/مرفوض).
  ///
  ///   العزل في القاعدة على `app.current_phone()`، والجهاز لا يرسل رقماً.
  Future<List<DoctorAppointment>> mine({int limit = 40}) async =>
      _rows('my_doctor_appointments', <String, dynamic>{'p_limit': limit});

  // ==================================================================
  //  دورة موافقة العيادة (السكرتير/الطبيب) + محفظة الطبيب
  // ==================================================================

  /// ★ حجوزات العيادة كما يراها السكرتير أو الطبيب: المنتظرة أولاً ثم
  ///   السجل. العزل في القاعدة على رقم الجلسة (`doctors.secretary_phone`
  ///   أو `doctors.phone`)، فلا وسيط يرسل رقماً.
  Future<List<DoctorAppointment>> forSecretary({int limit = 80}) =>
      _rows('doctor_appointments_for_secretary', <String, dynamic>{
        'p_limit': limit,
      });

  /// ★ موافقة السكرتير برقم يكتبه: الرقم إجباري في القاعدة، ويُكتب مرة
  ///   واحدة، ويصل المريض في إشعار. ترجع الرقم والكشفية والاستقطاع الثابت.
  Future<DoctorActionResult> approve(String id, int serial) async {
    if (id.isEmpty) return DoctorActionResult.failed('معرّف الحجز مفقود');
    if (serial <= 0) {
      return DoctorActionResult.failed('اكتب رقم حجز صحيحاً (رقم أكبر من صفر)');
    }
    return _actionResult('doctor_appointment_approve', id, <String, dynamic>{
      'p_serial': serial,
    });
  }

  /// رفض السكرتير: بلا كشفية، ويُشعَر المريض من القاعدة.
  Future<DoctorActionResult> reject(String id) =>
      _actionResult('doctor_appointment_reject', id);

  /// سياق الحساب: هل هو طبيب؟ سكرتير؟ وكم حجزاً ينتظر الموافقة؟
  ///
  /// يُستدعى عند فتح «حسابي» وحده؛ لا استطلاع دوري. إن لم يكن الملف
  /// مثبّتاً بعد على الخادم يعود `null` وتُخفى البوابات بلا خطأ.
  Future<DoctorRoleContext?> myRoles() async {
    final res = await SupabaseService.instance.rpcCall('my_doctor_roles', {});
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;
    final doctors = <DoctorRoleEntry>[];
    final raw = map['doctors'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        final m = Map<String, dynamic>.from(r);
        doctors.add(DoctorRoleEntry(
          id: _text(m['id']) ?? '',
          name: _text(m['name']) ?? '',
          imageUrl: _text(m['image_url']) ?? '',
          isDoctor: m['is_doctor'] == true,
          isSecretary: m['is_secretary'] == true,
        ));
      }
    }
    final isAdmin = map['is_admin'] == true;
    if (doctors.isEmpty && !isAdmin) return null;
    return DoctorRoleContext(
      doctors: doctors,
      pending: _int(map['pending']),
      isAdmin: isAdmin,
    );
  }

  /// ★ محفظة العيادات المرتبطة بالحساب (طبيب أو سكرتير): لكل عيادة
  ///   كشفياتها كاملة، استقطاع ثابت 500 لكل حجز، الصافي، المصروف
  ///   بالتصفير، والرصيد (= الصافي − المصروف) محسوباً في القاعدة.
  Future<DoctorWallet?> wallet() async {
    final res = await SupabaseService.instance.rpcCall('my_doctor_wallet', {});
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;
    final wallets = <ClinicWallet>[];
    final raw = map['wallets'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        final m = Map<String, dynamic>.from(r);
        final entries = <DoctorWalletEntry>[];
        final rawEntries = m['entries'];
        if (rawEntries is List) {
          for (final e in rawEntries.whereType<Map>()) {
            final em = Map<String, dynamic>.from(e);
            entries.add(DoctorWalletEntry(
              amount: _int(em['amount']),
              grossAmount: _int(em['gross_amount']),
              commission: _int(em['commission']),
              kind: _text(em['kind']) ?? '',
              note: _text(em['note']) ?? '',
              createdAt: DateTime.tryParse(
                em['created_at']?.toString() ?? '',
              )?.toLocal(),
            ));
          }
        }
        wallets.add(ClinicWallet(
          doctorId: _text(m['doctor_id']) ?? '',
          doctorName: _text(m['doctor_name']) ?? '',
          isDoctor: m['is_doctor'] == true,
          isSecretary: m['is_secretary'] == true,
          gross: _int(m['gross']),
          commission: _int(m['commission']),
          net: _int(m['net']),
          paid: _int(m['paid']),
          balance: _int(m['balance']),
          entries: entries,
          resetAt: DateTime.tryParse(
            m['reset_at']?.toString() ?? '',
          )?.toLocal(),
        ));
      }
    }
    return DoctorWallet(
      wallets: wallets,
      gross: _int(map['gross']),
      commission: _int(map['commission']),
      net: _int(map['net']),
      paid: _int(map['paid']),
      balance: _int(map['balance']),
      commissionPercent: _int(map['commission_percent']),
      resetAt: DateTime.tryParse(
        map['reset_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }

  // ==================================================================
  //  ★ أوقات الحجز الأسبوعية (2026-11-23)
  // ==================================================================

  /// ★ عيادات هذا الحساب (طبيب/سكرتير) وحالة زر الحجز لكل عيادة.
  /// لا جلسة ⇒ قائمة فارغة (لا خطأ يكسر الشاشة).
  Future<List<DoctorAvailabilityEntry>> myAvailability() async {
    final res = await SupabaseService.instance
        .rpcCall('doctor_my_availability', {});
    if (res is! Map) return const [];
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return const [];
    final list = <DoctorAvailabilityEntry>[];
    final raw = map['doctors'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        final m = Map<String, dynamic>.from(r);
        list.add(DoctorAvailabilityEntry(
          id: _text(m['id']) ?? '',
          name: _text(m['name']) ?? '',
          isDoctor: m['is_doctor'] == true,
          isSecretary: m['is_secretary'] == true,
          bookingOpen: m['booking_open'] != false,
        ));
      }
    }
    return list;
  }

  /// ★ تشغيل/إطفاء الحجز لعيادة واحدة. الإطفاء يمنع أي حجز من أي زبون
  /// مهما كان السبب (والمشغّل في القاعدة يرفض حتى نسخ التطبيق القديمة).
  Future<DoctorBookingSwitchResult> setBookingOpen(
    String doctorId,
    bool open,
  ) async {
    if (doctorId.isEmpty) {
      return const DoctorBookingSwitchResult.failed('معرّف الطبيب مفقود');
    }
    final res = await SupabaseService.instance.rpcCall(
      'doctor_set_booking_open',
      <String, dynamic>{
        'p_doctor_id': doctorId,
        'p_open': open,
      },
      timeoutSeconds: 15,
    );
    if (res is! Map) {
      final why = (SupabaseService.instance.lastRpcError ?? '').trim();
      return DoctorBookingSwitchResult.failed(
        why.isEmpty ? 'تعذّر تغيير حالة الحجز — تحقق من الاتصال' : why,
      );
    }
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorBookingSwitchResult.failed(
        _text(map['error']) ?? 'تعذّر تغيير حالة الحجز',
      );
    }
    return DoctorBookingSwitchResult.ok(map['booking_open'] != false);
  }

  /// توفر ساعات يوم معيّن لطبيب بالاسم: أُوقاته الأسبوعية + المحجوز.
  /// `null` = تعذّرت القراءة (الدالة غير مثبّتة أو بلا شبكة) — الشاشة
  /// عندها تفتح الساعات المستقبلية كما كانت، ولا تُغلق الحجز كله.
  Future<DoctorDayAvailability?> dayAvailability(
    String doctorName,
    DateTime day,
  ) async {
    final res = await SupabaseService.instance.rpcCall(
      'doctor_slot_availability',
      <String, dynamic>{
        'p_doctor_name': doctorName.trim(),
        'p_date': dateKey(day),
      },
      timeoutSeconds: 12,
    );
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;

    return DoctorDayAvailability(
      doctorFound: map['doctor_found'] == true,
      bookingOpen: map['booking_open'] != false,
      hasTemplate: map['has_template'] == true,
      openHours: _hours(map['open_hours']),
      bookedHours: _hours(map['booked_hours']),
    );
  }

  /// ★ أسبوع الحجز من `from` (7 أيام) بنداء واحد — بدل سبعة نداءات.
  /// `null` = تعذّرت القراءة (الدالة غير مثبّتة أو بلا شبكة).
  Future<DoctorWeekAvailability?> weekAvailability(
    String doctorName,
    DateTime from,
  ) async {
    final res = await SupabaseService.instance.rpcCall(
      'doctor_week_availability',
      <String, dynamic>{
        'p_doctor_name': doctorName.trim(),
        'p_from': dateKey(from),
      },
      timeoutSeconds: 12,
    );
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;

    final found = map['doctor_found'] == true;
    final open = map['booking_open'] != false;
    final hasTemplate = map['has_template'] == true;
    final days = <String, DoctorDayAvailability>{};
    final raw = map['days'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        final m = Map<String, dynamic>.from(r);
        final date = _text(m['date']) ?? '';
        if (date.isEmpty) continue;
        days[date] = DoctorDayAvailability(
          doctorFound: found,
          bookingOpen: open,
          hasTemplate: hasTemplate,
          openHours: _hours(m['open_hours']),
          bookedHours: _hours(m['booked_hours']),
        );
      }
    }
    return DoctorWeekAvailability(
      doctorFound: found,
      bookingOpen: open,
      hasTemplate: hasTemplate,
      days: days,
    );
  }

  /// مفتاح يوم `YYYY-MM-DD` كما تعيده دوال القاعدة.
  static String dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static Set<int> _hours(Object? raw) {
    final set = <int>{};
    if (raw is List) {
      for (final v in raw) {
        final h = _int(v);
        if (h >= 0 && h <= 23) set.add(h);
      }
    }
    return set;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  Future<List<DoctorAppointment>> _rows(
    String fn,
    Map<String, dynamic> args,
  ) async {
    final res = await SupabaseService.instance.rpcCall(fn, args);
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((e) => DoctorAppointment.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<DoctorActionResult> _actionResult(
    String fn,
    String id, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    if (id.isEmpty) return DoctorActionResult.failed('معرّف الحجز مفقود');
    final res = await SupabaseService.instance.rpcCall(fn, <String, dynamic>{
      'p_id': id,
      ...extra,
    });
    if (res is! Map) {
      final why = (SupabaseService.instance.lastRpcError ?? '').trim();
      return DoctorActionResult.failed(
        why.isEmpty ? 'تعذّر التنفيذ — تحقق من الاتصال' : why,
      );
    }
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorActionResult.failed(_text(map['error']) ?? 'تعذّر التنفيذ');
    }
    return DoctorActionResult.success(
      serial: _text(map['serial']) ?? '',
      examFee: _int(map['exam_fee']),
      commission: _int(map['commission']),
      netAmount: _int(map['net_amount']),
      already: map['already'] == true,
    );
  }

  static String? _text(Object? v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty || s == 'null' ? null : s;
  }

  static int _int(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }
}

/// صفّ حجز كما خرج من `doctor_appointments`.
class DoctorAppointment {
  const DoctorAppointment({
    required this.id,
    required this.serial,
    required this.specialty,
    required this.doctorName,
    required this.patientName,
    required this.contactPhone,
    required this.address,
    required this.status,
    required this.bookedName,
    required this.driverName,
    this.doctorId,
    this.examFee = 15000,
    this.appointmentAt,
    this.latitude,
    this.longitude,
    this.createdAt,
    this.approvedAt,
    this.rejectedAt,
    this.acceptedAt,
    this.doneAt,
  });

  factory DoctorAppointment.fromJson(Map<String, dynamic> json) {
    return DoctorAppointment(
      id: DoctorService._text(json['id']) ?? '',
      serial: DoctorService._text(json['serial_number']) ?? '',
      specialty: DoctorService._text(json['specialty']) ?? '',
      doctorName: DoctorService._text(json['doctor_name']) ?? '',
      patientName: DoctorService._text(json['patient_name']) ?? '',
      contactPhone: DoctorService._text(json['contact_phone']) ?? '',
      address: DoctorService._text(json['address']) ?? '',
      status: DoctorService._text(json['status']) ?? 'pending',
      bookedName:
          DoctorService._text(json['booked_name']) ??
          DoctorService._text(json['booked_phone']) ??
          '',
      driverName:
          DoctorService._text(json['driver_name']) ??
          DoctorService._text(json['driver_phone']) ??
          '',
      doctorId: DoctorService._text(json['doctor_id']),
      examFee:
          int.tryParse('${json['exam_fee'] ?? ''}') ??
          15000,
      appointmentAt: _date(json['appointment_at']),
      latitude: _num(json['latitude']),
      longitude: _num(json['longitude']),
      createdAt: _date(json['created_at']),
      approvedAt: _date(json['approved_at']),
      rejectedAt: _date(json['rejected_at']),
      acceptedAt: _date(json['accepted_at']),
      doneAt: _date(json['done_at']),
    );
  }

  final String id;

  /// الرقم التسلسلي **للسلسلة الخاصة بالحجوزات** (`doctor_serial_seq`):
  /// لا يأكل رقم طلب عادي ولا رقم «طلب مندوب» — كل نوع يبدأ من #1 وحده.
  final String serial;
  final String specialty;
  final String doctorName;
  final String patientName;
  final String contactPhone;
  final String address;
  final String status;
  final String bookedName;
  final String driverName;

  /// الطبيب المربوط من الدليل — هو مفتاح سكرتير العيادة ومحفظتها.
  final String? doctorId;

  /// كشفية الحجز (15,000) — تُقيَّد في محفظة الطبيب عند الموافقة فقط.
  final int examFee;

  final DateTime? appointmentAt;
  final double? latitude;
  final double? longitude;
  final DateTime? createdAt;

  /// لحظة موافقة العيادة — قبلها الحجز لا يصل للمندوبين.
  final DateTime? approvedAt;

  /// لحظة رفض العيادة — بلا كشفية ويُشعَر المريض.
  final DateTime? rejectedAt;

  /// لحظة أخذ المندوب للحجز — خطوة المراقبة الثانية، و`null` ما لم يأخذه أحد.
  final DateTime? acceptedAt;

  /// لحظة «تمّ الحجز» — يتوقف عندها عدّاد «كم مضى»، كما في الطلب المُسلَّم.
  final DateTime? doneAt;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isAccepted => status == 'accepted';
  bool get isDone => status == 'done';
  bool get isCancelled => status == 'cancelled';
  bool get isRejected => status == 'rejected';

  /// الحالة بكلمة واحدة تُقرأ في الشارة والسطر معاً — من هذه الدالة وحدها
  /// حتى لا تقول البطاقة «جديد» والشاشة «بانتظار مندوب» للحجز نفسه.
  String get statusLabel => DoctorStatus.label(status);

  /// ★ سطر «كم مضى» بالحقل الذي يفهمه `OrderElapsed`: التسليم عند المندوب
  ///   هو «تمّ الحجز» — فينطفئ العدّاد عند `done_at` بدل أن يقول «منذ
  ///   ٣ أيام» لحجز انتهى.
  Map<String, dynamic> get elapsedFields => <String, dynamic>{
    'created_at': createdAt?.toUtc().toIso8601String(),
    'delivered_at': doneAt?.toUtc().toIso8601String(),
  };

  /// «#7» — وبلا رقم في الصف لا تُختلق شارة: الفراغ يقول «لم يُرقَّم».
  String get serialLabel => switch (serial) {
    '' => '',
    _ => serial.startsWith('#') ? serial : '#$serial',
  };

  /// الموعد بصيغة الشاشة: `2026-11-02 · 10:30 ص`.
  String get whenLabel {
    final at = appointmentAt?.toLocal();
    if (at == null) return 'بلا موعد';
    final h = at.hour;
    final period = h < 12 ? 'ص' : 'م';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '${at.year}-${_two(at.month)}-${_two(at.day)}'
        ' · ${_two(h12)}:${_two(at.minute)} $period';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static DateTime? _date(Object? v) {
    final s = v?.toString().trim() ?? '';
    if (s.isEmpty || s == 'null') return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}');
  }
}

/// ★ كلمة الحالة الوحيدة — البطاقة والشيت وشاشة «حجوزاتي» تقرأ منها.
///
///   لا مندوب في حجوزات الأطباء: الموافقة برقم هي نهاية الدورة، فكل حالة
///   بعدها تُقرأ «تمّ الحجز». `accepted`/`done` تبقى لحجوزات قديمة فقط.
class DoctorStatus {
  const DoctorStatus._();

  static String label(String status) => switch (status) {
    'pending' => 'بانتظار الموافقة',
    'approved' => 'تمّت الموافقة',
    'accepted' => 'تمّت الموافقة',
    'done' => 'تمّ الحجز',
    'cancelled' => 'أُلغي',
    'rejected' => 'رفضت العيادة',
    _ => 'بانتظار الموافقة',
  };
}

/// نتيجة «تثبيت الحجز»: رقم الخادم أو رفضه بنصّه.
class DoctorBookingResult {
  const DoctorBookingResult._({
    required this.ok,
    required this.id,
    required this.serial,
    required this.error,
    this.pendingApproval = false,
    this.status = '',
    this.examFee = 15000,
  });

  factory DoctorBookingResult.success({
    required String id,
    required String serial,
    bool pendingApproval = false,
    String status = '',
    int examFee = 15000,
  }) => DoctorBookingResult._(
    ok: true,
    id: id,
    serial: serial,
    error: '',
    pendingApproval: pendingApproval,
    status: status,
    examFee: examFee,
  );

  factory DoctorBookingResult.failed(String error) =>
      DoctorBookingResult._(ok: false, id: '', serial: '', error: error);

  final bool ok;
  final String id;
  final String serial;
  final String error;

  /// طبيب له سكرتير ⇒ الحجز ينتظر الموافقة ولا يصل للمندوبين بعد.
  final bool pendingApproval;

  /// حالة الصف كما كتبها الخادم (`pending` / `approved`).
  final String status;

  /// الكشفية المقيدة في محفظة الطبيب عند الموافقة.
  final int examFee;
}

/// نتيجة إجراء السكرتير (موافقة/رفض): النجاح برقم الحجز أو نصّ الرفض.
class DoctorActionResult {
  const DoctorActionResult._({
    required this.ok,
    required this.serial,
    required this.examFee,
    required this.commission,
    required this.netAmount,
    required this.error,
    required this.already,
  });

  factory DoctorActionResult.success({
    required String serial,
    required int examFee,
    int commission = 0,
    int netAmount = 0,
    required bool already,
  }) => DoctorActionResult._(
    ok: true,
    serial: serial,
    examFee: examFee,
    commission: commission,
    netAmount: netAmount,
    error: '',
    already: already,
  );

  factory DoctorActionResult.failed(String error) => DoctorActionResult._(
    ok: false,
    serial: '',
    examFee: 0,
    commission: 0,
    netAmount: 0,
    error: error,
    already: false,
  );

  final bool ok;
  final String serial;

  /// الكشفية كاملة (15,000).
  final int examFee;

  /// استقطاع ثابت 500 دينار (أو الكشفية إن كانت أقل).
  final int commission;

  /// الصافي المقيد في محفظة العيادة (14,500).
  final int netAmount;

  final String error;

  /// الإجراء كان منجزاً من قبل: لا كشفية جديدة ولا تغيير.
  final bool already;
}

/// طبيب يرتبط به الحساب: طبيب نفسه أو سكرتير عيادته.
class DoctorRoleEntry {
  const DoctorRoleEntry({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.isDoctor,
    required this.isSecretary,
  });

  final String id;
  final String name;
  final String imageUrl;
  final bool isDoctor;
  final bool isSecretary;
}

/// سياق «حسابي»: يحدّد بوابات العيادة التي تظهر للحساب.
class DoctorRoleContext {
  const DoctorRoleContext({
    required this.doctors,
    required this.pending,
    this.isAdmin = false,
  });

  final List<DoctorRoleEntry> doctors;

  /// حجوزات تنتظر موافقة هذا الحساب الآن (للأدمن: كل الحجوزات المنتظرة).
  final int pending;

  /// الأدمن يشرف على كل العيادات ولو لم يكن طبيباً.
  final bool isAdmin;

  bool get isDoctor => doctors.any((d) => d.isDoctor);
  bool get isSecretary => doctors.any((d) => d.isSecretary);
  bool get hasClinic => isAdmin || doctors.isNotEmpty;
}

/// ★ محفظة الحساب كاملة: عيادة واحدة أو أكثر، مع الحصيلة العامة.
class DoctorWallet {
  const DoctorWallet({
    required this.wallets,
    required this.gross,
    required this.commission,
    required this.net,
    required this.paid,
    required this.balance,
    required this.commissionPercent,
    this.resetAt,
  });

  final List<ClinicWallet> wallets;

  /// مجموع الكشفيات كاملة، ثم الاستقطاعات الثابتة، ثم الصافي، ثم المصروف.
  /// كلها **منذ آخر تصفير**؛ وقبل أول تصفير تكون من بداية الدفتر.
  final int gross;
  final int commission;
  final int net;
  final int paid;

  /// المستحق الآن = الصافي − المصروف (التصفير يجعلها صفراً).
  final int balance;

  /// نسبة القاعدة (0 في العيادات: الاستقطاع ثابت 500 دينار لا نسبة).
  final int commissionPercent;

  /// لحظة آخر تصفير (null = لم تُصفَّر العيادة بعد).
  final DateTime? resetAt;
}

/// محفظة عيادة واحدة لطبيب أو سكرتير.
class ClinicWallet {
  const ClinicWallet({
    required this.doctorId,
    required this.doctorName,
    required this.isDoctor,
    required this.isSecretary,
    required this.gross,
    required this.commission,
    required this.net,
    required this.paid,
    required this.balance,
    required this.entries,
    this.resetAt,
  });

  final String doctorId;
  final String doctorName;
  final bool isDoctor;
  final bool isSecretary;
  final int gross;
  final int commission;
  final int net;
  final int paid;
  final int balance;
  final List<DoctorWalletEntry> entries;

  /// لحظة آخر تصفير لهذه العيادة (null = لم تُصفَّر بعد).
  final DateTime? resetAt;
}

class DoctorWalletEntry {
  const DoctorWalletEntry({
    required this.amount,
    required this.kind,
    required this.note,
    required this.createdAt,
    this.grossAmount = 0,
    this.commission = 0,
  });

  /// الصافي الذي دخل المحفظة (بعد الاستقطاع).
  final int amount;

  /// الكشفية كاملة والاستقطاع الثابت — للقراءة الشفافة في سطر القيد.
  final int grossAmount;
  final int commission;

  final String kind;
  final String note;
  final DateTime? createdAt;
}

/// ★ عيادة يديرها هذا الحساب (طبيب أو سكرتير) وحالة زر الحجز.
class DoctorAvailabilityEntry {
  const DoctorAvailabilityEntry({
    required this.id,
    required this.name,
    required this.isDoctor,
    required this.isSecretary,
    required this.bookingOpen,
  });

  final String id;
  final String name;
  final bool isDoctor;
  final bool isSecretary;

  /// مفتوح ⇒ الحجز متاح كل أيام الأسبوع (عدا الساعة المحجوزة مسبقاً).
  final bool bookingOpen;
}

/// نتيجة تغيير زر الحجز: الحالة النهائية كما أكّدتها القاعدة أو نص الرفض.
class DoctorBookingSwitchResult {
  const DoctorBookingSwitchResult.ok(this.open)
      : ok = true,
        error = '';

  const DoctorBookingSwitchResult.failed(this.error)
      : ok = false,
        open = false;

  final bool ok;
  final bool open;
  final String error;
}

/// توفر يوم واحد كما تقرأه شاشة الحجز.
class DoctorDayAvailability {
  const DoctorDayAvailability({
    required this.doctorFound,
    required this.bookingOpen,
    required this.hasTemplate,
    required this.openHours,
    required this.bookedHours,
  });

  /// اسم الطبيب مطابق لسجل في الدليل.
  final bool doctorFound;

  /// زر الحجز لدى الطبيب (إطفاؤه يمنع الحجز مهما كان السبب).
  final bool bookingOpen;

  /// في النسخة الجديدة = «الحجز مغلق» (توافق النسخ القديمة).
  final bool hasTemplate;

  /// ساعات هذا اليوم الأسبوعي في جدول الطبيب.
  final Set<int> openHours;

  /// ساعات فيها حجز قائم (بانتظار/موافَق عليه).
  final Set<int> bookedHours;

  bool isOpen(int hour) =>
      bookingOpen &&
      !bookedHours.contains(hour) &&
      (!hasTemplate || openHours.contains(hour));
}

/// ★ أسبوع الحجز كاملاً (7 أيام من تاريخ البداية) بنداء واحد —
///   من `doctor_week_availability`. صفّ أيام شاشة الحجز يعرض اسم كل
///   يوم وتاريخه وحالته (أخضر فيه ساعة متاحة، أحمر مغلق/ممتلئ).
class DoctorWeekAvailability {
  const DoctorWeekAvailability({
    required this.doctorFound,
    required this.bookingOpen,
    required this.hasTemplate,
    required this.days,
  });

  final bool doctorFound;
  final bool bookingOpen;
  final bool hasTemplate;

  /// مفتاحها `YYYY-MM-DD`.
  final Map<String, DoctorDayAvailability> days;

  DoctorDayAvailability? on(DateTime d) => days[DoctorService.dateKey(d)];
}

