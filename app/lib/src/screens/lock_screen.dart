import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../app.dart';
import '../ui/widgets.dart';

/// Covers the app when it comes back after a while, until the customer
/// uses a fingerprint, their face or their PIN.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _busy = false;
  String? _error;
  int _errorTick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _biometrics());
  }

  Future<void> _biometrics() async {
    if (!mounted) return;
    final security = AppScope.of(context).security;
    if (!security.biometricsOn) return;
    if (await security.pinByBiometrics('Unlock Avora') != null) security.unlock();
  }

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await scope.api.verifyPin(_pin);
      scope.security.unlock();
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _errorTick++;
        _error = e is ApiException ? e.message : 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final bio = scope.security.biometricsOn;
    return Scaffold(
      key: const Key('lock-screen'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
          child: Column(
            children: [
              const LogoMark(size: 64),
              const SizedBox(height: 20),
              Text('Welcome back', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                bio ? 'Use your fingerprint, face or PIN to unlock.' : 'Enter your PIN to unlock.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              PinDots(key: const Key('lock-pin'), filled: _pin.length, errorTick: _errorTick),
              SizedBox(
                height: 48,
                child: Center(
                  child: _error == null
                      ? null
                      : Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                        ),
                ),
              ),
              const Spacer(),
              NumberPad(
                onDigit: _digit,
                onBackspace: () {
                  if (_pin.isNotEmpty && !_busy) setState(() => _pin = _pin.substring(0, _pin.length - 1));
                },
                extraIcon: bio ? Icons.fingerprint_rounded : null,
                onExtra: bio ? _biometrics : null,
              ),
              TextButton(
                key: const Key('lock-sign-out'),
                onPressed: () async {
                  await scope.recipients.clear();
                  try {
                    await scope.api.logout();
                  } catch (_) {
                    // The token is cleared locally either way.
                  }
                },
                child: const Text('Not you? Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
