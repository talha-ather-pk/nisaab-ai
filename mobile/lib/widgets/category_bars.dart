import 'package:flutter/material.dart';

import '../core/categories.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';

/// Category spending distribution as ranked horizontal bars.
///
/// One hue encodes magnitude; category identity comes from the icon + label, and every
/// bar carries its value and share as text, so nothing relies on colour alone. Beyond
/// [maxRows] the long tail folds into "Other". Tap a row for a tooltip with the count.
class CategoryBars extends StatelessWidget {
  const CategoryBars({super.key, required this.data, this.maxRows = 5});

  final List<CategorySpend> data;
  final int maxRows;

  List<CategorySpend> _rows() {
    final sorted = [...data]..sort((a, b) => b.amount.compareTo(a.amount));
    if (sorted.length <= maxRows) return sorted;
    final head = sorted.take(maxRows - 1).toList();
    final tail = sorted.skip(maxRows - 1);
    final otherAmount = tail.fold<double>(0, (s, c) => s + c.amount);
    final otherShare = tail.fold<double>(0, (s, c) => s + c.share);
    final otherCount = tail.fold<int>(0, (s, c) => s + c.transactionCount);
    return [...head, CategorySpend('Other', otherAmount, otherShare, otherCount)];
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('No spending recorded this month yet.', style: TextStyle(color: context.palette.muted)),
      );
    }
    final max = rows.first.amount <= 0 ? 1.0 : rows.first.amount;
    return Column(
      children: [for (final row in rows) _BarRow(row: row, fraction: row.amount / max)],
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.row, required this.fraction});

  final CategorySpend row;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final style = CategoryStyle.of(row.category);
    final palette = context.palette;
    final tooltip = '${row.category}: ${formatPkr(row.amount)} · ${row.share.toStringAsFixed(1)}% · '
        '${row.transactionCount} transaction${row.transactionCount == 1 ? '' : 's'}';

    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.tap,
      preferBelow: false,
      child: Semantics(
        label: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(style.icon, size: 18, color: style.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(row.category, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Text(formatPkr(row.amount, compact: true), style: const TextStyle(fontWeight: FontWeight.w700)),
                  SizedBox(
                    width: 48,
                    child: Text('${row.share.toStringAsFixed(0)}%',
                        textAlign: TextAlign.right, style: TextStyle(color: palette.muted, fontSize: 13)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LayoutBuilder(
                builder: (context, constraints) => Stack(
                  children: [
                    Container(
                      height: 8,
                      width: constraints.maxWidth,
                      decoration: BoxDecoration(color: palette.chartTrack, borderRadius: BorderRadius.circular(4)),
                    ),
                    Container(
                      height: 8,
                      width: (constraints.maxWidth * fraction.clamp(0.0, 1.0)).clamp(4.0, constraints.maxWidth),
                      decoration: BoxDecoration(color: palette.chartBar, borderRadius: BorderRadius.circular(4)),
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
