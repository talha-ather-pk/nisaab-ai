import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../providers/goals_provider.dart';
import '../services/api_service.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  Future<void> _openForm(BuildContext context, {SavingsGoal? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _GoalFormSheet(existing: existing),
    );
    if (saved == true && context.mounted) showSnack(context, existing == null ? 'Goal added' : 'Goal updated');
  }

  Future<void> _contribute(BuildContext context, SavingsGoal goal, {required bool withdraw}) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ContributionDialog(goal: goal, withdraw: withdraw),
    );
    if (done == true && context.mounted) showSnack(context, withdraw ? 'Withdrawal recorded' : 'Savings added');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, SavingsGoal goal) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${goal.name}”?'),
        content: const Text('Your transactions are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(goalsProvider.notifier).delete(goal.id);
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Savings goals', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: const [ProfileButton()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Add goal'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(goalsProvider.future).then((_) {}, onError: (_) {}),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: goals.when(
            skipLoadingOnRefresh: true,
            loading: () => const [SizedBox(height: 160), Center(child: CircularProgressIndicator())],
            error: (e, _) => [ErrorView(message: e.toString(), onRetry: () => ref.invalidate(goalsProvider))],
            data: (items) => items.isEmpty
                ? [
                    EmptyState(
                      icon: Icons.flag_outlined,
                      title: 'No savings goals yet',
                      message: 'Save towards something specific, like “Laptop: Rs 150,000 by June”. '
                          'Nisaab tells you how much to put aside each month.',
                      action: FilledButton.icon(
                        onPressed: () => _openForm(context),
                        icon: const Icon(Icons.add),
                        label: const Text('Create a goal'),
                      ),
                    ),
                  ]
                : [
                    _TotalsCard(goals: items),
                    const SectionHeader('Your goals'),
                    for (final g in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _GoalCard(
                          goal: g,
                          onAdd: () => _contribute(context, g, withdraw: false),
                          onWithdraw: () => _contribute(context, g, withdraw: true),
                          onEdit: () => _openForm(context, existing: g),
                          onDelete: () => _delete(context, ref, g),
                        ),
                      ),
                  ],
          ),
        ),
      ),
    );
  }
}

