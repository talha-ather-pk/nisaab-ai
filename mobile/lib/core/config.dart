import 'package:flutter/foundation.dart' show kIsWeb;

/// Build-time configuration. Override with --dart-define, e.g.
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
class AppConfig {
  AppConfig._();

  static const String _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

  /// Without an override, a web build talks to the origin it was loaded from (the API serves
  /// it when WEB_DIR is set), and mobile uses 10.0.2.2, the host as seen from the Android
  /// emulator. Use http://127.0.0.1:8000 for the iOS simulator and desktop.
  static String get apiBaseUrl {
    if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
    if (kIsWeb) return Uri.base.origin;
    return 'http://10.0.2.2:8000';
  }

  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 60); // the AI assistant can take a while

  static const String demoEmail = 'demo@nisaab.app';
  static const String demoPassword = 'Demo@1234';
}
