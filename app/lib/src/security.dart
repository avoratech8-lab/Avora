import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'credentials.dart';

/// The phone's fingerprint or face check.
abstract class Biometrics {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

class DeviceBiometrics implements Biometrics {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }
}

/// For phones (and tests) with no fingerprint or face unlock.
class NoBiometrics implements Biometrics {
  const NoBiometrics();

  @override
  Future<bool> available() async => false;
  @override
  Future<bool> authenticate(String reason) async => false;
}

/// How soon the app locks after it leaves the screen.
enum LockAfter {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes');

  const LockAfter(this.duration, this.label);
  final Duration duration;
  final String label;
}

/// The app lock and fingerprint or face approval.
///
/// With biometrics on, the PIN is kept in the phone's Keystore/Keychain and
/// only released after a successful fingerprint or face check, so the server
/// still sees the PIN on every payment.
class Security extends ChangeNotifier {
  Security._(this._store, this.biometrics, this._pin, this._lockAfter, this._locked);

  static const _pinKey = 'biometric_pin';
  static const _lockKey = 'lock_after';

  /// [signedIn] says whether a session was kept from last time; if so the
  /// app opens locked.
  static Future<Security> load(KeyValueStore store, Biometrics biometrics, {required bool signedIn}) async {
    final lock = await store.read(_lockKey);
    return Security._(
      store,
      biometrics,
      await store.read(_pinKey),
      LockAfter.values.where((l) => l.name == lock).firstOrNull ?? LockAfter.oneMinute,
      signedIn,
    );
  }

  /// No biometrics and nothing stored; for tests and previews.
  factory Security.inMemory({Biometrics biometrics = const NoBiometrics()}) =>
      Security._(MemoryKeyValueStore(), biometrics, null, LockAfter.oneMinute, false);

  final KeyValueStore _store;
  final Biometrics biometrics;
  String? _pin;
  LockAfter _lockAfter;
  bool _locked;
  DateTime? _leftAt;

  bool get biometricsOn => _pin != null;
  LockAfter get lockAfter => _lockAfter;
  bool get locked => _locked;

  Future<void> enableBiometrics(String pin) async {
    await _store.write(_pinKey, pin);
    _pin = pin;
    notifyListeners();
  }

  Future<void> disableBiometrics() async {
    await _store.delete(_pinKey);
    _pin = null;
    notifyListeners();
  }

  /// Keeps the stored PIN in step after a PIN change.
  Future<void> pinChanged(String pin) async {
    if (biometricsOn) await enableBiometrics(pin);
  }

  /// Asks for a fingerprint or face and returns the PIN, or null if the
  /// check failed or biometrics are off.
  Future<String?> pinByBiometrics(String reason) async {
    final pin = _pin;
    if (pin == null) return null;
    return await biometrics.authenticate(reason) ? pin : null;
  }

  Future<void> setLockAfter(LockAfter l) async {
    await _store.write(_lockKey, l.name);
    _lockAfter = l;
    notifyListeners();
  }

  void left(DateTime at) => _leftAt ??= at;

  /// Locks if the app was away for longer than [lockAfter].
  void returned(DateTime at, {required bool signedIn}) {
    final left = _leftAt;
    _leftAt = null;
    if (signedIn && left != null && at.difference(left) >= _lockAfter.duration) lock();
  }

  void lock() {
    if (_locked) return;
    _locked = true;
    notifyListeners();
  }

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }

  /// Forgets the stored PIN on sign out.
  Future<void> signedOut() async {
    _locked = false;
    await disableBiometrics();
  }
}