(Color, IconData, String) _statusStyle(BuildContext context, String status) {
  final p = context.palette;
  return switch (status) {
    'completed' => (p.good, Icons.emoji_events_outlined, 'Completed'),
    'on_track' => (p.good, Icons.check_circle_outline, 'On track'),
    'behind' => (p.warning, Icons.schedule, 'Behind schedule'),
    'overdue' => (p.critical, Icons.error_outline, 'Past target date'),
    _ => (p.muted, Icons.flag_outlined, 'No deadline'),
  };
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.goals});

  final List<SavingsGoal> goals;

  @override
  Widget build(BuildContext context) {
    final active = goals.where((g) => !g.isCompleted).toList();
    final saved = active.fold<double>(0, (s, g) => s + g.savedAmount);
    final target = active.fold<double>(0, (s, g) => s + g.targetAmount);
    final monthly = active.fold<double>(0, (s, g) => s + (g.monthlyNeeded ?? 0));
    final done = goals.length - active.length;
    final palette = context.palette;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Saved across active goals', style: TextStyle(color: palette.muted)),
            const SizedBox(height: 4),
            Text('${formatPkr(saved)} of ${formatPkr(target)}',
                style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            BudgetBar(percent: target == 0 ? 100 : saved / target * 100, status: 'ok', height: 10),
            const SizedBox(height: 8),
            Text(
              [
                if (monthly > 0) 'Put aside ${formatPkr(monthly)}/month to stay on schedule',
                if (done > 0) '$done completed',
              ].join(' · ').ifEmpty('Every goal is complete. Nice work!'),
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.onAdd,
    required this.onWithdraw,
    required this.onEdit,
    required this.onDelete,
  });

  final SavingsGoal goal;
  final VoidCallback onAdd;
  final VoidCallback onWithdraw;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String _plan() {
    final g = goal;
    final by = g.targetDate == null ? null : DateFormat('MMM yyyy').format(g.targetDate!);
    return switch (g.status) {
      'completed' => 'Target reached',
      'overdue' => '${formatPkr(g.remaining)} still to go (target was $by)',
      'no_deadline' => '${formatPkr(g.remaining)} to go',
      _ => 'Save ${formatPkr(g.monthlyNeeded ?? g.remaining)}/month to reach it by $by',
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (color, icon, label) = _statusStyle(context, goal.status);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: color.withValues(alpha: 0.12),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(goal.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatPkr(goal.savedAmount), style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('of ${formatPkr(goal.targetAmount)}', style: TextStyle(color: palette.muted, fontSize: 12)),
                    ],
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Goal options',
                    onSelected: (v) => switch (v) {
                      'withdraw' => onWithdraw(),
                      'edit' => onEdit(),
                      _ => onDelete(),
                    },
                    itemBuilder: (_) => [
                      if (goal.savedAmount > 0) const PopupMenuItem(value: 'withdraw', child: Text('Withdraw')),
                      const PopupMenuItem(value: 'edit', child: Text('Edit goal')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete goal')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: BudgetBar(percent: goal.percent, status: goal.status == 'behind' ? 'warning' : 'ok'),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${goal.percent.toStringAsFixed(0)}% · ${_plan()}',
                          style: TextStyle(color: palette.muted, fontSize: 13)),
                    ),
                    if (!goal.isCompleted)
                      TextButton.icon(
                        onPressed: onAdd,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalFormSheet extends ConsumerStatefulWidget {
  const _GoalFormSheet({required this.existing});

  final SavingsGoal? existing;

  @override
  ConsumerState<_GoalFormSheet> createState() => _GoalFormSheetState();
}

class _GoalFormSheetState extends ConsumerState<_GoalFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _target;
  DateTime? _targetDate;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _target = TextEditingController(text: e == null ? '' : e.targetAmount.toStringAsFixed(0));
    _targetDate = e?.targetDate;
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _targetDate ?? DateTime(now.year, now.month + 6, now.day),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 20),
      helpText: 'Reach this goal by',
    );
    if (picked != null) setState(() => _targetDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final notifier = ref.read(goalsProvider.notifier);
    final name = _name.text.trim();
    final target = parseAmount(_target.text)!;
    try {
      final existing = widget.existing;
      if (existing == null) {
        await notifier.create(name: name, target: target, targetDate: _targetDate);
      } else {
        await notifier.edit(existing.id, {
          'name': name,
          'target_amount': target,
          'target_date': _targetDate == null ? null : isoDate(_targetDate!),
        });
      }
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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.existing == null ? 'New savings goal' : 'Edit goal',
                  style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: widget.existing == null,
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'What are you saving for?', hintText: 'e.g. New laptop'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Give your goal a name' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _target,
                keyboardType: TextInputType.number,
                style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                decoration: const InputDecoration(labelText: 'Target amount', prefixText: 'Rs  '),
                validator: (v) => (parseAmount(v ?? '') ?? 0) <= 0 ? 'Enter an amount above zero' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event_outlined),
                      label: Text(_targetDate == null
                          ? 'Add a target date (optional)'
                          : 'By ${DateFormat('d MMM yyyy').format(_targetDate!)}',
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  if (_targetDate != null)
                    IconButton(
                      tooltip: 'Remove target date',
                      onPressed: () => setState(() => _targetDate = null),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: context.palette.critical)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save goal'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContributionDialog extends ConsumerStatefulWidget {
  const _ContributionDialog({required this.goal, required this.withdraw});

  final SavingsGoal goal;
  final bool withdraw;

  @override
  ConsumerState<_ContributionDialog> createState() => _ContributionDialogState();
}

class _ContributionDialogState extends ConsumerState<_ContributionDialog> {
  final _amount = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount above zero');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(goalsProvider.notifier).contribute(widget.goal.id, widget.withdraw ? -amount : amount);
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
    final g = widget.goal;
    return AlertDialog(
      title: Text(widget.withdraw ? 'Withdraw from ${g.name}' : 'Add to ${g.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'Amount', prefixText: 'Rs  ', errorText: _error),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Text(
            widget.withdraw
                ? 'Saved so far: ${formatPkr(g.savedAmount)}'
                : 'Still to go: ${formatPkr(g.remaining)}',
            style: TextStyle(color: context.palette.muted, fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(widget.withdraw ? 'Withdraw' : 'Add savings'),
        ),
      ],
    );
  }
}
