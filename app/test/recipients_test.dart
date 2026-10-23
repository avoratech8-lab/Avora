import 'package:avora/src/credentials.dart';
import 'package:avora/src/recipients.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recent recipients: newest first, no duplicates, kept across restarts', () async {
    final store = MemoryKeyValueStore();
    final r = await RecentRecipients.load(store);
    await r.add(const Recipient(bankCode: '058', accountNumber: '0000000001', accountName: 'A'));
    await r.add(const Recipient(bankCode: '044', accountNumber: '0000000002', accountName: 'B'));
    await r.add(const Recipient(bankCode: '058', accountNumber: '0000000001', accountName: 'A'));
    expect(r.items.map((e) => e.accountName), ['A', 'B']);

    final reloaded = await RecentRecipients.load(store);
    expect(reloaded.items.map((e) => e.accountNumber), ['0000000001', '0000000002']);

    for (var i = 0; i < 20; i++) {
      await r.add(Recipient(bankCode: '058', accountNumber: '1$i'.padLeft(10, '0'), accountName: 'P$i'));
    }
    expect(r.items, hasLength(RecentRecipients.max));
  });

  test('a damaged saved list is ignored', () async {
    final store = MemoryKeyValueStore();
    await store.write('recent_recipients', 'not json');
    expect((await RecentRecipients.load(store)).items, isEmpty);
  });
}
