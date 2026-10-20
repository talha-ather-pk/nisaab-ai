import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'core_providers.dart';
import 'dashboard_provider.dart';
import 'session_provider.dart';

DateTime _thisMonth() {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
}

/// Month shown on the Budgets screen (always the 1st of the month).
final budgetMonthProvider = StateProvider<DateTime>((ref) => _thisMonth());

class BudgetsNotifier extends AsyncNotifier<List<Budget>> {
  @override
  Future<List<Budget>> build() async {
    final user = requireUser(ref);
    final month = ref.watch(budgetMonthProvider);
    final budgets = await ref.watch(apiServiceProvider).getBudgets(user.id, month: month.month, year: month.year);
    budgets.sort((a, b) => b.percentUsed.compareTo(a.percentUsed));
    return budgets;
  }

  /// Create or update. Throws [ApiException] so the form can show it.
  Future<void> save({required String category, required double limit, int alertThreshold = 80}) async {
    final month = ref.read(budgetMonthProvider);
    await ref.read(apiServiceProvider).upsertBudget(
          category: category,
          monthlyLimit: limit,
          month: month.month,
          year: month.year,
          alertThreshold: alertThreshold,
        );
    _afterChange();
  }

  Future<void> delete(int budgetId) async {
    await ref.read(apiServiceProvider).deleteBudget(budgetId);
    _afterChange();
  }

  void _afterChange() {
    ref.invalidateSelf();
    ref.invalidate(forecastProvider);
    ref.invalidate(dashboardProvider);
  }
}

final budgetsProvider = AsyncNotifierProvider<BudgetsNotifier, List<Budget>>(BudgetsNotifier.new);
