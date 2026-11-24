import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';

/// هل التطبيق مفتوح في وضع «مثبّت» (standalone)؟
@JS('window.matchMedia')
external JSBoolean _matchMedia(String query);

/// هل نافذة التثبيت الأصلية جاهزة؟ (معرّفة في `web/index.html`)
@JS('window.__saydalitiCanInstall')
external JSBoolean? _canInstall();

/// دالة التثبيت المعرّفة في `web/index.html` — تطلق نافذة التثبيت
/// الأصلية للمتصفح إن كانت جاهزة، وإلا تعيد false.
@JS('window.__saydalitiInstall')
external JSBoolean? _saydalitiInstall();

/// تنادي دالة JS خارجية بأمان: إن لم تكن معرّفة (متصفح بلا دعم)
/// يُرمى خطأ عند النداء فنعيد [fallback].
bool? _jsBool(bool? Function() call) {
  try {
    return call();
  } catch (_) {
    return null;
  }
}

/// بطاقة «ثبّت التطبيق على شاشتك» لنسخة الويب.
///
/// تظهر في الرئيسية عند فتح الموقع من المتصفح (وليس من الاختصار
/// المثبّت)، وتختفي نهائياً عند الضغط على «لاحقاً» أو بعد تثبيته.
class InstallAppBanner extends StatefulWidget {
  const InstallAppBanner({super.key, this.padding = 12});

  /// الهامش الأفقي الخارجي (يأتي من الصفحة ليطابق بقية البطاقات).
  final double padding;

  static const String _closedKey = 'install_banner_closed_v1';

  @override
  State<InstallAppBanner> createState() => _InstallAppBannerState();
}

class _InstallAppBannerState extends State<InstallAppBanner> {
  bool _visible = false;

  /// هل يملك المتصفح نافذة تثبيت أصلية (كروم/إيدج أندرويد وحاسوب)؟
  bool _canPrompt = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!kIsWeb) return;
    try {
      if (_matchMedia('(display-mode: standalone)').toDart) return;
    } catch (_) {
      // matchMedia غير موجود (متصفح قديم) — نكمل ونعرض البانر.
    }
    _canPrompt = _jsBool(() => _canInstall()?.toDart ?? false) ?? false;
    var closed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      closed = prefs.getBool(InstallAppBanner._closedKey) ?? false;
    } catch (_) {}
    if (mounted && !closed) setState(() => _visible = true);
  }

  Future<void> _close() async {
    setState(() => _visible = false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(InstallAppBanner._closedKey, true);
    } catch (_) {}
  }

  void _install() {
    if (!_canPrompt) return;
    final ok = _jsBool(() => _saydalitiInstall()?.toDart ?? false) ?? false;
    if (ok) _close();
  }

  String get _instructions {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'من سفاري اضغط زر المشاركة «مربع فيه سهم لأعلى» ثم اختر «إضافة إلى الشاشة الرئيسية».';
      case TargetPlatform.android:
        return 'اضغط «⋮» في متصفحك ثم اختر «إضافة إلى الشاشة الرئيسية» أو «تثبيت التطبيق».';
      default:
        return 'اضغط أيقونة التثبيت في شريط عنوان المتصفح، أو من قائمته اختر «تثبيت التطبيق».';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.padding),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFFE5F6F7),
          border: Border.all(color: AppColors.divider),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.add_to_home_screen_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ثبّت تطبيق اطباء ذي قار على شاشتك',
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _instructions,
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (_canPrompt)
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                            ),
                            visualDensity: VisualDensity.compact,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          onPressed: _install,
                          child: Text(
                            'تثبيت الآن',
                            style: GoogleFonts.cairo(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _close,
                        child: Text(
                          'لاحقاً',
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _close,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppColors.textSecondary,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: 'إغلاق',
            ),
          ],
        ),
      ),
    );
  }
}
