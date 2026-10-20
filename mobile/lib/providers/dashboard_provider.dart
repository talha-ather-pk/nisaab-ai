import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import 'budgets_provider.dart';
import 'core_providers.dart';
import 'session_provider.dart';
import 'transactions_provider.dart';

class DashboardData {
  final MonthlySummary summary;
  final List<Transaction> recent;
  final Forecast forecast;
  const DashboardData(this.summary, this.recent, this.forecast);
}

final forecastProvider = FutureProvider<Forecast>((ref) async {
  final user = requireUser(ref);
  return ref.watch(apiServiceProvider).getForecast(user.id);
});

final dashboardProvider = FutureProvider<DashboardData>((ref) async {
  final user = requireUser(ref);
  final api = ref.watch(apiServiceProvider);
  final results = await Future.wait<Object>([
    api.getSummary(user.id),
    api.getTransactions(user.id, const TransactionQuery(pageSize: 6)),
    ref.watch(forecastProvider.future),
  ]);
  return DashboardData(
    results[0] as MonthlySummary,
    (results[1] as TransactionPage).items,
    results[2] as Forecast,
  );
});

/// Call after any create/update/delete so every screen reflects the change.
void refreshFinancialData(WidgetRef ref) {
  ref.invalidate(forecastProvider);
  ref.invalidate(dashboardProvider);
  ref.invalidate(budgetsProvider);
  ref.read(transactionsProvider.notifier).refresh();
}
