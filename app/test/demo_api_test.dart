import 'package:avora/src/api/api.dart';
import 'package:avora/src/api/demo_api.dart';
import 'package:avora/src/api/models.dart';
import 'package:avora/src/credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DemoAvoraApi api;
  late DateTime now;

  setUp(() async {
    now = DateTime(2026, 10, 23, 12);
    api = DemoAvoraApi(credentials: await Credentials.load(MemoryKeyValueStore()), clock: () => now);
    final c = await api.startOtp('08031234567');
    await api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '135790');
  });

  Future<Transfer> send(String account, int amount, {String key = '', String pin = '135790'}) => api.send(
    bankCode: '058',
    accountNumber: account,
    amount: amount,
    narration: '',
    pin: pin,
    idempotencyKey: key.isEmpty ? '$account-$amount-${now.microsecondsSinceEpoch}' : key,
  );

  test('sign-up gives the welcome credit; a wrong code or PIN is refused', () async {
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit);

    final c = await api.startOtp('08031234567');
    await expectLater(
      api.verify(challengeId: c, code: '111111', pin: '135790'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_code')),
    );
    await expectLater(
      api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '246801'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wrong_pin')),
    );
  });

  test('delivered, declined and slow transfers follow the sandbox rules', () async {
    final ok = await send('0123456781', 100000);
    expect(ok.status, TransferStatus.delivered);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 100000);

    final declined = await send('0123456780', 200000);
    expect(declined.status, TransferStatus.refunded);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 100000);

    final slow = await send('0123456789', 300000);
    expect(slow.status, TransferStatus.sent);
    now = now.add(const Duration(seconds: 10));
    expect((await api.transfer(slow.id)).status, TransferStatus.delivered);

    await expectLater(
      api.nameEnquiry(bankCode: '058', accountNumber: '0123456788'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'account_not_found')),
    );
  });

  test('five free transfers, then a fee', () async {
    for (var i = 0; i < 5; i++) {
      expect((await api.quote(1000)).fee, 0);
      await send('0123456781', 1000, key: 'k$i');
    }
    final q = await api.quote(1000);
    expect(q.fee, DemoAvoraApi.feeAfterFree);
    expect(q.freeTransfersLeft, 0);
    expect((await send('0123456781', 1000, key: 'k5')).fee, DemoAvoraApi.feeAfterFree);
  });

  test('the same idempotency key never sends twice', () async {
    final a = await send('0123456781', 1000, key: 'same');
    final b = await send('0123456781', 1000, key: 'same');
    expect(b.id, a.id);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 1000);
  });

  test('wrong PIN and too little money are refused', () async {
    await expectLater(
      send('0123456781', 1000, pin: '000001'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wrong_pin')),
    );
    await expectLater(
      send('0123456781', DemoAvoraApi.welcomeCredit + 1),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'insufficient_funds')),
    );
  });
}
