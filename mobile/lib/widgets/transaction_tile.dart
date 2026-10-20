import 'package:flutter/material.dart';

import '../core/categories.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../models/models.dart';

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar(this.category, {super.key, this.radius = 22});

  final String category;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final style = CategoryStyle.of(category);
    return CircleAvatar(
      radius: radius,
      backgroundColor: style.color.withValues(alpha: 0.14),
      child: Icon(style.icon, color: style.color, size: radius),
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.transaction, this.onTap, this.showDate = true, this.trailing});

  final Transaction transaction;
  final VoidCallback? onTap;
  final bool showDate;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final sourceIcon = switch (t.source) {
      'voice' => Icons.mic_none,
      'sms' => Icons.sms_outlined,
      'text' => Icons.auto_awesome,
      _ => null,
    };
    final subtitle = showDate ? '${t.category} · ${formatShortDate(t.transactionDate)}' : t.category;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: CategoryAvatar(t.category),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Row(
        children: [
          Flexible(child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (sourceIcon != null) ...[
            const SizedBox(width: 6),
            Icon(sourceIcon, size: 14, color: context.palette.muted, semanticLabel: 'Added by ${t.source}'),
          ],
        ],
      ),
      trailing: trailing ??
          Text(
            formatPkr(t.signedAmount, signed: true),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: t.isIncome ? context.palette.income : context.palette.expense,
            ),
          ),
    );
  }
}
