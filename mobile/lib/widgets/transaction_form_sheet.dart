import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/categories.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../providers/core_providers.dart';
import '../services/api_service.dart';

/// Review an AI-parsed transaction (pass [parsed]) or add one manually (null).
/// Resolves to the saved [Transaction], or null if dismissed.
Future<Transaction?> showTransactionFormSheet(BuildContext context, {ParsedTransaction? parsed}) {
  return showModalBottomSheet<Transaction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => TransactionFormSheet(parsed: parsed),
  );
}

class TransactionFormSheet extends ConsumerStatefulWidget {
  const TransactionFormSheet({super.key, this.parsed});

  final ParsedTransaction? parsed;

  @override
  ConsumerState<TransactionFormSheet> createState() => _TransactionFormSheetState();
}

class _TransactionFormSheetState extends ConsumerState<TransactionFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _description;
  late String _type;
  late String _category;
  late DateTime _date;
  bool _saving = false;
  String? _error;

  ParsedTransaction? get _parsed => widget.parsed;

  @override
  void initState() {
    super.initState();
    final p = _parsed;
    _amount = TextEditingController(text: p?.amount == null ? '' : NumberFormat('#,##0.##', 'en_US').format(p!.amount!));
    _merchant = TextEditingController(text: p?.merchant ?? '');
    _description = TextEditingController(text: p?.description ?? '');
    _type = p?.type ?? 'expense';
    _category = p?.category ?? 'Other';
    _date = p?.transactionDate ?? DateTime.now();
    if (!categoriesFor(_type).contains(_category)) _category = 'Other';
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _description.dispose();
    super.dispose();
  }

  bool _wasCorrected() {
    final p = _parsed;
    if (p == null) return false;
    return p.amount != parseAmount(_amount.text) ||
        p.type != _type ||
        p.category != _category ||
        (p.merchant ?? '') != _merchant.text.trim() ||
        !DateUtils.isSameDay(p.transactionDate, _date);
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final p = _parsed;
    try {
      final saved = await ref.read(apiServiceProvider).createTransaction(TransactionDraft(
            amount: parseAmount(_amount.text)!,
            currency: p?.currency ?? 'PKR',
            type: _type,
            category: _category,
            merchant: _merchant.text,
            description: _description.text,
            rawText: p?.rawText,
            source: p?.source ?? 'manual',
            aiConfidence: p?.confidence,
            userCorrected: _wasCorrected(),
            transactionDate: _date,
          ));
      if (mounted) Navigator.of(context).pop(saved);
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
              Text(_parsed == null ? 'Add transaction' : 'Review transaction',
                  style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              if (_parsed != null) ...[_AiPreviewBanner(parsed: _parsed!), const SizedBox(height: 16)],
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'expense', label: Text('Expense'), icon: Icon(Icons.north_east)),
                  ButtonSegment(value: 'income', label: Text('Income'), icon: Icon(Icons.south_west)),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() {
                  _type = s.first;
                  if (!categoriesFor(_type).contains(_category)) {
                    _category = _type == 'income' ? 'Salary' : 'Other';
                  }
                }),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amount,
                autofocus: _parsed?.amount == null,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                decoration: InputDecoration(labelText: 'Amount', prefixText: '${_parsed?.currency == 'PKR' || _parsed == null ? 'Rs' : _parsed!.currency}  '),
                validator: (v) {
                  final value = parseAmount(v ?? '');
                  if (value == null) return 'Enter an amount';
                  if (value <= 0) return 'Amount must be greater than zero';
                  if (value >= 1e12) return 'Amount is too large';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              CategoryDropdown(
                value: _category,
                options: categoriesFor(_type),
                onChanged: (c) => setState(() => _category = c),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _merchant,
                textCapitalization: TextCapitalization.words,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: _type == 'income' ? 'From (optional)' : 'Merchant (optional)',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                maxLength: 255,
                decoration: const InputDecoration(labelText: 'Note (optional)', counterText: ''),
              ),
              const SizedBox(height: 12),
              DateField(date: _date, onTap: _pickDate),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: context.palette.critical)),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_saving ? 'Saving…' : 'Save transaction'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Category picker with coloured icons. Uses DropdownButton inside an InputDecorator so it
/// works across Flutter versions without deprecated form-field parameters.
class CategoryDropdown extends StatelessWidget {
  const CategoryDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.label = 'Category',
  });

  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final current = options.contains(value) ? value : options.first;
    return InputDecorator(
      decoration: InputDecoration(labelText: label, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          isExpanded: true,
          items: [
            for (final c in options)
              DropdownMenuItem(
                value: c,
                child: Row(
                  children: [
                    Icon(CategoryStyle.of(c).icon, size: 20, color: CategoryStyle.of(c).color),
                    const SizedBox(width: 10),
                    Flexible(child: Text(c, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class DateField extends StatelessWidget {
  const DateField({super.key, required this.date, required this.onTap});

  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Date',
          suffixIcon: Icon(Icons.calendar_today_outlined, size: 20),
        ),
        child: Text(DateFormat('EEE, d MMM yyyy').format(date)),
      ),
    );
  }
}

class _AiPreviewBanner extends StatelessWidget {
  const _AiPreviewBanner({required this.parsed});

  final ParsedTransaction parsed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pct = (parsed.confidence * 100).round();
    final (Color color, String label) = parsed.confidence >= 0.8
        ? (palette.good, 'Looks right')
        : parsed.confidence >= 0.5
            ? (palette.warning, 'Please double-check')
            : (palette.critical, 'Needs your input');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text('AI preview · $label', style: TextStyle(fontWeight: FontWeight.w600, color: color))),
              Text('$pct%', style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ],
          ),
          const SizedBox(height: 6),
          Text('“${parsed.rawText}”', style: TextStyle(fontStyle: FontStyle.italic, color: palette.muted)),
          if (parsed.learnedFromUser) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.school_outlined, size: 16, color: palette.muted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text('Category learned from your earlier edits',
                      overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: palette.muted)),
                ),
              ],
            ),
          ],
          if (parsed.missingFields.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Couldn’t find: ${parsed.missingFields.join(', ')}',
                style: TextStyle(fontSize: 13, color: palette.muted)),
          ],
        ],
      ),
    );
  }
}
