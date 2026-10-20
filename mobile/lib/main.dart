import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'providers/session_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/ai_chat_screen.dart';
import 'screens/budgets_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/transaction_history_screen.dart';
import 'widgets/common.dart';
import 'widgets/consent.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: NisaabApp()));
}

// =============================================================================
// Routing
// =============================================================================

/// Root routing table. "/" decides between login and the signed-in shell; the other
/// routes open a single screen full-page (deep links, notifications, tests).
abstract final class AppRoutes {
  static const root = '/';
  static const history = '/history';
  static const budgets = '/budgets';
  static const assistant = '/assistant';

  static Map<String, WidgetBuilder> get table => {
        root: (_) => const AuthGate(),
        history: (_) => const _Protected(child: TransactionHistoryScreen()),
        budgets: (_) => const _Protected(child: BudgetsScreen()),
        assistant: (_) => const _Protected(child: AiChatScreen()),
      };
}

// =============================================================================
// Theme: light & dark palettes and typography
// =============================================================================

abstract final class AppTheme {
  static const _seed = Color(0xFF0F2A4A); // Nisaab navy

  static TextTheme _typography(TextTheme base) => base.copyWith(
        headlineMedium: base.headlineMedium?.copyWith(letterSpacing: -0.5),
        headlineSmall: base.headlineSmall?.copyWith(letterSpacing: -0.3),
        titleLarge: base.titleLarge?.copyWith(letterSpacing: -0.2),
        bodyMedium: base.bodyMedium?.copyWith(height: 1.35),
      );

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
      primary: isDark ? const Color(0xFF9CC3F5) : _seed,
      secondary: isDark ? const Color(0xFF5FD08E) : const Color(0xFF1E8A4C),
      error: isDark ? const Color(0xFFFF7B7B) : const Color(0xFFC53030),
      surface: isDark ? const Color(0xFF18212D) : Colors.white,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
    final scaffold = isDark ? const Color(0xFF0F161F) : const Color(0xFFF4F6FA);

    return base.copyWith(
      scaffoldBackgroundColor: scaffold,
      textTheme: _typography(base.textTheme),
      extensions: [isDark ? NisaabPalette.dark : NisaabPalette.light],
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isDark ? const Color(0xFF223246) : const Color(0xFFE6ECF3)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1D2836) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? const Color(0xFF2C3D52) : const Color(0xFFD5DDE8)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF141C27) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 68,
      ),
      chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? const Color(0xFF18212D) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
    );
  }

  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);
}

// =============================================================================
// App
// =============================================================================

class NisaabApp extends ConsumerWidget {
  const NisaabApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Nisaab AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ref.watch(themeModeProvider),
      initialRoute: AppRoutes.root,
      routes: AppRoutes.table,
      onUnknownRoute: (_) => MaterialPageRoute(builder: (_) => const AuthGate()),
    );
  }
}

/// Shows login, the signed-in shell, or a startup error depending on the session.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return session.when(
      skipLoadingOnRefresh: false,
      loading: () => const _Splash(),
      error: (e, _) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ErrorView(message: e.toString(), onRetry: () => ref.invalidate(sessionProvider)),
                TextButton(
                  onPressed: () => ref.read(sessionProvider.notifier).logout(),
                  child: const Text('Log out'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (user) => user == null
          ? const LoginScreen()
          : user.termsRequired
              ? const ConsentScreen()
              : const HomeShell(),
    );
  }
}

/// Full-page routes require a session; otherwise fall back to the gate.
class _Protected extends ConsumerWidget {
  const _Protected({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(currentUserProvider) == null ? const AuthGate() : child;
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [context.palette.heroStart, context.palette.heroEnd]),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.bar_chart_rounded, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 20),
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          ],
        ),
      ),
    );
  }
}
