import 'package:flutter/material.dart';

import '../api/demo_api.dart';
import '../app.dart';
import 'code_screen.dart';

final _phoneRe = RegExp(r'^(\+?234|0)?[789][01]\d{8}$');

/// First screen: the customer's phone number, which is their login.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final phone = _phone.text.replaceAll(RegExp(r'[\s-]'), '');
    if (!_phoneRe.hasMatch(phone)) {
      setState(() => _error = 'Enter a Nigerian mobile number, like 0803 123 4567');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final scope = AppScope.of(context);
    try {
      final challenge = await scope.api.startOtp(phone);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CodeScreen(phone: phone, challengeId: challenge),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final demo = AppScope.of(context).api.isDemo;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Text(
              'Avora',
              style: theme.textTheme.displaySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text('Send money for free, and get it there.', style: theme.textTheme.titleMedium),
            const SizedBox(height: 40),
            TextField(
              key: const Key('phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              decoration: InputDecoration(
                labelText: 'Phone number',
                hintText: '0803 123 4567',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _continue(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('continue'),
              onPressed: _busy ? null : _continue,
              child: _busy ? const _Spinner() : const Text('Continue'),
            ),
            const SizedBox(height: 16),
            Text(
              demo
                  ? 'Demo mode: no real money moves. Your code will be ${DemoAvoraApi.code}.'
                  : "We'll text you a 6-digit code to confirm it's you.",
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
}
