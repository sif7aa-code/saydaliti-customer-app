import '../core/utils/deduction_label.dart';
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

  /// ★ أصغر رقم غير مستعمل اليوم في هذه العيادة (من القاعدة) — يفتح
  ///   به حوار الموافقة مُعبّأً، فلا يُكتب رقم مستعمل فيُرفض.
  ///   صفر = لا اقتراح (لا جلسة أو لا صلاحية أو الدالة غير مثبتة).
  Future<int> nextSerial(String doctorId) async {
    if (doctorId.isEmpty) return 0;
    final res = await SupabaseService.instance.rpcCall(
      'doctor_next_serial',
      <String, dynamic>{'p_doctor_id': doctorId},
    );
    if (res is num) return res.toInt();
    return int.tryParse('${res ?? ''}') ?? 0;
  }

  // ==================================================================
  //  الدوْر والزيارة (2026-11-26) — SQL_DOCTOR_QUEUE_VISITS.sql
  // ==================================================================

  /// قائمة انتظار العيادة/الطبيب اليوم (وللأدمن: كل العيادات).
  Future<DoctorQueue> queue() async {
    final res = await SupabaseService.instance.rpcCall('doctor_queue', {});
    if (res is! Map) return const DoctorQueue(error: 'تعذّر جلب قائمة الانتظار');
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorQueue(
        error: _text(map['error']) ?? 'تعذّر جلب قائمة الانتظار',
      );
    }
    final clinics = <DoctorQueueClinic>[];
    final raw = map['clinics'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        clinics.add(
          DoctorQueueClinic.fromJson(Map<String, dynamic>.from(r)),
        );
      }
    }
    return DoctorQueue(clinics: clinics, isAdmin: map['is_admin'] == true);
  }

  /// ★ إحصائيات اليوم للعيادة: المراجعون الآن (في الكشف + منتظر)،
  ///   والمكتمل اليوم، والمرفوض اليوم — كل حجز يُعدّ مرة واحدة حسب
  ///   حالته الحالية. اليوم بمنتصف ليل بغداد كما في `doctor_queue`.
  Future<DoctorDayStats> dayStats() async {
    final res = await SupabaseService.instance.rpcCall(
      'doctor_clinic_day_stats',
      {},
    );
    if (res is! Map) {
      return const DoctorDayStats(error: 'تعذّر جلب إحصائيات اليوم');
    }
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorDayStats(
        error: _text(map['error']) ?? 'تعذّر جلب إحصائيات اليوم',
      );
    }
    final totals = map['totals'] is Map
        ? Map<String, dynamic>.from(map['totals'] as Map)
        : const <String, dynamic>{};
    final clinics = <DoctorDayStatsClinic>[];
    final raw = map['clinics'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        final m = Map<String, dynamic>.from(r);
        clinics.add(DoctorDayStatsClinic(
          doctorId: _text(m['doctor_id']) ?? '',
          doctorName: _text(m['doctor_name']) ?? '',
          waiting: _int(m['waiting']),
          called: _int(m['called']),
          done: _int(m['done']),
          rejected: _int(m['rejected']),
        ));
      }
    }
    return DoctorDayStats(
      clinics: clinics,
      waiting: _int(totals['waiting']),
      called: _int(totals['called']),
      done: _int(totals['done']),
      rejected: _int(totals['rejected']),
    );
  }

  /// «استدعاء المريض» — يمكن استدعاء أكثر من مريض؛ كل واحد يصله إشعار
  /// «حان دورك» مرة واحدة.
  Future<DoctorActionResult> callPatient(String id) =>
      _actionResult('doctor_queue_call', id);

  /// «المريض التالي» — يستدعي أول منتظر في العيادة (أصغر رقم).
  Future<DoctorActionResult> callNext(String doctorId) async {
    if (doctorId.isEmpty) return DoctorActionResult.failed('معرّف العيادة مفقود');
    final res = await SupabaseService.instance.rpcCall(
      'doctor_queue_next',
      <String, dynamic>{'p_doctor_id': doctorId},
    );
    return _parseAction(res);
  }

  /// «تأكيد انتهاء المعاينة» — هنا وحدها تُقيَّد الكشفية. القاعدة تمنع
  /// الاحتساب مرتين (قفل الصف + قيد فريد لكل حجز)، والرد يقول `credited`.
  Future<DoctorActionResult> completeVisit(String id) =>
      _actionResult('doctor_queue_complete', id);

  /// ★ إلغاء انتظار مريض وحذف حجزه نهائياً (وقت الانتظار فقط).
  ///   القاعدة ترفض المكتمل والمرفوض، وتُشعِر المريض بالإلغاء مرة واحدة.
  Future<DoctorActionResult> deleteAppointment(String id) =>
      _actionResult('doctor_appointment_delete', id);

  /// دور الزبون النشط لبطاقة الرئيسية: رقم كبير + اسم الطبيب + المتبقي.
  /// `null` = لا دور نشط (لم يوافق أحد بعد، أو انتهت المعاينة).
  Future<ActiveDoctorTicket?> activeTicket() async {
    final res = await SupabaseService.instance.rpcCall(
      'my_active_doctor_ticket',
      {},
    );
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;
    final ticket = map['ticket'];
    if (ticket is! Map) return null;
    return ActiveDoctorTicket.fromJson(Map<String, dynamic>.from(ticket));
  }

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

  /// ★ سكرتير عيادة واحدة: الرقم واسم صاحبه إن كان قد سجّل حسابه.
  ///   القاعدة تسمح بها لطبيب العيادة نفسه أو الأدمن فقط؛ أي حساب آخر
  ///   يعود `null` فلا تظهر له بيانات.
  Future<DoctorSecretaryInfo?> secretaryInfo(String doctorId) async {
    if (doctorId.isEmpty) return null;
    final res = await SupabaseService.instance.rpcCall(
      'doctor_secretary_info',
      <String, dynamic>{'p_doctor_id': doctorId},
      timeoutSeconds: 15,
    );
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;
    return DoctorSecretaryInfo(
      doctorId: _text(map['doctor_id']) ?? doctorId,
      doctorName: _text(map['doctor_name']) ?? '',
      phone: _text(map['secretary_phone']) ?? '',
      name: _text(map['secretary_name']) ?? '',
    );
  }

  /// ★ هل رقم السكرتير مسجّل في التطبيق؟ (قبل الحفظ)
  ///   ترجع الاسم إن كان مسجّلاً، و`registered=false` إن لم يكن.
  ///   أي خطأ/انقطاع يعود `null` — والقاعدة تبقى هي الحَكَم عند الحفظ.
  Future<DoctorSecretaryCheck?> secretaryCheck(
    String doctorId,
    String phone,
  ) async {
    if (doctorId.isEmpty) return null;
    final res = await SupabaseService.instance.rpcCall(
      'doctor_secretary_check',
      <String, dynamic>{
        'p_doctor_id': doctorId,
        'p_phone': phone,
      },
      timeoutSeconds: 15,
    );
    if (res is! Map) return null;
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) return null;
    return DoctorSecretaryCheck(
      registered: map['registered'] == true,
      name: _text(map['name']) ?? '',
    );
  }

  /// ★ ضبط أو تغيير أو حذف سكرتير العيادة.
  ///   `phone` فارغ ⇒ يُحذف السكرتير (فيفقد الوصول فوراً في القاعدة).
  ///   التحقق من الرقم وتطبيعه يجري في القاعدة أيضاً لا هنا وحده.
  Future<DoctorSecretaryResult> setSecretary(    String doctorId,
    String phone,
  ) async {
    if (doctorId.isEmpty) {
      return DoctorSecretaryResult.failed('معرّف العيادة مفقود');
    }
    final res = await SupabaseService.instance.rpcCall(
      'doctor_secretary_set',
      <String, dynamic>{
        'p_doctor_id': doctorId,
        'p_phone': phone,
      },
      timeoutSeconds: 15,
    );
    if (res is! Map) {
      final why = (SupabaseService.instance.lastRpcError ?? '').trim();
      return DoctorSecretaryResult.failed(
        why.isEmpty ? 'تعذّر الحفظ — تحقق من الاتصال' : why,
      );
    }
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorSecretaryResult.failed(
        _text(map['error']) ?? 'تعذّر حفظ السكرتير',
      );
    }
    return DoctorSecretaryResult.ok(
      phone: _text(map['secretary_phone']) ?? '',
      message: _text(map['message']) ?? 'حُفظ السكرتير',
    );
  }

  /// ★ محفظة العيادات المرتبطة بالحساب (طبيب أو سكرتير): لكل عيادة
  ///   كشفياتها كاملة، الاستقطاع (ثابت أو نسبة — يحدده الأدمن)، الصافي،
  ///   المصروف بالتصفير، والرصيد (= الصافي − المصروف) محسوباً في القاعدة.
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
          deductionMethod: deductionMethodOf(m['commission_method']),
          deductionValue: _dbl(m['commission_value']),
          deductionIsDefault: m['commission_is_default'] != false,
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
      deductionMethod: deductionMethodOf(map['deduction_method']),
      deductionValue: _dbl(map['deduction_value']),
      deductionIsDefault: map['deduction_is_default'] != false,
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
        final hours = <int, Set<int>>{};
        final rawHours = m['hours'];
        if (rawHours is List) {
          for (final x in rawHours.whereType<Map>()) {
            final day = _int(x['d']);
            final hour = _int(x['h']);
            if (day >= 1 && day <= 7 && hour >= 0 && hour <= 23) {
              hours.putIfAbsent(day, () => <int>{}).add(hour);
            }
          }
        }
        list.add(DoctorAvailabilityEntry(
          id: _text(m['id']) ?? '',
          name: _text(m['name']) ?? '',
          isDoctor: m['is_doctor'] == true,
          isSecretary: m['is_secretary'] == true,
          bookingOpen: m['booking_open'] != false,
          hours: hours,
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

  /// ★ حفظ ساعات الحجز الأسبوعية التي اختارها الطبيب أو السكرتير.
  /// `hours`: يوم الأسبوع (1=الاثنين … 7=الأحد) ⇒ الساعات المختارة.
  /// قائمة فارغة تماماً = بلا تحديد ⇒ كل الساعات متاحة (السلوك القديم)،
  /// فلا نفرض ساعات من أنفسنا ولا نطفئ ما اختاره هو.
  Future<DoctorHoursSaveResult> saveAvailability(
    String doctorId,
    Map<int, Set<int>> hours,
  ) async {
    if (doctorId.isEmpty) {
      return const DoctorHoursSaveResult.failed('معرّف الطبيب مفقود');
    }
    final payload = <Map<String, int>>[
      for (var d = 1; d <= 7; d++)
        for (final h in (hours[d] ?? const <int>{})) {'d': d, 'h': h},
    ];
    final res = await SupabaseService.instance.rpcCall(
      'doctor_availability_set',
      <String, dynamic>{
        'p_doctor_id': doctorId,
        'p_hours': payload,
      },
      timeoutSeconds: 20,
    );
    if (res is! Map) {
      final why = (SupabaseService.instance.lastRpcError ?? '').trim();
      return DoctorHoursSaveResult.failed(
        why.isEmpty ? 'تعذّر حفظ الأوقات — تحقق من الاتصال' : why,
      );
    }
    final map = Map<String, dynamic>.from(res);
    if (map['ok'] != true) {
      return DoctorHoursSaveResult.failed(
        _text(map['error']) ?? 'تعذّر حفظ الأوقات',
      );
    }
    return DoctorHoursSaveResult.ok(_int(map['count']));
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
    return _parseAction(res);
  }

  DoctorActionResult _parseAction(Object? res) {
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
      credited: map['credited'] == true,
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

  static double _dbl(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
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
    this.calledAt,
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
      calledAt: _date(json['called_at']),
      rejectedAt: _date(json['rejected_at']),
      acceptedAt: _date(json['accepted_at']),
      doneAt: _date(json['done_at']),
    );
  }

  final String id;

  /// رقم الحجز الذي يكتبه السكرتير/الطبيب عند الموافقة. لكل عيادة
  /// سلسلتها اليومية وحدها، وتعود الأرقام متاحة من جديد كل يوم.
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

  /// كشفية الحجز (15,000) — تُقيَّد في محفظة الطبيب بعد تأكيد انتهاء
  /// المعاينة فقط (لا عند الموافقة).
  final int examFee;

  final DateTime? appointmentAt;
  final double? latitude;
  final double? longitude;
  final DateTime? createdAt;

  /// لحظة موافقة العيادة — قبلها الحجز لا يصل للمندوبين.
  final DateTime? approvedAt;

  /// لحظة استدعاء المريض من العيادة («حان دورك»).
  final DateTime? calledAt;

  /// لحظة رفض العيادة — بلا كشفية ويُشعَر المريض.
  final DateTime? rejectedAt;

  /// لحظة أخذ المندوب للحجز — خطوة المراقبة الثانية، و`null` ما لم يأخذه أحد.
  final DateTime? acceptedAt;

  /// لحظة «تمّ الحجز» — يتوقف عندها عدّاد «كم مضى»، كما في الطلب المُسلَّم.
  final DateTime? doneAt;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isCalled => status == 'called';
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
    'called' => 'حان دورك',
    'accepted' => 'تمّت الموافقة',
    'done' => 'انتهت المعاينة',
    'cancelled' => 'أُلغي',
    'rejected' => 'رفضت العيادة',
    _ => 'بانتظار الموافقة',
  };
}

