import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import 'core_providers.dart';

/// The signed-in user (null = signed out). AsyncError = we have a token but couldn't
/// reach the server to validate it (offline at launch).
class SessionNotifier extends AsyncNotifier<User?> {
  @override
  Future<User?> build() async {
    final storage = ref.read(tokenStorageProvider);
    final api = ref.read(apiServiceProvider);
    final token = await storage.readToken();
    if (token == null) return null;
    api.setToken(token);
    try {
      return await api.me();
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _clear();
        return null;
      }
      rethrow;
    }
  }

  /// Throws [ApiException] on failure so the login form can show the message.
  Future<void> login(String email, String password) async {
    final result = await ref.read(apiServiceProvider).login(email.trim(), password);
    await _persist(result);
  }

  Future<void> register({
    required String fullName,
    required String email,
    required String password,
    double? monthlyIncome,
    required bool acceptTerms,
  }) async {
    final result = await ref.read(apiServiceProvider).register(
          fullName: fullName.trim(),
          email: email.trim(),
          password: password,
          monthlyIncome: monthlyIncome,
          acceptTerms: acceptTerms,
        );
    await _persist(result);
  }

  /// Records consent for an existing account. Throws [ApiException].
  Future<void> acceptTerms() async {
    state = AsyncData(await ref.read(apiServiceProvider).acceptTerms());
  }

  /// Permanently deletes the account, then signs out. Throws [ApiException] (e.g. wrong password).
  Future<void> deleteAccount(String password) async {
    await ref.read(apiServiceProvider).deleteAccount(password);
    await logout();
  }

  Future<void> logout() async {
    await _clear();
    state = const AsyncData(null);
  }

  /// Token rejected by the server (expired / revoked).
  Future<void> expire() async {
    if (state.valueOrNull == null) return;
    await logout();
  }

  Future<void> _persist(AuthResult result) async {
    ref.read(apiServiceProvider).setToken(result.accessToken);
    await ref.read(tokenStorageProvider).saveToken(result.accessToken);
    state = AsyncData(result.user);
  }

  Future<void> _clear() async {
    ref.read(apiServiceProvider).setToken(null);
    await ref.read(tokenStorageProvider).clearToken();
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, User?>(SessionNotifier.new);

/// Convenience for screens that are only reachable when signed in.
final currentUserProvider = Provider<User?>((ref) => ref.watch(sessionProvider).valueOrNull);

User requireUser(Ref ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) throw const ApiException('Not signed in', statusCode: 401);
  return user;
}
