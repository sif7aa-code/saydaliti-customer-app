/// بدل `dart:io` عند البناء للويب فقط.
///
/// يُستدعى بشرط من ملف التشغيل:
/// `import 'dart:io' if (!dart.library.io) 'core/io_stub_web.dart';`
/// فأي منصة فيها `dart:io` (أندرويد/ويندوز/…) تستخدم المكتبة الحقيقية نفسها
/// حرفياً، ولا يتغيّر سلوك التطبيق على الهاتف إطلاقاً. المتصفح لا يملك ملفات،
/// لذلك كل دالة هنا تُجيب «لا شيء» بدل أن ترمي: مواضع الاستعمال كلها داخل
/// `try` أو اختبار وجود ملف، فالحذف/القراءة على الويب ببساطة لا يحدثان.
class File {
  File(this.path);

  final String path;

  bool existsSync() => false;

  Future<bool> exists() async => false;

  int lengthSync() => 0;

  Future<int> length() async => 0;

  Future<File> writeAsBytes(List<int> bytes, {bool flush = false}) async =>
      this;

  Future<File> writeAsString(String contents, {bool flush = false}) async =>
      this;

  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      RandomAccessFile();
}

/// سطح كتابة/قراءة فارغ — يكفي توقيعات `main.dart` (writeString/flush/close).
class RandomAccessFile {
  void writeString(String contents) {}

  void write(List<int> bytes) {}

  Future<void> flush() async {}

  Future<void> close() async {}
}

enum FileMode { read, write, append }

/// بلا ملفات على الويب: كل الأنظمة `false` والفاصل `/` كما في الروابط.
abstract final class Platform {
  static const String pathSeparator = '/';
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isWindows = false;
  static const bool isLinux = false;
  static const bool isMacOS = false;
  static const String operatingSystem = 'web';
}
