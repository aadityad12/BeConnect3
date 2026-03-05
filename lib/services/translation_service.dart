import 'package:flutter/services.dart';

class TranslationService {
  static const _channel =
      MethodChannel('com.beconnect.beconnect/translation');

  /// Translates [text] to [targetLanguage] (BCP-47 code, e.g. 'es', 'fr').
  /// Returns the translated string, or throws [PlatformException] on failure.
  static Future<String> translate(String text, String targetLanguage) async {
    final result = await _channel.invokeMethod<String>('translate', {
      'text': text,
      'targetLanguage': targetLanguage,
    });
    return result ?? text;
  }

  /// Returns language codes (e.g. ['es', 'fr']) that are already downloaded
  /// on this device and available for offline translation.
  /// On iOS: uses LanguageAvailability to check .installed status.
  /// On Android: returns all supported codes (models download on demand).
  static Future<List<String>> getDownloadedLanguages() async {
    try {
      final result = await _channel.invokeListMethod<String>('getDownloadedLanguages');
      return result ?? [];
    } on PlatformException {
      return [];
    }
  }
}
