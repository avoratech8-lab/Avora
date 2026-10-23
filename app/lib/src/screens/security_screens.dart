import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../security.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Me → Security: fingerprint and face, the app lock, PIN and phones.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  bool? _available;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_available == null) {
      AppScope.of(context).security.biometrics.available().then((a) {
        if (mounted) setState(() => _available = a);
      });
    }
  }

  Future<void> _toggleBiometrics(Security security, bool on) async {
    if (!on) {
      await security.disableBiometrics();
      return;
    }
    if (_available != true) {
      showMessage(context, 'Set up a fingerprint or face unlock in your phone settings first.');
      return;
    }
    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const PinCheckSheet(title: 'Enter your PIN', subtitle: 'to turn on fingerprint and face'),
    );
    if (pin == null || !mounted) return;
    if (!await security.biometrics.authenticate('Turn on fingerprint and face for Avora')) return;
    await security.enableBiometrics(pin);
    if (mounted) showMessage(context, 'Fingerprint and face are on');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final security = AppScope.of(context).security;
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListenableBuilder(
        listenable: security,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    key: const Key('biometrics'),
                    secondary: Icon(Icons.fingerprint_rounded, color: theme.colorScheme.primary),
                    title: Text('Fingerprint and face', style: theme.textTheme.titleSmall),
                    subtitle: Text(
                      _available == false
                          ? 'Not set up on this phone'
                          : 'Unlock the app and approve payments without your PIN',
                    ),
                    value: security.biometricsOn,
                    onChanged: (v) => _toggleBiometrics(security, v),
                  ),
                  const Divider(indent: 56),
                  ListTile(
                    leading: Icon(Icons.lock_clock_outlined, color: theme.colorScheme.primary),
                    title: Text('Lock the app', style: theme.textTheme.titleSmall),
                    subtitle: Text('${security.lockAfter.label} away'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _pickLock(security),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    key: const Key('change-pin'),
                    leading: Icon(Icons.password_rounded, color: theme.colorScheme.primary),
                    title: Text('Change PIN', style: theme.textTheme.titleSmall),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ChangePinScreen())),
                  ),
                  const Divider(indent: 56),
                  ListTile(
                    key: const Key('devices'),
                    leading: Icon(Icons.devices_rounded, color: theme.colorScheme.primary),
                    title: Text('Phones signed in', style: theme.textTheme.titleSmall),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen())),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SafetyTips(),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLock(Security security) async {
    final l = await showModalBottomSheet<LockAfter>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in LockAfter.values)
              ListTile(
                key: Key('lock-${l.name}'),
                title: Text(l.label),
                trailing: l == security.lockAfter ? const Icon(Icons.check_rounded, color: Brand.green) : null,
                onTap: () => Navigator.pop(c, l),
              ),
          ],
        ),
      ),
    );
    if (l != null) await security.setLockAfter(l);
  }
}