/// قائمة انتظار عيادة واحدة اليوم.
class DoctorQueueClinic {
  const DoctorQueueClinic({
    required this.doctorId,
    required this.doctorName,
    required this.items,
    this.isDoctor = false,
    this.isSecretary = false,
  });

  factory DoctorQueueClinic.fromJson(Map<String, dynamic> json) {
    final items = <DoctorQueueItem>[];
    final raw = json['items'];
    if (raw is List) {
      for (final r in raw.whereType<Map>()) {
        items.add(DoctorQueueItem.fromJson(Map<String, dynamic>.from(r)));
      }
    }
    return DoctorQueueClinic(
      doctorId: DoctorService._text(json['doctor_id']) ?? '',
      doctorName: DoctorService._text(json['doctor_name']) ?? '',
      items: items,
      isDoctor: json['is_doctor'] == true,
      isSecretary: json['is_secretary'] == true,
    );
  }

  final String doctorId;
  final String doctorName;
  final List<DoctorQueueItem> items;
  final bool isDoctor;
  final bool isSecretary;

  /// المستدعون الآن — يمكن أن يكون أكثر من مريض في الوقت نفسه.
  List<DoctorQueueItem> get calledList =>
      items.where((i) => i.isCalled).toList(growable: false);

  List<DoctorQueueItem> get waiting =>
      items.where((i) => !i.isCalled).toList(growable: false);
}

