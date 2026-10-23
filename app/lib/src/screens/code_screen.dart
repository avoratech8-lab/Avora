import 'package:flutter/material.dart';

import '../app.dart';

/// The texted code plus the PIN. New customers choose their PIN here;
/// returning customers (or a new phone) confirm theirs.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key, required this.phone, required this.challengeId});

  final String phone;
  final String challengeId;

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  final _code = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  String? _codeError;
  String? _pinError;

  @override
  void dispose() {
    _code.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    final pin = _pin.text.trim();
    setState(() {
      _codeError = RegExp(r'^\d{6}$').hasMatch(code) ? null : 'Enter the 6-digit code we texted you';
      _pinError = RegExp(r'^\d{6}$').hasMatch(pin) ? null : 'Your PIN is 6 digits';
    });
    if (_codeError != null || _pinError != null) return;

    setState(() => _busy = true);
    final scope = AppScope.of(context);
    try {
      // On success the credentials change and the app swaps to the home screen.
      await scope.api.verify(challengeId: widget.challengeId, code: code, pin: pin);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Enter your code', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('We sent it to ${widget.phone}.'),
            const SizedBox(height: 24),
            TextField(
              key: const Key('code'),
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: InputDecoration(labelText: 'Code', errorText: _codeError, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('pin'),
              controller: _pin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              obscureText: true,
              decoration: InputDecoration(labelText: 'PIN', errorText: _pinError, border: const OutlineInputBorder()),
              onSubmitted: (_) => _verify(),
            ),
            Text(
              'New here? Choose a 6-digit PIN you will use to approve transfers. '
              'Avoid easy ones like 123456 or your birthday. '
              'Already with Avora? Enter your PIN.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('verify'),
              onPressed: _busy ? null : _verify,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
