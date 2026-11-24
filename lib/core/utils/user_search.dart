import 'account_name.dart';
import 'auth_fields.dart';

/// ★ بحث الأدمن في قائمة الحسابات — بالاسم الحقيقي أو بالرقم.
///
///   القائمة كلها تصل من القاعدة في نداء واحد (`fetchUsers`)، فتُصفَّى
///   هنا فوراً بدل طلب `ilike` كل حرف: لا انتظار شبكة، ولا تحميل القائمة
///   من جديد، ولا فرق بين أن يكون الحساب في أولها أو في آخرها.
///
///   والتطبيع العربي ليس ترفاً: الأسماء محفوظة بهمزاتها وتائها المربوطة
///   («أحمد»، «مروة»)، والأدمن يكتب كما يسمعها بلا تشكيل — فبلا هذا لا يجد
///   أحداً ويظن أن البحث معطوب.
class UserSearch {
  const UserSearch._();

  /// الحركات والتطويل والألف الخنجرية: لا يكتبها أحد في البحث وقد تكون
  /// مكتوبة في الاسم المحفوظ.
  static final RegExp _diacritics = RegExp('[\\u064B-\\u0652\\u0640\\u0670]');

  /// نص قابل للمقارنة: صغير، بلا حركات، والهمزات والتاء المربوطة والألف
  /// المقصورة كلها تردّ إلى أصلها.
  static String fold(String raw) => raw
      .toLowerCase()
      .replaceAll(_diacritics, '')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ٱ', 'ا')
      .replaceAll('ئ', 'ي')
      .replaceAll('ؤ', 'و')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي');

  /// الرقم إلى صيغة الحفظ المحلية: `+964` و`00964` و`964` كلها ترجع إلى
  /// `07…` — لأن `users.phone` محفوظ كذلك، والأدمن ينسخ الرقم كما يظهر في
  /// واتساب أو في سجل الطلب فيصيغه الدولية لا تقابل المخزَّنة حرفاً بحرف.
  static String _localDigits(String raw) {
    var d = AuthFields.digits(raw);
    if (d.startsWith('00')) d = d.substring(2);
    if (d.startsWith('964')) d = '0${d.substring(3)}';
    return d;
  }

  /// هل يطابق هذا الحساب كلمة البحث؟ جزء من الاسم، أو جزء من الرقم مكتوباً
  /// بأي صيغة (شرطات ومسافات و+964 و07 كلها أرقام عند المقارنة).
  static bool matches(Map<String, dynamic> user, String query) {
    final q = fold(query.trim());
    if (q.isEmpty) return true;
    final digits = _localDigits(query);
    if (digits.length >= 2) {
      if (_localDigits(user['phone']?.toString() ?? '').contains(digits)) {
        return true;
      }
    }
    final name = fold(AccountName.real(name: user['name'], phone: user['phone']));
    return name.contains(q);
  }

  /// القائمة المرئية: كما هي بلا بحث، ومطابقةٌ للكلمة مع البحث.
  static List<Map<String, dynamic>> filter(
    List<Map<String, dynamic>> users,
    String query,
  ) {
    if (query.trim().isEmpty) return users;
    return users.where((u) => matches(u, query)).toList();
  }
}
