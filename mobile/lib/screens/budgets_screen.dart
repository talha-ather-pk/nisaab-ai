import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/categories.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../providers/budgets_provider.dart';
import '../providers/dashboard_provider.dart';
import '../services/api_service.dart';
import '../widgets/common.dart';
import '../widgets/transaction_form_sheet.dart';
import '../widgets/transaction_tile.dart';
import 'home_shell.dart';

class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  bool _isCurrentMonth(DateTime month) {
    final now = DateTime.now();
    return month.year == now.year && month.month == now.month;
  }

  Future<void> _openForm(BuildContext context, WidgetRef ref, {Budget? existing, required List<Budget> budgets}) async {
    final forecast = ref.read(forecastProvider).valueOrNull;
    final taken = budgets.map((b) => b.category).toSet();
    final options = existing != null
        ? [existing.category]
        : kExpenseCategories.where((c) => !taken.contains(c)).toList();
    if (options.isEmpty) {
      showSnack(context, 'Every category already has a budget this month.');
      return;
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _BudgetFormSheet(existing: existing, categories: options, forecast: forecast),
    );
    if (saved == true && context.mounted) showSnack(context, existing == null ? 'Budget added' : 'Budget updated');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Budget budget) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${budget.category} budget?'),
        content: const Text('Your transactions are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(budgetsProvider.notifier).delete(budget.id);
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(budgetMonthProvider);
    final budgets = ref.watch(budgetsProvider);
    final isCurrent = _isCurrentMonth(month);
    final forecast = isCurrent ? ref.watch(forecastProvider).valueOrNull : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budgets', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: const [ProfileButton()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context, ref, budgets: budgets.valueOrNull ?? const []),
        icon: const Icon(Icons.add),
        label: const Text('Add budget'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(forecastProvider);
          return ref.refresh(budgetsProvider.future).then((_) {}, onError: (_) {});
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            _MonthSwitcher(
              month: month,
              canGoForward: !isCurrent,
              onChange: (m) => ref.read(budgetMonthProvider.notifier).state = m,
            ),
            ...budgets.when(
              skipLoadingOnRefresh: true,
              loading: () => const [SizedBox(height: 160), Center(child: CircularProgressIndicator())],
              error: (e, _) => [ErrorView(message: e.toString(), onRetry: () => ref.invalidate(budgetsProvider))],
              data: (items) => _content(context, ref, items, forecast, isCurrent),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, WidgetRef ref, List<Budget> items, Forecast? forecast, bool isCurrent) {
    if (items.isEmpty) {
      final recs = (forecast?.categories ?? const <CategoryForecast>[])
          .where((c) => c.recommendedBudget != null && c.monthlyLimit == null)
          .take(3)
          .toList();
      return [
        EmptyState(
          icon: Icons.savings_outlined,
          title: 'No budgets for this month',
          message: recs.isEmpty
              ? 'Set a monthly limit for a category and Nisaab will warn you before you overspend.'
              : 'Based on your history, try: ${recs.map((c) => '${c.category} ${formatPkr(c.recommendedBudget!)}').join(' · ')}',
          action: FilledButton.icon(
            onPressed: () => _openForm(context, ref, budgets: items),
            icon: const Icon(Icons.add),
            label: const Text('Create a budget'),
          ),
        ),
      ];
    }

    final totalLimit = items.fold<double>(0, (s, b) => s + b.monthlyLimit);
    final totalSpent = items.fold<double>(0, (s, b) => s + b.spent);
    final alerts = (forecast?.categories ?? const <CategoryForecast>[])
        .where((c) => c.monthlyLimit != null && c.isAlert)
        .toList();

    return [
      _OverallCard(limit: totalLimit, spent: totalSpent, forecast: forecast),
      if (alerts.isNotEmpty) ...[
        const SizedBox(height: 12),
        AlertBanner(
          messages: alerts.take(3).map((c) => c.message).toList(),
          critical: alerts.any((c) => c.risk == 'exceeded' || c.risk == 'likely_over'),
        ),
      ],
      const SectionHeader('By category'),
      for (final b in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _BudgetCard(
            budget: b,
            forecast: forecast?.forCategory(b.category),
            showProjection: isCurrent,
            onEdit: () => _openForm(context, ref, existing: b, budgets: items),
            onDelete: () => _delete(context, ref, b),
          ),
        ),
    ];
  }
}

class _MonthSwitcher extends StatelessWidget {
  const _MonthSwitcher({required this.month, required this.canGoForward, required this.onChange});

  final DateTime month;
  final bool canGoForward;
  final ValueChanged<DateTime> onChange;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous month',
            onPressed: () => onChange(DateTime(month.year, month.month - 1)),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(formatMonth(month.year, month.month),
                textAlign: TextAlign.center, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: 'Next month',
            onPressed: canGoForward ? () => onChange(DateTime(month.year, month.month + 1)) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class _OverallCard extends StatelessWidget {
  const _OverallCard({required this.limit, required this.spent, required this.forecast});

  final double limit;
  final double spent;
  final Forecast? forecast;

  @override
  Widget build(BuildContext context) {
    final pct = limit == 0 ? 0.0 : spent / limit * 100;
    final status = spent > limit ? 'exceeded' : (pct >= 80 ? 'warning' : 'ok');
    final palette = context.palette;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Total budgeted', style: TextStyle(color: palette.muted))),
                StatusLabel(status: status),
              ],
            ),
            const SizedBox(height: 4),
            Text('${formatPkr(spent)} of ${formatPkr(limit)}',
                style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            BudgetBar(percent: pct, status: status, height: 10),
            const SizedBox(height: 8),
            Text(
              spent > limit
                  ? '${formatPkr(spent - limit)} over across your budgets'
                  : '${formatPkr(limit - spent)} left · ${pct.toStringAsFixed(0)}% used'
                      '${forecast == null ? '' : ' · day ${forecast!.daysElapsed} of ${forecast!.daysInMonth}'}',
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.budget,
    required this.forecast,
    required this.showProjection,
    required this.onEdit,
    required this.onDelete,
  });

  final Budget budget;
  final CategoryForecast? forecast;
  final bool showProjection;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final b = budget;
    final f = forecast;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CategoryAvatar(b.category, radius: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.category, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        StatusLabel(status: b.status),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatPkr(b.spent), style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('of ${formatPkr(b.monthlyLimit)}', style: TextStyle(color: palette.muted, fontSize: 12)),
                    ],
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Budget options',
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit limit')),
                      PopupMenuItem(value: 'delete', child: Text('Remove budget')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: BudgetBar(percent: b.percentUsed, status: b.status),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  b.remaining >= 0
                      ? '${formatPkr(b.remaining)} left · ${b.percentUsed.toStringAsFixed(0)}% used'
                      : '${formatPkr(-b.remaining)} over budget',
                  style: TextStyle(color: palette.muted, fontSize: 13),
                ),
              ),
              if (showProjection && f != null) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Row(
                    children: [
                      Icon(Icons.trending_up, size: 15, color: palette.forRisk(f.risk)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Projected month-end: ${formatPkr(f.projectedMonthEnd)}'
                          '${f.projectedOverrun > 0 ? ' (${formatPkr(f.projectedOverrun)} over)' : ''}',
                          style: TextStyle(color: palette.forRisk(f.risk), fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BudgetFormSheet extends ConsumerStatefulWidget {
  const _BudgetFormSheet({required this.existing, required this.categories, required this.forecast});

  final Budget? existing;
  final List<String> categories;
  final Forecast? forecast;

  @override
  ConsumerState<_BudgetFormSheet> createState() => _BudgetFormSheetState();
}

class _BudgetFormSheetState extends ConsumerState<_BudgetFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _limit;
  late String _category;
  late double _threshold;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _category = e?.category ?? widget.categories.first;
    _threshold = (e?.alertThreshold ?? 80).toDouble();
    _limit = TextEditingController(text: e == null ? '' : e.monthlyLimit.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  double? get _recommended => widget.forecast?.forCategory(_category)?.recommendedBudget;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(budgetsProvider.notifier).save(
            category: _category,
            limit: parseAmount(_limit.text)!,
            alertThreshold: _threshold.round(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final recommended = _recommended;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.existing == null ? 'New budget' : 'Edit ${widget.existing!.category} budget',
                  style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              if (widget.existing == null) ...[
                CategoryDropdown(
                  value: _category,
                  options: widget.categories,
                  onChanged: (c) => setState(() => _category = c),
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _limit,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                decoration: const InputDecoration(labelText: 'Monthly limit', prefixText: 'Rs  '),
                validator: (v) => (parseAmount(v ?? '') ?? 0) <= 0 ? 'Enter a limit above zero' : null,
              ),
              if (recommended != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 16),
                    label: Text('Suggested from your history: ${formatPkr(recommended)}'),
                    onPressed: () => setState(() => _limit.text = recommended.toStringAsFixed(0)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Warn me at ${_threshold.round()}% of the limit', style: context.text.labelLarge),
              Slider(
                value: _threshold,
                min: 50,
                max: 100,
                divisions: 10,
                label: '${_threshold.round()}%',
                onChanged: (v) => setState(() => _threshold = v),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: context.palette.critical)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save budget'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
