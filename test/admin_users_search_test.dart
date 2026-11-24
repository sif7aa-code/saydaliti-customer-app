import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/user_search.dart';
import 'package:saydaliti/screens/admin_users_screen.dart';

/// المنطق يُختبر على الحسابات نفسها، والشاشة تُختبر على الوصل:
/// الاختبار بلا شبكة، فالقائمة تصل فارغاً ولا تُقاس الأرقام هنا.
void main() {
  Map<String, dynamic> user({
    required String phone,
    String? name,
    bool driver = false,
    bool admin = false,
    bool owner = false,
  }) =>
      {
        'phone': phone,
        'name': name,
        'is_driver': driver,
        'is_admin': admin,
        'is_shop_owner': owner,
        'is_active': true,
      };

  final roster = <Map<String, dynamic>>[
    user(phone: '07801234567', name: 'أحمد عباس'),
    user(phone: '07712223334', name: 'زوزايه كريم', driver: true),
    user(phone: '07900000001', name: 'مروة حسن', owner: true),
    user(phone: '07849463956', admin: true),
  ];

  group('منطق البحث في الحسابات', () {
    test('الهمزة والتاء المربوطة لا تقفان في الطريق', () {
      expect(UserSearch.filter(roster, 'احمد').length, 1);
      expect(UserSearch.filter(roster, 'أحمد').length, 1);
      expect(UserSearch.filter(roster, 'احمَد').length, 1);
      expect(UserSearch.filter(roster, 'زوز').length, 1);
      expect(UserSearch.filter(roster, 'مروه').length, 1);
    });

    test('الرقم يوصل بأي صيغة كتابة وبجزء منه', () {
      for (final form in [
        '07801234567',
        '0780-123-4567',
        '+9647801234567',
        '9647801234567',
        '34567',
      ]) {
        expect(
          UserSearch.filter(roster, form).length,
          1,
          reason: 'صيغة الرقم «$form» يجب أن توصل لصاحبها',
        );
      }
    });

    test('بلا بحث القائمة كما هي، ومع كلمة لا تشبه أحداً لا نتيجة', () {
      expect(UserSearch.filter(roster, ''), roster);
      expect(UserSearch.filter(roster, '    '), roster);
      expect(UserSearch.filter(roster, 'ليسهو'), isEmpty);
    });

    test('من لا اسم له يُوجد برقمه لا بلقب يُختلق له', () {
      final found = UserSearch.filter(roster, '0784946');
      expect(found.length, 1);
      expect(found.single['is_admin'], true);
    });
  });

  group('حقل البحث في شاشة إدارة المستخدمين', () {
    Future<void> pumpUsers(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: AdminUsersScreen(),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
    }

    testWidgets('على عرض 320 لا فيض في الحقل ولا في سطر النتيجة', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: AdminUsersScreen(),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      await tester.enterText(find.byType(TextField), 'احمد');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('0 من 0'), findsOneWidget);
    });

    testWidgets('يظهر فوق القائمة ويمسح بزر واحد', (tester) async {
      await pumpUsers(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('ابحث بالاسم أو رقم الهاتف…'), findsOneWidget);
      expect(find.text('إدارة المستخدمين'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'مندوب');
      await tester.pump();
      expect(find.text('0 من 0'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(find.text('0 من 0'), findsNothing);
    });
  });
}