/// صف واحد في قائمة الانتظار.
class DoctorQueueItem {
  const DoctorQueueItem({
    required this.id,
    required this.serial,
    required this.patientName,
    required this.patientPhone,
    required this.status,
    required this.position,
    this.calledAt,
    this.appointmentAt,
  });

  factory DoctorQueueItem.fromJson(Map<String, dynamic> json) {
    return DoctorQueueItem(
      id: DoctorService._text(json['id']) ?? '',
      serial: DoctorService._text(json['serial']) ?? '',
      patientName: DoctorService._text(json['patient_name']) ?? '',
      patientPhone: DoctorService._text(json['patient_phone']) ?? '',
      status: DoctorService._text(json['status']) ?? 'approved',
      position: DoctorService._int(json['position']),
      calledAt: DoctorAppointment._date(json['called_at']),
      appointmentAt: DoctorAppointment._date(json['appointment_at']),
    );
  }

  final String id;
  final String serial;
  final String patientName;
  final String patientPhone;
  final String status;

  /// عدد من يسبقه في نفس العيادة.
  final int position;

  final DateTime? calledAt;
  final DateTime? appointmentAt;

  bool get isCalled => status == 'called';

  String get serialLabel => serial.isEmpty
      ? ''
      : (serial.startsWith('#') ? serial : '#$serial');
}

