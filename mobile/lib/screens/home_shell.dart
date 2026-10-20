import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../providers/core_providers.dart';
import '../providers/session_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/consent.dart';
import 'ai_chat_screen.dart';
import 'budgets_screen.dart';
import 'dashboard_screen.dart';
import 'goals_screen.dart';
import 'transaction_history_screen.dart';

/// Signed-in root: bottom navigation across the five main screens.
/// IndexedStack keeps each tab's scroll position and state.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
    NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'History'),
    NavigationDestination(icon: Icon(Icons.savings_outlined), selectedIcon: Icon(Icons.savings), label: 'Budgets'),
    NavigationDestination(icon: Icon(Icons.flag_outlined), selectedIcon: Icon(Icons.flag), label: 'Goals'),
    NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'Assistant'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(homeTabProvider);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const [
          DashboardScreen(),
          TransactionHistoryScreen(),
          BudgetsScreen(),
          GoalsScreen(),
          AiChatScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => ref.read(homeTabProvider.notifier).state = i,
        destinations: _destinations,
      ),
    );
  }
}

/// Avatar button used in every tab's app bar; opens the profile & settings sheet.
class ProfileButton extends ConsumerWidget {
  const ProfileButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: IconButton(
        tooltip: 'Profile & settings',
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          useSafeArea: true,
          builder: (_) => const _ProfileSheet(),
        ),
        icon: CircleAvatar(
          radius: 17,
          backgroundColor: context.colors.primaryContainer,
          child: Text(user?.initials ?? '?',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: context.colors.onPrimaryContainer)),
        ),
      ),
    );
  }
}

class _ProfileSheet extends ConsumerWidget {
  const _ProfileSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final mode = ref.watch(themeModeProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(child: Text(user?.initials ?? '?')),
            title: Text(user?.fullName ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(user?.email ?? ''),
          ),
          if (user?.monthlyIncome != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Declared monthly income: ${formatPkr(user!.monthlyIncome!)}',
                  style: TextStyle(color: context.palette.muted)),
            ),
          const SizedBox(height: 8),
          Text('Appearance', style: context.text.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {mode},
            onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
          ),
          const SizedBox(height: 20),
          const AccountPrivacySection(),
          const SizedBox(height: 16),
          Text('Server: ${AppConfig.apiBaseUrl}', style: TextStyle(color: context.palette.muted, fontSize: 12)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(homeTabProvider.notifier).state = 0;
              ref.read(sessionProvider.notifier).logout();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
        ],
      ),
    );
  }
}