class _SafetyTips extends StatelessWidget {
  const _SafetyTips();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Brand.green.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, color: Brand.green),
              const SizedBox(width: 10),
              Text('Staying safe', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          for (final t in const [
            'Avora staff will never ask for your PIN or sign-in code.',
            "Don't share your screen while the app is open.",
            'A new phone can send up to ₦20,000 in its first 24 hours.',
          ])
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  '),
                  Expanded(child: Text(t, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks for the PIN and checks it with the server; pops with the PIN.
class PinCheckSheet extends StatefulWidget {
  const PinCheckSheet({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  State<PinCheckSheet> createState() => _PinCheckSheetState();
}

class _PinCheckSheetState extends State<PinCheckSheet> {
  String _pin = '';
  bool _busy = false;
  String? _error;
  int _errorTick = 0;

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).api.verifyPin(_pin);
      if (mounted) Navigator.of(context).pop(_pin);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _busy = false;
        _pin = '';
        _errorTick++;
        _error = e is ApiException ? e.message : 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              widget.subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            PinDots(key: const Key('check-pin'), filled: _pin.length, errorTick: _errorTick),
            SizedBox(
              height: 44,
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
            NumberPad(
              onDigit: _digit,
              onBackspace: () {
                if (_pin.isNotEmpty && !_busy) setState(() => _pin = _pin.substring(0, _pin.length - 1));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Current PIN, new PIN, new PIN again.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key});

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  int _step = 0;
  String _old = '';
  String _new = '';
  String _pin = '';
  bool _busy = false;
  String? _error;
  int _errorTick = 0;

  static const _titles = ['Current PIN', 'New PIN', 'Confirm new PIN'];
  static const _hints = [
    'Enter the PIN you use now.',
    'Choose 6 digits. Avoid easy ones like 123456 or your birthday.',
    'Enter the new PIN again.',
  ];

  void _fail(String msg, {required int step}) {
    HapticFeedback.heavyImpact();
    setState(() {
      _error = msg;
      _errorTick++;
      _pin = '';
      _step = step;
    });
  }

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;
    switch (_step) {
      case 0:
        setState(() {
          _old = _pin;
          _pin = '';
          _step = 1;
        });
      case 1:
        if (_pin == _old) return _fail('Choose a PIN different from your current one.', step: 1);
        setState(() {
          _new = _pin;
          _pin = '';
          _step = 2;
        });
      default:
        if (_pin != _new) return _fail("Those PINs don't match. Choose your new PIN again.", step: 1);
        await _save();
    }
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await scope.api.changePin(oldPin: _old, newPin: _new);
      await scope.security.pinChanged(_new);
      if (!mounted) return;
      showMessage(context, 'PIN changed. Your other phones were signed out.');
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _fail(e.message, step: e.code == 'wrong_pin' || e.code == 'pin_locked' ? 0 : 1);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _fail('Something went wrong. Please try again.', step: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Change PIN')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Column(
            children: [
              Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: i <= _step ? Brand.green : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 28),
              Text(_titles[_step], key: const Key('pin-step'), style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                _hints[_step],
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              PinDots(key: const Key('new-pin'), filled: _pin.length, errorTick: _errorTick),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Phones that have signed in, with a way to remove one that isn't yours.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Device>? _devices;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_devices == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final d = await AppScope.of(context).api.devices();
      if (mounted) setState(() => _devices = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _remove(Device d) async {
    final api = AppScope.of(context).api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${_name(d)}?'),
        content: const Text(
          "It will be signed out and will need a new code and your PIN to sign in again. If it wasn't you, change your PIN too.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-remove'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.removeDevice(d.id);
      if (!mounted) return;
      showMessage(context, '${_name(d)} removed');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  static String _name(Device d) => d.name.isEmpty ? 'A phone' : d.name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = _devices;
    return Scaffold(
      appBar: AppBar(title: const Text('Phones signed in')),
      body: devices == null
          ? Center(
              child: _error == null ? const CircularProgressIndicator() : const Text("We couldn't load your phones."),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Text(
                  "These are the phones that have signed in to your account. If you see one you don't know, remove it and change your PIN.",
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      for (final (i, d) in devices.indexed) ...[
                        if (i > 0) const Divider(indent: 56),
                        ListTile(
                          key: Key('device-${d.id}'),
                          leading: Icon(
                            Icons.smartphone_rounded,
                            color: d.thisPhone ? Brand.green : theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Text(_name(d), style: theme.textTheme.titleSmall),
                          subtitle: Text(
                            d.thisPhone
                                ? 'This phone · added ${formatDate(d.boundAt)}'
                                : '${d.signedIn ? 'Signed in' : 'Signed out'} · added ${formatDate(d.boundAt)}',
                          ),
                          trailing: d.thisPhone
                              ? null
                              : IconButton(
                                  key: Key('remove-${d.id}'),
                                  tooltip: 'Remove',
                                  icon: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
                                  onPressed: () => _remove(d),
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
