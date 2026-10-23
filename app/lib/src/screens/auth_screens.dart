import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/demo_api.dart';
import '../app.dart';
import '../ui/widgets.dart';

final _phoneRe = RegExp(r'^(\+?234|0)?[789][01]\d{8}$');

/// Turns "0803 123 4567" or "+2348031234567" into "0803 123 4567" for display.
String displayPhone(String phone) {
  var p = phone.replaceAll(RegExp(r'\D'), '');
  if (p.startsWith('234')) p = '0${p.substring(3)}';
  if (!p.startsWith('0')) p = '0$p';
  if (p.length != 11) return phone;
  return '${p.substring(0, 4)} ${p.substring(4, 7)} ${p.substring(7)}';
}

/// Step 1: phone number.
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

  String get _cleaned => _phone.text.replaceAll(RegExp(r'[\s-]'), '');

  Future<void> _continue() async {
    final phone = _cleaned;
    if (!_phoneRe.hasMatch(phone)) {
      setState(() => _error = 'Enter a Nigerian mobile number, like 0803 123 4567');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = AppScope.of(context).api;
    try {
      final challenge = await api.startOtp(phone);
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
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("What's your phone number?", style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                "It's how you sign in. We'll text you a code to confirm it's yours.",
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              TextField(
                key: const Key('phone'),
                controller: _phone,
                autofocus: true,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d\s+-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
                style: theme.textTheme.titleLarge,
                decoration: InputDecoration(
                  hintText: '0803 123 4567',
                  errorText: _error,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🇳🇬', style: TextStyle(fontSize: 20)),
                        const SizedBox(width: 8),
                        Text('+234', style: theme.textTheme.titleMedium),
                        const SizedBox(width: 10),
                        Container(width: 1, height: 24, color: theme.colorScheme.outlineVariant),
                      ],
                    ),
                  ),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _continue(),
              ),
              const SizedBox(height: 16),
              if (demo)
                _DemoNote(
                  text: 'Demo mode: no real money moves. Use any number; your code will be ${DemoAvoraApi.code}.',
                ),
              const Spacer(),
              Text(
                'By continuing you agree to the Terms and Privacy Policy.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              PrimaryButton(key: const Key('continue'), label: 'Continue', loading: _busy, onPressed: _continue),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoNote extends StatelessWidget {
  const _DemoNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.science_outlined, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Step 2: the texted code, typed on the number pad.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key, required this.phone, required this.challengeId});

  final String phone;
  final String challengeId;

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  static const _resendAfter = 60;

  late String _challenge = widget.challengeId;
  String _code = '';
  int _wait = _resendAfter;
  Timer? _timer;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _wait = _resendAfter);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_wait <= 1) t.cancel();
      setState(() => _wait--);
    });
  }

  Future<void> _resend() async {
    setState(() => _resending = true);
    try {
      _challenge = await AppScope.of(context).api.startOtp(widget.phone);
      if (!mounted) return;
      setState(() => _code = '');
      _startTimer();
      showMessage(context, 'New code sent');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _digit(String d) async {
    if (_code.length >= 6) return;
    setState(() => _code += d);
    if (_code.length == 6) {
      final code = _code;
      final wrong = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PinScreen(challengeId: _challenge, code: code),
        ),
      );
      // The PIN screen comes back with true when the code itself was rejected.
      if (mounted && wrong == true) {
        setState(() => _code = '');
        showMessage(context, 'That code is wrong or has expired. Try again or get a new one.');
      } else if (mounted) {
        setState(() => _code = '');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Enter the code', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'We sent a 6-digit code to '),
                    TextSpan(
                      text: displayPhone(widget.phone),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              CodeBoxes(key: const Key('code'), code: _code),
              const SizedBox(height: 16),
              Center(
                child: _wait > 0
                    ? Text(
                        'Resend code in 0:${_wait.toString().padLeft(2, '0')}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      )
                    : TextButton(onPressed: _resending ? null : _resend, child: const Text('Resend code')),
              ),
              const Spacer(),
              NumberPad(
                onDigit: _digit,
                onBackspace: () {
                  if (_code.isNotEmpty) setState(() => _code = _code.substring(0, _code.length - 1));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Step 3: the PIN. New customers choose one here; returning customers (or
/// a new phone) confirm theirs.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.challengeId, required this.code});

  final String challengeId;
  final String code;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  bool _busy = false;
  int _errorTick = 0;
  String? _error;

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;

    setState(() => _busy = true);
    final api = AppScope.of(context).api;
    try {
      // On success the credentials change and the app opens the home screen.
      await api.verify(challengeId: widget.challengeId, code: widget.code, pin: _pin);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'invalid_code') {
        Navigator.of(context).pop(true);
        return;
      }
      HapticFeedback.heavyImpact();
      setState(() {
        _error = e.message;
        _errorTick++;
        _pin = '';
      });
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _pin = '');
      }
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Column(
            children: [
              Text('Your 6-digit PIN', style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'New here? Create a PIN to approve payments. Avoid easy ones like 123456.\n'
                'Already with Avora? Enter your PIN.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 36),
              PinDots(key: const Key('pin'), filled: _pin.length, errorTick: _errorTick),
              const SizedBox(height: 16),
              SizedBox(
                height: 40,
                child: _busy
                    ? const Center(
                        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      )
                    : _error == null
                    ? null
                    : Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                      ),
              ),
              const Spacer(),
              NumberPad(
                onDigit: _digit,
                onBackspace: () {
                  if (_pin.isNotEmpty && !_busy) setState(() => _pin = _pin.substring(0, _pin.length - 1));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
