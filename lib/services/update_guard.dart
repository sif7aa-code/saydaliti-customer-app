import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_colors.dart';
import 'supabase_service.dart';

/// قرار فحص الإصدار.
enum UpdateNeed { none, optional, mandatory }

/// رسالة «حدِّث التطبيق»: تقارن إصدار الجهاز بالرقم الذي ينشره الأدمن في
/// `app_settings`، ثم تنقل الزبون إلى صفحة صيدليتي على Google Play.
///
/// كل الأرقام على الخادم ⇒ الأدمن يرفع رقم الإصدار فيُخاطَب الجميع بلا بناء
/// جديد، وبمجرد أن يركّب الزبون الإصدار المعلَن تختفي الرسالة من نفسه.
class UpdateGuard {
  UpdateGuard._();
  static final UpdateGuard instance = UpdateGuard._();

  /// صفحة التطبيق على Google Play — نفس معرّف الحزمة `com.saydaliti.app`.
  /// الفتح يكون بالرابط دائماً: `market://` على هواتف HONOR/Huawei يذهب إلى
  /// صيدلية الشركة (AppMarket) بدل Play، بينما هذا الرابط معتمد لـ
  /// `com.android.vending`، فيفتح الصيدلية الرسمي إذا كان منصَّبا وإلا المتصفح.
  static const String playWebUrl =
      'https://play.google.com/store/apps/details?id=com.saydaliti.app';

  /// نسخة القرص من إعدادات التحديث (تُصلح الفحص بلا إنترنت).
  static const String _kCache = 'update_cfg_cache_v1';

  /// بعد هذا العدد من الإصدارات تفقد الرسالة خيار «لاحقاً».
  static const int mandatoryAfter = 2;

  static const String optionalBody =
      'وصل إصدار جديد من اطباء ذي قار. حدِّثه الآن لتحصل على آخر المنتجات والتحسينات.';
  static const String mandatoryBody =
      'إصدارك لم يعد مدعوماً. حدِّث اطباء ذي قار حتى تتمكن من متابعة طلباتك.';

  /// يمنع عرض النافذة مرتين في نفس التشغيل.
  static bool _showing = false;

  /// يُنادى بعد أول إطار للتطبيق. [installed] يُمرَّر في الاختبارات، وفي
  /// التشغيل الحقيقي يُقرأ من الحزمة نفسها.
  Future<void> start(BuildContext? root, {String? installed}) async {
    if (_showing || root == null) return;
    final current = (installed ?? await _installedVersion())?.trim();
    if (current == null || current.isEmpty) return;

    final remote = await SupabaseService.instance.fetchAppConfig();
    // بلا سيرفر (انقطاع أو ردّ خاطئ) تُقرَّر من آخر نسخة وصلت للقرص.
    final cfg = remote ?? await _readCache();
    if (remote != null) await _writeCache(remote);

    final latest = (cfg?['update_latest_version']?.toString() ?? '').trim();
    final need = decide(
      installed: current,
      latest: latest,
      enabled: cfg?['update_enabled'] != false,
    );
    debugPrint(
      '[update] installed=$current latest=[$latest] '
      'source=${remote != null ? 'server' : (cfg != null ? 'cache' : 'none')} '
      'keys=${cfg?.keys.toList()} need=$need',
    );
    if (need == UpdateNeed.none) return;
    if (!root.mounted) {
      debugPrint('[update] context gone before dialog');
      return;
    }

    final custom = cfg?['update_message']?.toString().trim() ?? '';
    final body =
        '${custom.isNotEmpty ? custom : (need == UpdateNeed.mandatory ? mandatoryBody : optionalBody)}\n\nالإصدار الجديد: $latest';

    _showing = true;
    try {
      await _show(root, need: need, body: body);
    } finally {
      _showing = false;
    }
  }

  /// النافذة: «لاحقاً» موجودة في الاختيارية فقط، والإجبارية لا تُغلق بالنقر
  /// خارجها ولا بزر الرجوع.
  Future<void> _show(
    BuildContext root, {
    required UpdateNeed need,
    required String body,
  }) async {
    final forced = need == UpdateNeed.mandatory;
    await showDialog<void>(
      context: root,
      barrierDismissible: false,
      builder: (dialogCtx) => PopScope(
        canPop: !forced,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          icon: Icon(
            forced ? Icons.gpp_bad_rounded : Icons.system_update_alt_rounded,
            color: AppColors.primary,
            size: 34,
          ),
          title: Text(
            forced ? 'التحديث مطلوب للمتابعة' : 'يوجد إصدار جديد',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
          content: Text(
            body,
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontSize: 13.5, height: 1.8),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            if (!forced)
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text(
                  'لاحقاً',
                  style: GoogleFonts.cairo(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            FilledButton(
              onPressed: () {
                if (!forced) Navigator.pop(dialogCtx);
                unawaited(openPlayStore());
              },
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: Text(
                'تحديث الآن',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// فتح صفحة صيدليتي على Play (السبب في الرابط بالأعلى: لا `market://`).
  static Future<void> openPlayStore() async {
    try {
      await launchUrl(
        Uri.parse(playWebUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('[update] play launch failed: $e');
    }
  }

  /// صفر = محدَّث (أو أحدث من المعلَن)، وإلا عدد الإصدارات المتأخرة.
  static int versionsBehind(String installed, String latest) {
    final a = _parts(installed), b = _parts(latest);
    if (a.isEmpty || b.isEmpty) return 0;
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x == y) continue;
      if (x > y) return 0;
      // فرق في مكوّن غير الأخير (1.7 ⇒ 1.8) = أبعد من إصدارين.
      final lastSegment = i == a.length - 1 && i == b.length - 1;
      return lastSegment ? y - x : mandatoryAfter;
    }
    return 0;
  }

  static UpdateNeed decide({
    required String installed,
    required String latest,
    bool enabled = true,
  }) {
    if (!enabled || _parts(latest).isEmpty) return UpdateNeed.none;
    final behind = versionsBehind(installed, latest);
    if (behind <= 0) return UpdateNeed.none;
    return behind >= mandatoryAfter
        ? UpdateNeed.mandatory
        : UpdateNeed.optional;
  }

  static List<int> _parts(String version) => version
      .trim()
      .split(RegExp(r'[^0-9]+'))
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList();

  static Future<String?> _installedVersion() async {
    try {
      final v = (await PackageInfo.fromPlatform()).version.trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCache);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(Map<String, dynamic> cfg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCache,
        jsonEncode({
          'update_latest_version': cfg['update_latest_version'] ?? '',
          'update_enabled': cfg['update_enabled'] ?? true,
          'update_message': cfg['update_message'] ?? '',
        }),
      );
    } catch (_) {}
  }
}
