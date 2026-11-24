/// الفرع الحقيقي: كل منصة تملك `dart:io` (أندرويد/ويندوز/…) تأخذ المكتبة
/// نفسها كما هي، فلا أي تغيير في سلوك التطبيق على الهاتف.
///
/// يُختار هذا الملف من شرط الاستيراد في `main.dart` و
/// `services/system_notification.dart`:
/// `import 'core/io_stub_web.dart' if (dart.library.io) 'core/io_native.dart';`
export 'dart:io' show Directory, File, FileMode, Platform;
