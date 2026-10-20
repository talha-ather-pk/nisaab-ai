import 'package:flutter/material.dart';

import '../core/theme.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: context.palette.muted),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, textAlign: TextAlign.center, style: TextStyle(color: context.palette.muted)),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'Couldn’t load your data',
      message: message,
      action: FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
    );
  }
}

/// Pull-to-refresh friendly centred spinner.
class LoadingList extends StatelessWidget {
  const LoadingList({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [SizedBox(height: 220), Center(child: CircularProgressIndicator())],
    );
  }
}

/// Coloured status text with an icon. Status is never shown by colour alone.
class StatusLabel extends StatelessWidget {
  const StatusLabel({super.key, required this.status});

  final String status; // ok | warning | exceeded

  @override
  Widget build(BuildContext context) {
    final color = context.palette.forStatus(status);
    final (IconData icon, String label) = switch (status) {
      'exceeded' => (Icons.error_outline, 'Over budget'),
      'warning' => (Icons.warning_amber_rounded, 'Near limit'),
      _ => (Icons.check_circle_outline, 'On track'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

/// Thin rounded progress bar used for budgets.
class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.percent, required this.status, this.height = 8});

  final double percent;
  final String status;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.forStatus(status);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: LinearProgressIndicator(
        value: (percent / 100).clamp(0.0, 1.0),
        minHeight: height,
        color: color,
        backgroundColor: context.palette.chartTrack,
      ),
    );
  }
}

/// Banner for overspending / forecast alerts.
class AlertBanner extends StatelessWidget {
  const AlertBanner({super.key, required this.messages, this.critical = false});

  final List<String> messages;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    final color = critical ? context.palette.critical : context.palette.warning;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.notifications_active_outlined, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in messages)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(m, style: TextStyle(color: color, fontWeight: FontWeight.w600, height: 1.3)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    backgroundColor: error ? context.palette.critical : null,
  ));
}
