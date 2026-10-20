import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../providers/core_providers.dart';
import '../providers/dashboard_provider.dart';
import '../providers/session_provider.dart';
import '../services/api_service.dart';
import '../widgets/category_bars.dart';
import '../widgets/common.dart';
import '../widgets/nl_input_bar.dart';
import '../widgets/transaction_form_sheet.dart';
import '../widgets/transaction_tile.dart';
import 'home_shell.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _parsing = false;

  Future<bool> _handleInput(String text, String source) async {
    setState(() => _parsing = true);
    try {
      final parsed = await ref.read(apiServiceProvider).parseTransaction(text, source: source);
      if (!mounted) return true;
      setState(() => _parsing = false);
      await _openSheet(parsed);
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _parsing = false);
        showSnack(context, e.message, error: true);
      }
      return false;
    }
  }

  Future<void> _openSheet([ParsedTransaction? parsed]) async {
    final saved = await showTransactionFormSheet(context, parsed: parsed);
    if (saved != null && mounted) {
      showSnack(context, 'Saved ${formatPkr(saved.amount)} · ${saved.category}');
      refreshFinancialData(ref);
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(forecastProvider);
    ref.invalidate(dashboardProvider);
    try {
      await ref.read(dashboardProvider.future);
    } catch (_) {
      // The error is rendered by dashboard.when(error: ...).
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final dashboard = ref.watch(dashboardProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Assalam-o-Alaikum${user == null ? '' : ', ${user.firstName}'}',
                style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            Text(formatMonth(DateTime.now().year, DateTime.now().month),
                style: TextStyle(fontSize: 13, color: context.palette.muted)),
          ],
        ),
        toolbarHeight: 68,
        actions: const [ProfileButton()],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: dashboard.when(
                skipLoadingOnRefresh: true,
                skipLoadingOnReload: true,
                loading: () => const LoadingList(),
                error: (e, _) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [ErrorView(message: e.toString(), onRetry: () => _refresh())],
                ),
                data: (data) => _DashboardBody(data: data, onAdd: () => _openSheet()),
              ),
            ),
          ),
          NlInputBar(busy: _parsing, onSubmit: _handleInput, onManualAdd: () => _openSheet()),
        ],
      ),
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  const _DashboardBody({required this.data, required this.onAdd});

  final DashboardData data;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = data.summary;
    final forecast = data.forecast;
    final alerts = forecast.categories.where((c) => c.isAlert).toList();
    final critical = alerts.any((c) => c.risk == 'exceeded' || c.risk == 'likely_over');

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        _SummaryCard(summary: summary),
        const SizedBox(height: 12),
        _QuickStats(summary: summary, forecast: forecast),
        if (alerts.isNotEmpty) ...[
          const SizedBox(height: 12),
          AlertBanner(messages: alerts.take(2).map((c) => c.message).toList(), critical: critical),
        ],
        SectionHeader(
          'Where your money went',
          action: summary.budgets.isEmpty ? null : 'Budgets',
          onAction: () => ref.read(homeTabProvider.notifier).state = 2,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: CategoryBars(data: summary.byCategory),
          ),
        ),
        SectionHeader('Recent transactions', action: 'See all', onAction: () => ref.read(homeTabProvider.notifier).state = 1),
        if (data.recent.isEmpty)
          Card(
            child: EmptyState(
              icon: Icons.chat_bubble_outline,
              title: 'No transactions yet',
              message: 'Type or say something like “Spent 500 on chai” below.',
              action: OutlinedButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add manually')),
            ),
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < data.recent.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
                  TransactionTile(transaction: data.recent[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MonthlySummary summary;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final positive = summary.netSavings >= 0;
    final change = summary.expenseChangePct;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [palette.heroStart, palette.heroEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Net savings this month', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text(
            formatPkr(summary.netSavings),
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            summary.totalIncome > 0
                ? 'You kept ${summary.savingsRate.toStringAsFixed(0)}% of your income'
                : 'Add your income to see your savings rate',
            style: TextStyle(color: positive ? const Color(0xFFA6E9C2) : const Color(0xFFFFC2C2)),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _Flow(label: 'Income', amount: summary.totalIncome, icon: Icons.south_west)),
              Container(width: 1, height: 36, color: Colors.white24),
              const SizedBox(width: 16),
              Expanded(
                child: _Flow(
                  label: change == null
                      ? 'Spent'
                      : 'Spent (${change >= 0 ? '+' : ''}${change.toStringAsFixed(0)}% vs last month)',
                  amount: summary.totalExpense,
                  icon: Icons.north_east,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Flow extends StatelessWidget {
  const _Flow({required this.label, required this.amount, required this.icon});

  final String label;
  final double amount;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text(formatPkr(amount, compact: true),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuickStats extends StatelessWidget {
  const _QuickStats({required this.summary, required this.forecast});

  final MonthlySummary summary;
  final Forecast forecast;

  @override
  Widget build(BuildContext context) {
    final days = forecast.daysElapsed <= 0 ? 1 : forecast.daysElapsed;
    final dailyAvg = summary.totalExpense / days;
    return Row(
      children: [
        Expanded(child: _StatTile(icon: Icons.receipt_long_outlined, label: 'Entries', value: '${summary.transactionCount}')),
        const SizedBox(width: 10),
        Expanded(child: _StatTile(icon: Icons.today_outlined, label: 'Daily avg', value: formatPkr(dailyAvg, compact: true))),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.trending_up,
            label: 'Month-end',
            value: formatPkr(forecast.projectedTotalExpense, compact: true),
            tooltip: 'Projected spending by the end of the month at your current pace',
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.label, required this.value, this.tooltip});

  final IconData icon;
  final String label;
  final String value;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final tile = Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: context.colors.primary),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(fontSize: 12, color: context.palette.muted)),
            const SizedBox(height: 2),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip!, triggerMode: TooltipTriggerMode.tap, child: tile);
  }
}