/// نتيجة قراءة قائمة الانتظار: عيادات، أو نصّ الفشل.
class DoctorQueue {
  const DoctorQueue({this.clinics = const [], this.isAdmin = false, this.error = ''});

  final List<DoctorQueueClinic> clinics;
  final bool isAdmin;
  final String error;

  bool get ok => error.isEmpty;

  bool get isEmpty =>
      clinics.every((c) => c.items.isEmpty);
}

/// إحصائيات اليوم لعيادة واحدة — كل حجز في خانة واحدة بحسب حالته.
class DoctorDayStatsClinic {
  const DoctorDayStatsClinic({
    required this.doctorId,
    required this.doctorName,
    this.waiting = 0,
    this.called = 0,
    this.done = 0,
    this.rejected = 0,
  });

  final String doctorId;
  final String doctorName;

  /// منتظر اليوم (موافَق عليه ولم يُستدعَ بعد).
  final int waiting;

  /// في الكشف الآن (مستدعى).
  final int called;
  final int done;
  final int rejected;

  /// المراجعون الحاليون = في الكشف + منتظر.
  int get current => waiting + called;
}

/// مجموع إحصائيات اليوم لكل عيادات الحساب.
class DoctorDayStats {
  const DoctorDayStats({
    this.clinics = const [],
    this.waiting = 0,
    this.called = 0,
    this.done = 0,
    this.rejected = 0,
    this.error = '',
  });

