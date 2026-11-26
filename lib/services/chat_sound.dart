import 'package:audioplayers/audioplayers.dart';

/// صوت إرسال الرسالة — نقرة قصيرة هادئة مثل تطبيقات الدردشة.
///
/// الملف مولَّد محلياً (`assets/sounds/chat_send.wav`) بلا أي صوت خارجي.
class ChatSound {
  ChatSound._();

  static final AudioPlayer _player = AudioPlayer(playerId: 'chat_send_pop');

  static Future<void> sent() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/chat_send.wav'), volume: 0.8);
    } catch (_) {
      // الصوت رفاهية — لا يعطّل الإرسال أبداً.
    }
  }
}
