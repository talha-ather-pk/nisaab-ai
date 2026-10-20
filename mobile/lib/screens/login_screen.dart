import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/formatters.dart';
import '../core/theme.dart';
import '../providers/session_provider.dart';
import '../services/api_service.dart';
import '../widgets/consent.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _income = TextEditingController();
  bool _registering = false;
  bool _busy = false;
  bool _obscure = true;
  bool _acceptedTerms = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _income.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = ref.read(sessionProvider.notifier);
    try {
      if (_registering) {
        await session.register(
          fullName: _name.text,
          email: _email.text,
          password: _password.text,
          monthlyIncome: parseAmount(_income.text),
          acceptTerms: _acceptedTerms,
        );
      } else {
        await session.login(_email.text, _password.text);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fillDemo() {
    setState(() {
      _registering = false;
      _email.text = AppConfig.demoEmail;
      _password.text = AppConfig.demoPassword;
    });
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _BrandMark(),
                      const SizedBox(height: 28),
                      Text(_registering ? 'Create your account' : 'Welcome back',
                          style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(
                        _registering
                            ? 'Track every rupee. Takes less than a minute.'
                            : 'Log in to see where your money goes.',
                        style: TextStyle(color: palette.muted),
                      ),
                      const SizedBox(height: 24),
                      if (_registering) ...[
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.name],
                          decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline)),
                          validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value) ? null : 'Enter a valid email';
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: [_registering ? AutofillHints.newPassword : AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          helperText: _registering ? 'At least 8 characters, with a letter and a number' : null,
                        ),
                        validator: (v) {
                          final value = v ?? '';
                          if (!_registering) return value.isEmpty ? 'Enter your password' : null;
                          if (value.length < 8) return 'Use at least 8 characters';
                          if (!value.contains(RegExp(r'[A-Za-z]')) || !value.contains(RegExp(r'\d'))) {
                            return 'Include a letter and a number';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_registering) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _income,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Monthly income (optional)',
                            prefixText: 'Rs  ',
                            prefixIcon: Icon(Icons.payments_outlined),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ConsentCheckbox(onChanged: (v) => _acceptedTerms = v),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(_error!, style: TextStyle(color: palette.critical)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(_registering ? 'Create account' : 'Log in'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _registering = !_registering;
                                  _error = null;
                                }),
                        child: Text(_registering ? 'Already have an account? Log in' : 'New to Nisaab? Create an account'),
                      ),
                      if (!_registering)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _fillDemo,
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text('Try the demo account'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [palette.heroStart, palette.heroEnd]),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.bar_chart_rounded, color: Colors.white, size: 30),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Nisaab', style: context.text.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('TRACK · UNDERSTAND · GROW',
                    style: TextStyle(color: palette.muted, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
