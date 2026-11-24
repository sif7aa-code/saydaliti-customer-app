import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/widgets/app_image.dart';
import 'package:saydaliti/widgets/welcome_banner.dart';

/// ★ صورة الحساب في بطاقة الترحيب (2026-10-30)
///
///   البطاقة الكبيرة (شاشة المندوب) لا تمرَّر لها الصورة، فبقيت أيقونة.
///   الصورة تُرسم في البطاقة المضغوطة وحدها، وبلا صورة تعود الأيقونة.
void main() {
  testWidgets('بلا صورة ⇒ أيقونة الشخص كما كانت', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.rtl,
        child: MaterialApp(
          home: Scaffold(
            body: WelcomeBanner(name: 'ام علي', isDriver: false, compact: true),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    expect(find.byType(AppImage), findsNothing);
  });

  testWidgets('صورة الحساب تحلّ مكان الأيقونة في البطاقة المضغوطة', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.rtl,
        child: MaterialApp(
          home: const Scaffold(
            body: WelcomeBanner(
              name: 'ام علي',
              isDriver: false,
              compact: true,
              avatarUrl: 'avatars/x.png',
            ),
          ),
        ),
      ),
    );

    final image = find.byType(AppImage);
    expect(image, findsOneWidget);
    expect(tester.widget<AppImage>(image).src, 'avatars/x.png');
    // الدائرة ما زالت بمقاسها، فلا يتغيّر ارتفاع البطاقة.
    expect(tester.getRect(find.byType(ClipOval).first).size, const Size(44, 44));
    expect(find.byIcon(Icons.person_rounded), findsNothing);
  });

  testWidgets('البطاقة الكبيرة للمندوب لا تأخذ الصورة', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.rtl,
        child: MaterialApp(
          home: Scaffold(
            body: WelcomeBanner(
              name: 'حيدر',
              isDriver: true,
              avatarUrl: 'avatars/x.png',
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AppImage), findsNothing);
    expect(find.byIcon(Icons.delivery_dining_rounded), findsOneWidget);
  });
}
