import 'package:flutter/material.dart';

import '../../screens/login_screen.dart';
import '../../services/auth_service.dart';

/// ★ بوابة الإرسال: لا طلب ولا حجز ولا طلب مندوب بلا تسجيل دخول.
///   تُقرأ من `AuthService` لحظة الإرسال لا من نسخة الواجهة.
bool get hasAppSession {
  final auth = AuthService.instance;
  return auth.isLoggedIn && (auth.phone?.isNotEmpty ?? false);
}

/// يفتح شاشة الدخول، وعند النجاح ينفّذ [onSuccess] ليكمل الإرسال نفسه.
void pushAppLogin(BuildContext context, {required VoidCallback onSuccess}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          LoginScreen(showBackButton: true, onLoginSuccess: onSuccess),
    ),
  );
}
