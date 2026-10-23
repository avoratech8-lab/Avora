import 'package:avora/src/api/models.dart';
import 'package:avora/src/credentials.dart';
import 'package:avora/src/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('theme, hidden balance and the Home cache survive a restart', () async {
    final store = MemoryKeyValueStore();
    final p = await Preferences.load(store);
    expect(p.theme, ThemeMode.system);
    expect(p.cachedHome, isNull);

    await p.setTheme(ThemeMode.dark);
    await p.setHideBalance(true);
    await p.cacheHome(Wallet(id: 1, accountNumber: '9012345678', balance: 123450), [
      StatementLine(
        kind: 'inbound_credit',
        description: 'From ADA',
        ref: '',
        amount: 500,
        at: DateTime.utc(2026, 10, 23),
      ),
    ]);

    final again = await Preferences.load(store);
    expect(again.theme, ThemeMode.dark);
    expect(again.hideBalance, isTrue);
    expect(again.cachedHome!.$1.balance, 123450);
    expect(again.cachedHome!.$2.single.description, 'From ADA');

    await again.signedOut();
    expect((await Preferences.load(store)).cachedHome, isNull);
    expect((await Preferences.load(store)).theme, ThemeMode.dark);
  });

  test('a damaged cache is ignored', () async {
    final store = MemoryKeyValueStore();
    await store.write('home_cache', '{not json');
    expect((await Preferences.load(store)).cachedHome, isNull);
  });
}
