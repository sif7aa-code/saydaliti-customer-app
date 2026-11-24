import 'package:firebase_core/firebase_core.dart';

/// إعداد Firebase للويب — مشروع `diqarapp`.
///
/// ### مشروع واحد لكل المنصات (٢٠٢٦-١١-٢٤)
/// أندرويد وآيفون والويب كلهم الآن مسجّلون في `diqarapp` (مشروع الأدمن)،
/// وحساب `shtra-af201` القديم خرج من مسار الإشعارات نهائياً. مفتاح
/// الخدمة في السيرفر مشروعيّ، فيرسل المنصات الثلاث من المشروع نفسه.
///
/// ### حقيقة `apiKey`
/// مفتاح Firebase للويب **عام بحكم التصميم** (يوثّق Firebase نشره داخل
/// الصفحة)، والحماية على قواعد الأمان في المشروع. فلا حاجة لتجزئته.
/// أما مفتاح الخدمة (Service Account) فسرّ حقيقي: لا يدخل التطبيق أبداً،
/// بل الخادم وحده.
class FirebaseWebConfig {
  FirebaseWebConfig._();

  static const FirebaseOptions options = FirebaseOptions(
    apiKey: 'AIzaSyDFJpVhWb1-_M5TNzGAQnnO6nthr0QQMmQ',
    authDomain: 'diqarapp.firebaseapp.com',
    projectId: 'diqarapp',
    storageBucket: 'diqarapp.firebasestorage.app',
    messagingSenderId: '828586455121',
    appId: '1:828586455121:web:5293088b354fcd09408870',
  );

  /// مفتاح الويب العام لدفع الإشعارات (Web Push certificates).
  static const String vapidKey =
      'BAxXPK3sM9rgH30l1eMS7Q-ctt_X1yGN7-yc9oQrozeHrQDQvQg4Ahqt_jFjW7JVD7g72Up1fEERYtXzwlwRP9k';
}
