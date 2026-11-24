import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:saydaliti/app.dart';
import 'package:saydaliti/screens/doctor_appointment_screen.dart';
import 'package:saydaliti/screens/free_driver_request_screen.dart';
import 'package:saydaliti/screens/services_screen.dart';
import 'package:saydaliti/services/auth_service.dart';
import 'package:saydaliti/services/doctor_service.dart';
import 'package:saydaliti/services/notification_center.dart';
import 'package:saydaliti/services/realtime_service.dart';
import 'package:saydaliti/widgets/bottom_nav_bar.dart';
import 'package:saydaliti/widgets/doctor_appointment_card.dart';
import 'package:saydaliti/widgets/doctor_appointment_details.dart';

/// ★ ميزة «حجز موعد دكتور/ة» (طلب الأدمن ٢٠٢٦-١٠-٣١).
///
///   المُحكَّ هنا أربعة أشياء هي موضع الخطر:
///   * **قائمة التخصص**: أسماء الأدمن التسعة بترتيبها ونطقه. أي زيادة
///     أو تبديل حرف يراهم في الشاشة فيرفضها.
///   * **تبويب خدمات**: بوابتان، و«طلب مندوب» تفتح نفس شاشته كما هي.
///   * **الرقم التسلسلي**: من `doctor_serial_seq` وحده، فيظهر «#N» لا
///     رقم طلب متجر.
///   * **الإجبار قبل التثبيت**: بلا تاريخ كان الانهيار صامتاً في
///     `_appointmentAt!`؛ ومن هنا لا يُرسل حجز ناقص.
///
///   بلا شبكة: لا اختبار هنا يضغط «تثبيت الحجز» ببيانات كاملة، لأن
///   ذلك يكتب في قاعدة الإنتاج.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> view(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> silenceBackground(WidgetTester tester) async {
    NotificationCenter.instance.stop();
    RealtimeService.instance.stop();
    await tester.pump();
  }

  Future<void> logIn() async {
    // رقم وهمي صراحةً: أصفار بعد المقدّمة، لا اسم ولا رقم حقيقي.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AuthService.loggedInPrefKey, true);
    await prefs.setString('auth_phone', '07000000000');
    await AuthService.instance.init();
  }

  /// يرسم شاشة مستقلة فوق `MaterialApp` باتجاه عربي.
  Future<void> page(WidgetTester tester, Widget screen) => tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Directionality(textDirection: TextDirection.rtl, child: screen),
    ),
  );

  DoctorAppointment booking({
    String serial = '7',
    String status = 'pending',
    String specialty = 'كسور',
    String driverName = '',
    String? acceptedAt,
    String? doneAt,
  }) => DoctorAppointment.fromJson(<String, dynamic>{
    'id': 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d',
    'serial_number': serial,
    'specialty': specialty,
    'doctor_name': 'د. علي الحسيني',
    'patient_name': 'زينب العبودي',
    'contact_phone': '07800000001',
    'address': 'الشطرة - قرب السوق',
    'status': status,
    'driver_name': driverName,
    'appointment_at': '2026-11-02T07:30:00.000Z',
    'latitude': 31.78,
    'longitude': 46.21,
    'created_at': '2026-10-31T10:00:00.000Z',
    'accepted_at': acceptedAt,
    'done_at': doneAt,
  });

  // ── [1] القائمة والصف كما تخرجهما القاعدة ────────────────────────────

  test('التسعة بأسماء الأدمن وبترتيبه', () {
    expect(DoctorService.specialties, <String>[
      'باطنية',
      'كسور',
      'جراح',
      'قلبية',
      'اذن وحنجرة',
      'اسنان',
      'عيون',
      'اعصاب',
      'غير ذلك',
    ]);
  });

  test('الحجز يحمل رقمه المستقل وتاريخه وحالته', () {
    final a = booking();
    expect(a.serialLabel, '#7');
    expect(a.specialty, 'كسور');
    expect(a.doctorName, 'د. علي الحسيني');
    expect(a.patientName, 'زينب العبودي');
    expect(a.contactPhone, '07800000001');
    expect(a.isOpen, isTrue);
    expect(a.isAccepted, isFalse);
    // الموعد يُعرض للمندوب كما هو عند صاحب الحجز، لا بصيغة خام.
    // التوقيت يُحسب محلياً كما يفعل التطبيق، فالتوقّع لا يُثبَّت على منطقة
    // زمنية machine بعينها.
    final local = DateTime.parse('2026-11-02T07:30:00.000Z').toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    expect(
      a.whenLabel,
      contains('${local.year}-${two(local.month)}-${two(local.day)}'),
    );
    expect(
      a.whenLabel,
      contains(
        '${two(local.hour % 12 == 0 ? 12 : local.hour % 12)}:${two(local.minute)}',
      ),
    );
  });

  test('صفّ بلا رقم: لا شارة ولا رقم مختلَق', () {
    final a = DoctorAppointment.fromJson(<String, dynamic>{
      'id': '1',
      'status': 'pending',
    });
    expect(a.serialLabel, isEmpty);
    expect(a.appointmentAt, isNull);
    expect(a.whenLabel, 'بلا موعد');
  });

  test('المأخوذ عند المندوب ليس مفتوحاً', () {
    expect(booking(status: 'accepted').isAccepted, isTrue);
    expect(booking(status: 'done').isOpen, isFalse);
  });

  // ── [2] بطاقة المندوب: «لديك حجز دكتور/ة» برقمه ──────────────────────

  testWidgets('البطاقة تقول الحجز وتُظهر رقمه المستقل', (tester) async {
    var took = 0;
    await page(
      tester,
      Scaffold(
        body: ListView(
          children: [
            DoctorAppointmentCard(
              appointment: booking(),
              onTake: () => took++,
              onDone: () {},
              forDriver: true,
            ),
          ],
        ),
      ),
    );
    await settle(tester);

    expect(find.text('لديك حجز دكتور/ة'), findsOneWidget);
    // ★ الرقم من سلسلة الحجوزات وحدها، معروضاً كما خرج من القاعدة.
    expect(find.text('#7'), findsOneWidget);
    expect(find.text('كسور'), findsOneWidget);
    expect(find.text('د. علي الحسيني'), findsOneWidget);
    expect(find.text('زينب العبودي'), findsOneWidget);
    expect(find.text('أخذ الحجز'), findsOneWidget);
    expect(find.text('تم الحجز'), findsNothing);

    await tester.tap(find.text('أخذ الحجز'));
    await settle(tester);
    expect(took, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('الحجز المأخوذ يعرض «تم الحجز» ولا يعرض أخذه ثانية', (
    tester,
  ) async {
    var done = 0;
    await page(
      tester,
      Scaffold(
        body: ListView(
          children: [
            DoctorAppointmentCard(
              appointment: booking(status: 'accepted'),
              onTake: () {},
              onDone: () => done++,
              forDriver: true,
            ),
          ],
        ),
      ),
    );
    await settle(tester);

    expect(find.text('أخذ الحجز'), findsNothing);
    expect(find.text('تم الحجز'), findsOneWidget);
    expect(find.text('عندك'), findsOneWidget);

    await tester.tap(find.text('تم الحجز'));
    await settle(tester);
    expect(done, 1);
  });

  // ── [2ب] التفاصيل والمراقبة — الزبون والمندوب من شيت واحد ────────────

  late BuildContext hostContext;

  /// صفيحة تملك `context` حيّاً يفتح عليه الشيت بعد أنفراج البناء —
  /// فالنداء أثناء البناء لا يبني شيئاً وتكون النتيجة اختباراً أخضر كاذب.
  Future<void> host(WidgetTester tester) async {
    await page(
      tester,
      Scaffold(
        body: Builder(
          builder: (ctx) {
            hostContext = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('بطاقة الزبون: عنوانه وحده، وزرّ أخذ لا يظهر له', (tester) async {
    await page(
      tester,
      Scaffold(
        body: ListView(
          children: [
            DoctorAppointmentCard(appointment: booking(), onDetails: () {}),
          ],
        ),
      ),
    );
    await settle(tester);

    expect(find.text('حجزك عند دكتور/ة'), findsOneWidget);
    expect(find.text('لديك حجز دكتور/ة'), findsNothing);
    // لا «أخذ الحجز» لصاحب الحجز: هو لا يأخذ حجزه ولا يُنهيه.
    expect(find.text('أخذ الحجز'), findsNothing);
    expect(find.text('تم الحجز'), findsNothing);
    expect(find.text('تفاصيل الحجز ومراقبته'), findsOneWidget);
  });

  testWidgets('نقر البطاقة يفتح الشيت بكل سطور الحجز وخطواته', (tester) async {
    await page(
      tester,
      Scaffold(
        body: Builder(
          builder: (ctx) => ListView(
            children: [
              DoctorAppointmentCard(
                appointment: booking(),
                onTake: () {},
                forDriver: true,
                onDetails: () => DoctorAppointmentDetails.show(
                  ctx,
                  appointment: booking(),
                  onTake: () {},
                  forDriver: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await settle(tester);

    await tester.tap(find.text('تفاصيل الحجز ومراقبته'));
    await settle(tester);

    // ★ السطور التي كانت غائبة عن الطرفين (طلب الأدمن 10-31).
    expect(find.text('تفاصيل حجز دكتور/ة'), findsOneWidget);
    expect(find.textContaining('رقم هاتف شغال للحجز'), findsOneWidget);
    expect(find.textContaining('اسم المريض أو صاحب الحجز'), findsOneWidget);
    expect(find.text('مراقبة الحجز'), findsOneWidget);
    expect(find.text('الحجز مثبّت'), findsOneWidget);
    expect(find.text('وصل المندوبين'), findsOneWidget);
    // لم يأخذه أحد بعد: الخطوة مرسومة لكن بتفصيل فارغ، والزرّ هو «أخذ» لا «تمّ».
    expect(find.text('مندوب أخذه'), findsOneWidget);
    expect(find.text('لم يأخذه أحد بعد'), findsOneWidget);
    // البطاقة خلف الشيت لا تُطوى: الزرّ مرسوم في الاثنين معاً.
    expect(find.text('أخذ الحجز'), findsWidgets);
    expect(find.text('تم الحجز'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('شيت المندوب الذي أخذ الحجز: «أخذته» وزرّ الإنهاء', (
    tester,
  ) async {
    final taken = booking(
      status: 'accepted',
      driverName: 'حيدر 07000000010',
      acceptedAt: '2026-10-31T11:00:00.000Z',
    );
    await host(tester);
    DoctorAppointmentDetails.show(
      hostContext,
      appointment: taken,
      onDone: () {},
      forDriver: true,
    );
    await settle(tester);

    expect(find.text('أخذته'), findsOneWidget);
    expect(find.text('مندوب أخذه'), findsNothing);
    expect(find.text('تم الحجز'), findsOneWidget);
    expect(find.textContaining('حيدر'), findsWidgets);
  });

  testWidgets('شيت الحجز المنجَز: الخطوة الأخيرة من وقت القاعدة', (
    tester,
  ) async {
    final done = booking(
      status: 'done',
      driverName: 'حيدر 07000000010',
      acceptedAt: '2026-10-31T11:00:00.000Z',
      doneAt: '2026-10-31T12:00:00.000Z',
    );
    expect(done.elapsedFields['delivered_at'], isNotNull);
    expect(done.isDone, isTrue);

    await host(tester);
    DoctorAppointmentDetails.show(
      hostContext,
      appointment: done,
      forDriver: true,
    );
    await settle(tester);

    expect(find.text('تمّ الحجز'), findsWidgets);
    expect(find.text('أخذته'), findsNothing);
    // حجزٌ انتهى: لا زرَّ يُعيد أخذه أو يُنهيه ثانية.
    expect(find.text('تم الحجز'), findsNothing);
    expect(find.text('أخذ الحجز'), findsNothing);
  });

  test('كلمة الحالة من مصدر واحد: «عندك» للمندوب و«مندوب أخذه» لغيره', () {
    expect(DoctorStatus.label('accepted'), 'مندوب أخذه');
    expect(DoctorStatus.label('accepted', mine: true), 'عندك');
    expect(DoctorStatus.label('done'), 'تمّ الحجز');
    expect(DoctorStatus.label('pending'), 'بانتظار مندوب');
    expect(DoctorStatus.label('cancelled'), 'أُلغي');
  });

  testWidgets('شاشة الحجز تعرض التخصصات التسعة', (tester) async {
    await view(tester);
    await page(tester, const DoctorAppointmentScreen());
    await settle(tester);

    expect(find.text('حجز موعد دكتور/ة'), findsWidgets);
    for (final label in <String>[
      'نوع التخصص',
      'اسم الدكتور',
      'اسم المريض أو صاحب الحجز',
      'رقم هاتف شغال للحجز',
      'تاريخ الحجز',
      'تثبيت الحجز',
    ]) {
      expect(find.textContaining(label), findsWidgets, reason: label);
    }

    // القائمة المنسدلة تُفتح بكل الأسماء، لا بثلاثة منها.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await settle(tester);
    for (final s in DoctorService.specialties) {
      expect(find.text(s), findsWidgets, reason: 'التخصص $s مفقود');
    }
  });

  testWidgets('بلا حقول: لا حجز يُرسل والرسائل ظاهرة', (tester) async {
    await view(tester);
    await page(tester, const DoctorAppointmentScreen());
    await settle(tester);

    await tester.tap(find.text('تثبيت الحجز'));
    await settle(tester);

    expect(find.text('أدخل اسم الدكتور'), findsOneWidget);
    expect(find.text('أدخل اسم المريض أو صاحب الحجز'), findsOneWidget);
    expect(find.text('أدخل رقم الهاتف'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('رقم قصير مرفوض قبل الإرسال', (tester) async {
    await view(tester);
    await page(tester, const DoctorAppointmentScreen());
    await settle(tester);

    await tester.enterText(find.byType(TextFormField).at(2), '0781');
    await tester.tap(find.text('تثبيت الحجز'));
    await settle(tester);

    expect(find.text('يجب أن يكون الرقم 11 رقماً بالضبط'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('حقول ممتلئة بلا موعد: رسالة صريحة لا انهيار', (tester) async {
    await view(tester);
    await page(tester, const DoctorAppointmentScreen());
    await settle(tester);

    await tester.enterText(find.byType(TextFormField).at(0), 'د. علي الحسيني');
    await tester.enterText(find.byType(TextFormField).at(1), 'زينب العبودي');
    await tester.enterText(find.byType(TextFormField).at(2), '07800000001');
    await tester.tap(find.text('تثبيت الحجز'));
    await settle(tester);

    // ★ كان هذا السقوط `Null check operator used on a null value` لأن
    //   الموعد سطراً منتقياً لا `TextFormField`، فلا يراه `validate()`.
    expect(find.text('اختر تاريخ الحجز ووقته قبل التثبيت'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ── [4] تبويب خدمات: بوابتان ─────────────────────────────────────────

  Future<void> tapNav(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text(label),
      ),
    );
    await settle(tester);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AuthService.instance.accountDeletedLocally();
  });

  tearDown(() async {
    await AuthService.instance.accountDeletedLocally();
  });

  testWidgets('«خدمات»: مربّع طلب مندوب ومربّع حجز طبيب، وكلٌّ يفتح شاشته', (
    tester,
  ) async {
    await view(tester);
    await logIn();

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);
    await tapNav(tester, 'خدمات');

    expect(find.byType(ServicesScreen), findsOneWidget);
    expect(find.text('اضغط هنا'), findsOneWidget);

    // البوابة الأولى: نفس شاشة طلب المندوب، لا نسخة معدّلة منها.
    await tester.tap(find.text('طلب مندوب'));
    await settle(tester);
    expect(find.byType(FreeDriverRequestScreen), findsOneWidget);
    expect(find.text('طلب مندوب'), findsWidgets);

    Navigator.of(tester.element(find.byType(FreeDriverRequestScreen))).pop();
    await settle(tester);
    expect(find.byType(FreeDriverRequestScreen), findsNothing);

    // البوابة الثانية: مربّع «حجز طبيب» إلى جانب الأول — والشاشة التي
    // يفتحها ما زال عنوانها الكامل «حجز موعد دكتور/ة» لم يَتغيّر.
    await tester.tap(find.text('حجز طبيب'));
    await settle(tester);
    expect(find.byType(DoctorAppointmentScreen), findsOneWidget);
    expect(find.text('تثبيت الحجز'), findsOneWidget);

    await silenceBackground(tester);
  });
}
