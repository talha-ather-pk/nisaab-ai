import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../core/categories.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../providers/core_providers.dart';
import '../providers/session_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/api_service.dart';
import '../widgets/common.dart';
import '../widgets/transaction_form_sheet.dart';
import '../widgets/transaction_tile.dart';
import 'home_shell.dart';

class TransactionHistoryScreen extends ConsumerStatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  ConsumerState<TransactionHistoryScreen> createState() => _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends ConsumerState<TransactionHistoryScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  int? _editingId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        ref.read(transactionsProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  TransactionsNotifier get _notifier => ref.read(transactionsProvider.notifier);

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _notifier.setFilter(ref.read(transactionsProvider).filter.copyWith(search: value.trim()));
    });
  }

  Future<void> _pickRange(TransactionFilter filter) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: filter.range ?? DateTimeRange(start: DateTime(now.year, now.month), end: now),
    );
    if (range != null) _notifier.setFilter(filter.copyWith(range: range));
  }

  Future<void> _pickCategory(TransactionFilter filter) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.clear_all),
            title: const Text('All categories'),
            onTap: () => Navigator.pop(context, ''),
          ),
          for (final c in kAllCategories)
            ListTile(
              leading: CategoryAvatar(c, radius: 16),
              title: Text(c),
              trailing: filter.category == c ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, c),
            ),
        ],
      ),
    );
    if (picked == null) return;
    _notifier.setFilter(picked.isEmpty ? filter.copyWith(clearCategory: true) : filter.copyWith(category: picked));
  }

  Future<bool> _confirmDelete(Transaction t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete transaction?'),
        content: Text('${t.title} · ${formatPkr(t.amount)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      await _notifier.deleteTransaction(t.id);
      if (mounted) showSnack(context, 'Transaction deleted');
      return true;
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
      return false;
    }
  }

  Future<void> _addManual() async {
    final saved = await showTransactionFormSheet(context);
    if (saved != null) {
      _notifier.refresh();
      if (mounted) showSnack(context, 'Saved ${formatPkr(saved.amount)} · ${saved.category}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transactionsProvider);
    final filter = state.filter;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: const [_ExportButton(), ProfileButton()],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(116),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _search,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search merchant, note or category',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              _onSearchChanged('');
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final (value, label) in const [(null, 'All'), ('expense', 'Expenses'), ('income', 'Income')])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: filter.type == value,
                          onSelected: (_) => _notifier.setFilter(
                              value == null ? filter.copyWith(clearType: true) : filter.copyWith(type: value)),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: const Icon(Icons.category_outlined, size: 18),
                        label: Text(filter.category ?? 'Category'),
                        selected: filter.category != null,
                        onSelected: (_) => _pickCategory(filter),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: const Icon(Icons.date_range, size: 18),
                        label: Text(filter.range == null
                            ? 'Any date'
                            : '${DateFormat('d MMM').format(filter.range!.start)} – ${DateFormat('d MMM').format(filter.range!.end)}'),
                        selected: filter.range != null,
                        onSelected: (_) => _pickRange(filter),
                      ),
                    ),
                    if (filter.isActive)
                      ActionChip(
                        avatar: const Icon(Icons.filter_alt_off_outlined, size: 18),
                        label: const Text('Clear'),
                        onPressed: () {
                          _search.clear();
                          _notifier.setFilter(const TransactionFilter());
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add transaction',
        onPressed: _addManual,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(onRefresh: _notifier.refresh, child: _buildList(state)),
    );
  }

  Widget _buildList(TransactionListState state) {
    if (state.loading && state.items.isEmpty) return const LoadingList();
    if (state.error != null && state.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [ErrorView(message: state.error!, onRetry: _notifier.refresh)],
      );
    }
    if (state.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          EmptyState(
            icon: Icons.search_off,
            title: state.filter.isActive ? 'No matching transactions' : 'No transactions yet',
            message: state.filter.isActive ? 'Try a different search or clear the filters.' : 'Add one with the + button.',
          ),
        ],
      );
    }

    // Flatten into day headers + rows.
    final entries = <Object>[];
    DateTime? lastDay;
    for (final t in state.items) {
      final day = DateTime(t.transactionDate.year, t.transactionDate.month, t.transactionDate.day);
      if (lastDay == null || day != lastDay) {
        entries.add(day);
        lastDay = day;
      }
      entries.add(t);
    }

    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: entries.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _TotalsStrip(state: state);
        if (index == entries.length + 1) {
          if (state.loadingMore) {
            return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
          }
          if (!state.hasMore) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Center(child: Text('${state.total} transactions', style: TextStyle(color: context.palette.muted))),
            );
          }
          return const SizedBox(height: 40);
        }
        final entry = entries[index - 1];
        if (entry is DateTime) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(formatDayHeader(entry),
                style: context.text.labelLarge?.copyWith(color: context.palette.muted, fontWeight: FontWeight.w700)),
          );
        }
        final t = entry as Transaction;
        final editing = _editingId == t.id;
        return Dismissible(
          key: ValueKey('txn-${t.id}'),
          direction: editing ? DismissDirection.none : DismissDirection.endToStart,
          confirmDismiss: (_) => _confirmDelete(t),
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            color: context.palette.critical.withValues(alpha: 0.12),
            child: Icon(Icons.delete_outline, color: context.palette.critical, semanticLabel: 'Delete'),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: editing
                ? _InlineEditor(
                    key: ValueKey('edit-${t.id}'),
                    transaction: t,
                    onDone: () => setState(() => _editingId = null),
                    onDelete: () async {
                      if (await _confirmDelete(t) && mounted) setState(() => _editingId = null);
                    },
                  )
                : TransactionTile(
                    transaction: t,
                    showDate: false,
                    onTap: () => setState(() => _editingId = t.id),
                  ),
          ),
        );
      },
    );
  }
}

