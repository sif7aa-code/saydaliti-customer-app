/// ★ اسم الحساب **حقيقي** أو رقمه — ولا لقب عام يُخترع له.
///
///   القاعدة: لكل حساب اسمُه المخزَّن، وهو ثابت ما لم يُبدّله صاحبه أو
///   الأدمن. فإن لم يكن له اسم، فهُويّته رقمه (رقم ثابت لا يتبدّل)،
///   لا كلمة مثل «حساب» أو «زبون» أو «مندوب» — تلك ألقاب عامة تختلط
///   فيها الحسابات ولا يعرف أحد من هو.
///
///   الملف كله مصدر واحد لكل الواجهات، فلا تُصلح شاشة وتبقى أخرى.
class AccountName {
  const AccountName._();

  /// ألقاب عامة ليست أسماءً لأحد — كانت تُكتب في `users.name` عند
  /// التسجيل بلا اسم، أو تُعرض احتياطاً في الواجهات القديمة.
  static const Set<String> _genericLabels = <String>{
    'حساب',
    'حساب جديد',
    'زبون',
    'عميل',
    'مستخدم',
    'مندوب',
    'سائق',
    'تاجر',
    'صاحب صيدلية',
    'account',
    'new account',
    'user',
    'customer',
    'client',
    'driver',
    'merchant',
    'shop owner',
  };

  /// نص نظيف من أي قيمة خام من القاعدة: `null` النصي فراغ، والفراغ فراغ.
  static String _clean(dynamic v) {
    if (v == null) return '';
    final s = v.toString().trim();
    return s.toLowerCase() == 'null' ? '' : s;
  }

  /// هل هذه القيمة لقب عام (أو فراغ) لا اسم لأحد بعينه؟
  static bool isGeneric(dynamic v) {
    final s = _clean(v);
    if (s.isEmpty) return true;
    return _genericLabels.contains(s) || _genericLabels.contains(s.toLowerCase());
  }

  /// الاسم الحقيقي: اسم الحساب، ثم اسم صيدليته إن كان تاجراً، ثم رقمه
  /// الثابت. فإن لم يُعرف أيّ منها أُرجع فراغ — والفراغ أصدق من لقب.
  ///
  /// [name] الاسم المخزّن، [shop] اسم صيدليته، [phone] رقمه.
  static String real({dynamic name, dynamic shop, dynamic phone}) {
    final n = _clean(name);
    if (!isGeneric(n)) return n;
    final s = _clean(shop);
    if (!isGeneric(s)) return s;
    return _clean(phone);
  }

  /// الاسم مع رقمه في سطر واحد للوحات: «أم علي · 07800000001».
  ///
  /// إذا لم يكن اسمٌ حقيقي فالرقم وحده — لا يُضاف لقب بعده.
  static String withPhone({dynamic name, dynamic shop, dynamic phone}) {
    final p = _clean(phone);
    final n = real(name: name, shop: shop, phone: phone);
    if (n.isEmpty) return p;
    if (p.isEmpty || p == n) return n;
    return '$n · $p';
  }
}
