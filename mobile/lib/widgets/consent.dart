import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/terms.dart';
import '../core/theme.dart';
import '../providers/core_providers.dart';
import '../providers/session_provider.dart';
import '../services/api_service.dart';

/// Full terms & research consent text in a scrollable sheet.
Future<void> showTermsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (ctx, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text('Terms & research consent', style: ctx.text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text('Version $kTermsVersion', style: TextStyle(color: ctx.palette.muted, fontSize: 12)),
          for (final (heading, body) in kTermsSections) ...[
            const SizedBox(height: 16),
            Text(heading, style: ctx.text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(body),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    ),
  );
}

/// Required consent checkbox for the registration form.
class ConsentCheckbox extends FormField<bool> {
  ConsentCheckbox({super.key, required ValueChanged<bool> onChanged})
      : super(
          initialValue: false,
          validator: (v) => v == true ? null : 'Please accept to create an account',
          builder: (state) {
            final context = state.context;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: state.value ?? false,
                      onChanged: (v) {
                        state.didChange(v ?? false);
                        onChanged(v ?? false);
                      },
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(kConsentSummary, style: TextStyle(fontSize: 13)),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => showTermsSheet(context),
                              child: const Text('Read the terms & consent'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (state.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(state.errorText!,
                        style: TextStyle(color: context.colors.error, fontSize: 12)),
                  ),
              ],
            );
          },
        );
}

/// Shown after login to accounts that haven't accepted the current terms.
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).acceptTerms();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final palette = context.palette;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Icon(Icons.verified_user_outlined, size: 40, color: context.colors.primary),
                const SizedBox(height: 12),
                Text(
                  user?.termsAcceptedAt == null ? 'Before you continue' : 'Our terms have changed',
                  style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text('Nisaab AI is part of a research study. Please review how your data is used.',
                    style: TextStyle(color: palette.muted)),
                for (final (heading, body) in kTermsSections) ...[
                  const SizedBox(height: 14),
                  Text(heading, style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(body),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: TextStyle(color: palette.critical)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _accept,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('I agree'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => ref.read(sessionProvider.notifier).logout(),
                      child: const Text('Not now, log out'),
                    ),
                    if (user != null && !user.isDemo)
                      TextButton(
                        onPressed: _busy ? null : () => showDeleteAccountDialog(context, ref),
                        child: Text('Delete my account', style: TextStyle(color: palette.critical)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for the password, deletes the account and signs out. Returns true if deleted.
Future<bool> showDeleteAccountDialog(BuildContext context, WidgetRef ref) async {
  // Captured up front: signing out may dispose the widget that opened this dialog.
  final messenger = ScaffoldMessenger.of(context);
  final homeTab = ref.read(homeTabProvider.notifier);
  final deleted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _DeleteAccountDialog(),
  );
  if (deleted == true) {
    homeTab.state = 0;
    messenger.showSnackBar(const SnackBar(content: Text('Your account and all of its data were deleted.')));
  }
  return deleted == true;
}

class _DeleteAccountDialog extends ConsumerStatefulWidget {
  const _DeleteAccountDialog();

  @override
  ConsumerState<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final notifier = ref.read(sessionProvider.notifier);
      await ref.read(apiServiceProvider).deleteAccount(_password.text);
      // Close the dialog before signing out, which replaces the screen underneath it.
      if (mounted) Navigator.pop(context, true);
      await notifier.logout();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: palette.critical),
      title: const Text('Delete your account?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This permanently erases your account and everything in it: transactions, budgets, '
                'savings goals and assistant history. You will also leave the research study. '
                'This cannot be undone.'),
            const SizedBox(height: 16),
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              decoration: InputDecoration(labelText: 'Confirm with your password', errorText: _error),
              onSubmitted: (_) => _delete(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: palette.critical, foregroundColor: Colors.white),
          onPressed: _busy ? null : _delete,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Delete forever'),
        ),
      ],
    );
  }
}

/// Consent status and the delete option for the profile sheet.
class AccountPrivacySection extends ConsumerWidget {
  const AccountPrivacySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final palette = context.palette;
    final accepted = user.termsAcceptedAt;
    final status = user.isDemo
        ? 'Shared demo account: not part of the research study.'
        : accepted == null
            ? 'Research consent not given.'
            : 'Research consent given on ${MaterialLocalizations.of(context).formatMediumDate(accepted.toLocal())} '
                '(terms v${user.termsVersion}).';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Privacy', style: context.text.labelLarge),
        const SizedBox(height: 6),
        Text(status, style: TextStyle(color: palette.muted, fontSize: 13)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: () => showTermsSheet(context), child: const Text('Read the terms')),
        ),
        if (!user.isDemo)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: palette.critical),
            onPressed: () async {
              final sheet = Navigator.of(context);
              final deleted = await showDeleteAccountDialog(context, ref);
              if (deleted && sheet.canPop()) sheet.pop();
            },
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete account'),
          ),
      ],
    );
  }
}