class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.state});

  final TransactionListState state;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget cell(String label, double value, Color color) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: palette.muted)),
              const SizedBox(height: 2),
              Text(formatPkr(value, compact: true), style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              cell(state.filter.isActive ? 'Income (filtered)' : 'Total income', state.totalIncome, palette.income),
              cell(state.filter.isActive ? 'Spent (filtered)' : 'Total spent', state.totalExpense, palette.expense),
              cell('Net', state.totalIncome - state.totalExpense,
                  state.totalIncome >= state.totalExpense ? palette.income : palette.critical),
            ],
          ),
        ),
      ),
    );
  }
}

/// Edits a transaction in place (PATCH /transactions/{id}).
class _InlineEditor extends ConsumerStatefulWidget {
  const _InlineEditor({super.key, required this.transaction, required this.onDone, required this.onDelete});

  final Transaction transaction;
  final VoidCallback onDone;
  final VoidCallback onDelete;

  @override
  ConsumerState<_InlineEditor> createState() => _InlineEditorState();
}

class _InlineEditorState extends ConsumerState<_InlineEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _description;
  late String _type;
  late String _category;
  late DateTime _date;
  bool _saving = false;
  String? _error;

  Transaction get t => widget.transaction;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: NumberFormat('#,##0.##', 'en_US').format(t.amount));
    _merchant = TextEditingController(text: t.merchant ?? '');
    _description = TextEditingController(text: t.description ?? '');
    _type = t.type;
    _category = t.category;
    _date = t.transactionDate;
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _description.dispose();
    super.dispose();
  }

  Map<String, dynamic> _changes() {
    final changes = <String, dynamic>{};
    final amount = parseAmount(_amount.text);
    if (amount != null && amount != t.amount) changes['amount'] = amount;
    if (_type != t.type) changes['type'] = _type;
    if (_category != t.category) changes['category'] = _category;
    if (_merchant.text.trim() != (t.merchant ?? '')) changes['merchant'] = _merchant.text.trim();
    if (_description.text.trim() != (t.description ?? '')) changes['description'] = _description.text.trim();
    if (!DateUtils.isSameDay(_date, t.transactionDate)) changes['transaction_date'] = isoDate(_date);
    return changes;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final changes = _changes();
    if (changes.isEmpty) return widget.onDone();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(transactionsProvider.notifier).updateTransaction(t.id, changes);
      if (mounted) {
        showSnack(context, 'Transaction updated');
        widget.onDone();
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: context.colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CategoryAvatar(_category, radius: 16),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Edit transaction', style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                  IconButton(tooltip: 'Delete', onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline)),
                ],
              ),
              if (t.rawText != null && t.rawText!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('“${t.rawText}”',
                      style: TextStyle(fontStyle: FontStyle.italic, color: context.palette.muted, fontSize: 13)),
                ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'expense', label: Text('Expense')),
                  ButtonSegment(value: 'income', label: Text('Income')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() {
                  _type = s.first;
                  if (!categoriesFor(_type).contains(_category)) _category = _type == 'income' ? 'Salary' : 'Other';
                }),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Amount', prefixText: 'Rs  ', isDense: true),
                      validator: (v) => (parseAmount(v ?? '') ?? 0) <= 0 ? 'Enter an amount' : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: CategoryDropdown(
                      value: _category,
                      options: categoriesFor(_type),
                      onChanged: (c) => setState(() => _category = c),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _merchant,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Merchant', isDense: true, counterText: ''),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _description,
                maxLength: 255,
                decoration: const InputDecoration(labelText: 'Note', isDense: true, counterText: ''),
              ),
              const SizedBox(height: 10),
              DateField(date: _date, onTap: _pickDate),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: context.palette.critical)),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _saving ? null : widget.onDone, child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Downloads every transaction as a CSV (US-22). Mobile opens the share sheet; browsers download the file.
class _ExportButton extends ConsumerStatefulWidget {
  const _ExportButton();

  @override
  ConsumerState<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends ConsumerState<_ExportButton> {
  bool _busy = false;

  Future<void> _export() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await ref.read(apiServiceProvider).exportTransactionsCsv(user.id);
      final name = 'nisaab-transactions-${isoDate(DateTime.now())}.csv';
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'text/csv', name: name)],
        fileNameOverrides: [name],
        subject: 'Nisaab transactions',
      ));
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not export your transactions.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Export to CSV',
      onPressed: _busy ? null : _export,
      icon: _busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.file_download_outlined),
    );
  }
}
