import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../services/token_storage.dart';
import 'session_provider.dart';

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final apiServiceProvider = Provider<ApiService>((ref) {
  final api = ApiService();
  // Read lazily inside the callback: the session notifier itself depends on this provider.
  api.onUnauthorized = () => ref.read(sessionProvider.notifier).expire();
  return api;
});

/// Index of the selected bottom-navigation tab in HomeShell.
final homeTabProvider = StateProvider<int>((ref) => 0);
