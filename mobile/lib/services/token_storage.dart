import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the JWT (Android Keystore / iOS Keychain) and small preferences.
class TokenStorage {
  TokenStorage([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'nisaab_access_token';
  static const _themeKey = 'nisaab_theme_mode';

  Future<String?> readToken() async {
    try {
      return await _storage.read(key: _tokenKey);
    } catch (_) {
      // Corrupted keystore entries (e.g. after a backup restore) must not brick the app.
      await clearToken();
      return null;
    }
  }

  Future<void> saveToken(String token) => _storage.write(key: _tokenKey, value: token);

  Future<void> clearToken() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
  }

  Future<String?> readThemeMode() async {
    try {
      return await _storage.read(key: _themeKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveThemeMode(String mode) => _storage.write(key: _themeKey, value: mode);
}
