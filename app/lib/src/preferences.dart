import 'dart:convert';

import 'package:flutter/material.dart';

import 'api/models.dart';
import 'credentials.dart';

/// Small things the app remembers on this phone: the theme, whether the
/// balance is hidden, and the last Home screen so the app opens instantly
/// while it refreshes.
class Preferences extends ChangeNotifier {
  Preferences._(this._store, this._theme, this._hideBalance, this._home);

  static const _themeKey = 'theme';
  static const _hideKey = 'hide_balance';
  static const _homeKey = 'home_cache';

  static Future<Preferences> load(KeyValueStore store) async {
    final values = await Future.wait([store.read(_themeKey), store.read(_hideKey), store.read(_homeKey)]);
    return Preferences._(
      store,
      ThemeMode.values.where((m) => m.name == values[0]).firstOrNull ?? ThemeMode.system,
      values[1] == '1',
      _decodeHome(values[2]),
    );
  }

  factory Preferences.inMemory() => Preferences._(MemoryKeyValueStore(), ThemeMode.system, false, null);

  final KeyValueStore _store;
  ThemeMode _theme;
  bool _hideBalance;
  (Wallet, List<StatementLine>)? _home;

  ThemeMode get theme => _theme;
  bool get hideBalance => _hideBalance;

  /// What Home showed last time, if anything.
  (Wallet, List<StatementLine>)? get cachedHome => _home;

  Future<void> setTheme(ThemeMode m) async {
    _theme = m;
    notifyListeners();
    await _store.write(_themeKey, m.name);
  }

  Future<void> setHideBalance(bool hide) async {
    _hideBalance = hide;
    notifyListeners();
    await _store.write(_hideKey, hide ? '1' : '0');
  }

  Future<void> cacheHome(Wallet w, List<StatementLine> lines) async {
    _home = (w, lines);
    await _store.write(
      _homeKey,
      jsonEncode({'wallet': w.toJson(), 'lines': lines.take(20).map((l) => l.toJson()).toList()}),
    );
  }

  /// Forgets everything about the account on sign out; the theme stays.
  Future<void> signedOut() async {
    _home = null;
    await _store.delete(_homeKey);
  }

  static (Wallet, List<StatementLine>)? _decodeHome(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        Wallet.fromJson(j['wallet'] as Map<String, dynamic>),
        (j['lines'] as List).map((l) => StatementLine.fromJson(l as Map<String, dynamic>)).toList(),
      );
    } catch (_) {
      return null; // an old or damaged cache is simply ignored
    }
  }
}
