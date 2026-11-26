import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';

/// سمة واحدة لشاشة الدردشة: خلفية المحادثة ولونا الفقاعتين.
class ChatTheme {
  const ChatTheme({
    required this.key,
    required this.name,
    required this.background,
    required this.mineBubble,
    required this.otherBubble,
    required this.otherBorder,
    required this.otherText,
    required this.otherSub,
    required this.tint,
  });

  final String key;
  final String name;
  final Color background;
  final Color mineBubble;
  final Color otherBubble;
  final Color otherBorder;
  final Color otherText;
  final Color otherSub;

  /// لون خلفية اقتباس الرد في فقاعة الطرف الآخر.
  final Color tint;

  static const ChatTheme fallback = ChatTheme(
    key: 'default',
    name: 'الافتراضي',
    background: AppColors.background,
    mineBubble: AppColors.primary,
    otherBubble: AppColors.surface,
    otherBorder: AppColors.divider,
    otherText: AppColors.textPrimary,
    otherSub: AppColors.textHint,
    tint: AppColors.primaryLight,
  );

  static const List<ChatTheme> all = <ChatTheme>[
    fallback,
    ChatTheme(
      key: 'blue',
      name: 'أزرق',
      background: Color(0xFFE8F2FB),
      mineBubble: Color(0xFF1E88E5),
      otherBubble: Colors.white,
      otherBorder: Color(0xFFCFE3F5),
      otherText: Color(0xFF102A43),
      otherSub: Color(0xFF6B8299),
      tint: Color(0xFFD9EAFB),
    ),
    ChatTheme(
      key: 'purple',
      name: 'بنفسجي',
      background: Color(0xFFF3EEFA),
      mineBubble: Color(0xFF7E57C2),
      otherBubble: Colors.white,
      otherBorder: Color(0xFFE0D3F0),
      otherText: Color(0xFF2A1B3D),
      otherSub: Color(0xFF8B7CA6),
      tint: Color(0xFFEBE2F8),
    ),
    ChatTheme(
      key: 'rose',
      name: 'وردي',
      background: Color(0xFFFDEEF3),
      mineBubble: Color(0xFFC2185B),
      otherBubble: Colors.white,
      otherBorder: Color(0xFFF6CFDC),
      otherText: Color(0xFF3D1120),
      otherSub: Color(0xFF9E7383),
      tint: Color(0xFFFBE2EB),
    ),
    ChatTheme(
      key: 'dark',
      name: 'داكن',
      background: Color(0xFF101A16),
      mineBubble: Color(0xFF00897B),
      otherBubble: Color(0xFF1E2B26),
      otherBorder: Color(0xFF2D3F37),
      otherText: Color(0xFFE8F1EC),
      otherSub: Color(0xFF9DB5AA),
      tint: Color(0xFF1B2E27),
    ),
  ];

  static ChatTheme byKey(String? key) {
    final k = (key ?? '').trim();
    for (final t in all) {
      if (t.key == k) return t;
    }
    return fallback;
  }
}

/// سمة الدردشة المحفوظة دائماً — يبدأ التطبيق بها في كل فتح حتى يغيّرها صاحبها.
class ChatThemeStore {
  ChatThemeStore._();

  static const String _prefsKey = 'chat_theme_v1';
  static final ValueNotifier<ChatTheme> current = ValueNotifier<ChatTheme>(
    ChatTheme.fallback,
  );
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      current.value = ChatTheme.byKey(prefs.getString(_prefsKey));
    } catch (_) {
      // بلا حفظ سابق — الافتراضي.
    }
  }

  static Future<void> save(ChatTheme theme) async {
    current.value = theme;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, theme.key);
    } catch (_) {
      // التطبيق يستعملها الآن؛ الحفظ يعود في المحاولة التالية.
    }
  }
}