  final List<DoctorDayStatsClinic> clinics;
  final int waiting;
  final int called;
  final int done;
  final int rejected;

  /// فراغ = الأرقام صحيحة؛ النصّ = تعذّر الجلب (أو الدالة غير مثبّتة).
  final String error;

  bool get ok => error.isEmpty;
  int get current => waiting + called;
}

/// بطاقة الزبون: دوره النشط الآن.
class ActiveDoctorTicket {
  const ActiveDoctorTicket({
    required this.appointmentId,
    required this.doctorId,
    required this.doctorName,
    required this.specialty,
    required this.serial,
    required this.status,
    required this.position,
    required this.examFee,
    this.appointmentAt,
    this.calledAt,
    this.approvedAt,
  });

  factory ActiveDoctorTicket.fromJson(Map<String, dynamic> json) {
    return ActiveDoctorTicket(
      appointmentId: DoctorService._text(json['appointment_id']) ?? '',
      doctorId: DoctorService._text(json['doctor_id']) ?? '',
      doctorName: DoctorService._text(json['doctor_name']) ?? '',
      specialty: DoctorService._text(json['specialty']) ?? '',
      serial: DoctorService._text(json['serial']) ?? '',
      status: DoctorService._text(json['status']) ?? 'approved',
      position: DoctorService._int(json['position']),
      examFee: DoctorService._int(json['exam_fee']),
      appointmentAt: DoctorAppointment._date(json['appointment_at']),
      calledAt: DoctorAppointment._date(json['called_at']),
      approvedAt: DoctorAppointment._date(json['approved_at']),
    );
  }

  final String appointmentId;
  final String doctorId;
  final String doctorName;
  final String specialty;
  final String serial;
  final String status;

  /// كم مريضاً قبله في العيادة الآن (0 = التالي).
  final int position;
  final int examFee;
  final DateTime? appointmentAt;
  final DateTime? calledAt;
  final DateTime? approvedAt;

  bool get isCalled => status == 'called';

  String get serialLabel => serial.isEmpty
      ? '—'
      : (serial.startsWith('#') ? serial : '#$serial');

  /// الرقم وحده بلا «#» — يُعرض كبيراً في البطاقة.
  String get serialNumber => serial.replaceFirst('#', '');
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

  /// الكشفية المقيدة في محفظة الطبيب بعد تأكيد انتهاء المعاينة.
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
    required this.credited,
  });

  factory DoctorActionResult.success({
    required String serial,
    required int examFee,
    int commission = 0,
    int netAmount = 0,
    required bool already,
    bool credited = false,
  }) => DoctorActionResult._(
    ok: true,
    serial: serial,
    examFee: examFee,
    commission: commission,
    netAmount: netAmount,
    error: '',
    already: already,
    credited: credited,
  );

  factory DoctorActionResult.failed(String error) => DoctorActionResult._(
    ok: false,
    serial: '',
    examFee: 0,
    commission: 0,
    netAmount: 0,
    error: error,
    already: false,
    credited: false,
  );

  final bool ok;
  final String serial;

  /// الكشفية كاملة (15,000).
  final int examFee;

  /// الاستقطاع كما حسبته القاعدة من إعدادات الأدمن (ثابت أو نسبة).
  final int commission;

  /// الصافي المقيد في محفظة العيادة (الكشفية − الاستقطاع).
  final int netAmount;

  final String error;

  /// الإجراء كان منجزاً من قبل: لا كشفية جديدة ولا تغيير.
  final bool already;

  /// «انتهاء المعاينة»: هل أُضيف القيد المالي في هذه الضغطة؟
  /// `false` مع `already=true` = كان منتهياً/مقيَّداً من قبل، بلا تكرار.
  final bool credited;
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

/// سكرتير عيادة واحدة كما يعيده `doctor_secretary_info`.
class DoctorSecretaryInfo {
  const DoctorSecretaryInfo({
    required this.doctorId,
    required this.doctorName,
    required this.phone,
    required this.name,
  });

  final String doctorId;
  final String doctorName;

  /// الرقم كما هو في `doctors.secretary_phone` (فارغ = لا سكرتير).
  final String phone;

  /// اسم صاحب الرقم من `users` إن كان قد سجّل حساباً — وإلا فارغ.
  final String name;

  bool get hasSecretary => phone.isNotEmpty;
}

/// ★ نتيجة فحص رقم السكرتير قبل الحفظ: هل صاحبه مسجّل في التطبيق؟
class DoctorSecretaryCheck {
  const DoctorSecretaryCheck({
    required this.registered,
    required this.name,
  });

  final bool registered;

  /// اسم صاحب الحساب إن كان مسجّلاً — وإلا فارغ.
  final String name;
}

/// نتيجة ضبط/حذف سكرتير العيادة.
class DoctorSecretaryResult {
  const DoctorSecretaryResult._({
    required this.ok,
    required this.phone,
    required this.message,
    required this.error,
  });

  factory DoctorSecretaryResult.ok({
    required String phone,
    required String message,
  }) =>
      DoctorSecretaryResult._(
        ok: true,
        phone: phone,
        message: message,
        error: '',
      );

  factory DoctorSecretaryResult.failed(String error) =>
      DoctorSecretaryResult._(
        ok: false,
        phone: '',
        message: '',
        error: error,
      );

  final bool ok;

  /// الرقم المحفوظ بعد التطبيع (فارغ عند الحذف).
  final String phone;
  final String message;
  final String error;
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
    this.deductionMethod = DeductionMethod.fixed,
    this.deductionValue = 0,
    this.deductionIsDefault = true,
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

  /// نسبة القاعدة القديمة — لم تعد تُعرض؛ الاستقطاع يُقرأ من
  /// `deductionMethod`/`deductionValue`.
  final int commissionPercent;

  /// ★ الاستقطاع الذي حدده الأدمن (ثابت أو نسبة)، من القاعدة مباشرة.
  final DeductionMethod deductionMethod;
  final double deductionValue;
  final bool deductionIsDefault;

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
    this.deductionMethod = DeductionMethod.fixed,
    this.deductionValue = 0,
    this.deductionIsDefault = true,
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

  /// ★ استقطاع هذه العيادة كما ضبطه الأدمن.
  final DeductionMethod deductionMethod;
  final double deductionValue;
  final bool deductionIsDefault;

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

/// ★ عيادة يديرها هذا الحساب (طبيب أو سكرتير) وحالة زر الحجز
///   وساعات الحجز الأسبوعية التي اختارها.
class DoctorAvailabilityEntry {
  const DoctorAvailabilityEntry({
    required this.id,
    required this.name,
    required this.isDoctor,
    required this.isSecretary,
    required this.bookingOpen,
    this.hours = const <int, Set<int>>{},
  });

  final String id;
  final String name;
  final bool isDoctor;
  final bool isSecretary;

  /// ★ مفتاح الفتح العام: مغلق ⇒ لا حجز لأي زبون مهما كانت الساعات.
  final bool bookingOpen;

  /// ★ ساعات الأسبوع المختارة: 1=الاثنين … 7=الأحد ⇒ ساعات اليوم.
  /// فارغة بالكامل = لم يحدد شيئاً ⇒ كل الساعات متاحة.
  final Map<int, Set<int>> hours;

  Set<int> hoursOn(int weekday) => hours[weekday] ?? const <int>{};

  int get weeklyCount => hours.values.fold(0, (sum, s) => sum + s.length);

  DoctorAvailabilityEntry copyWith({
    bool? bookingOpen,
    Map<int, Set<int>>? hours,
  }) =>
      DoctorAvailabilityEntry(
        id: id,
        name: name,
        isDoctor: isDoctor,
        isSecretary: isSecretary,
        bookingOpen: bookingOpen ?? this.bookingOpen,
        hours: hours ?? this.hours,
      );
}

/// نتيجة حفظ ساعات الأسبوع: العدد النهائي كما عدّه الخادم أو نص الرفض.
class DoctorHoursSaveResult {
  const DoctorHoursSaveResult.ok(this.count)
      : ok = true,
        error = '';

  const DoctorHoursSaveResult.failed(this.error)
      : ok = false,
        count = 0;

  final bool ok;
  final int count;
  final String error;
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

