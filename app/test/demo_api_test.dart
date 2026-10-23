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
    // Over the Tier 1 daily limit, which is the same as the welcome credit.
    await expectLater(
      send('0123456781', DemoAvoraApi.welcomeCredit + 1),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'daily_limit')),
    );
    await api.verifyKyc(kind: 'bvn', number: '22212345671');
    await expectLater(
      send('0123456781', DemoAvoraApi.welcomeCredit + 1),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'insufficient_funds')),
    );
  });

  test('KYC raises the tier and the daily limit, and says so', () async {
    expect((await api.kycStatus()).tier, 1);
    await expectLater(
      api.verifyKyc(kind: 'nin', number: '12345678900'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'kyc_mismatch')),
    );
    expect((await api.verifyKyc(kind: 'nin', number: '12345678901')).tier, 2);
    final s = await api.verifyKyc(kind: 'bvn', number: '22212345671');
    expect(s.tier, 3);
    expect(s.limits.maxBalance, 0);

    final (items, unread) = await api.notifications();
    expect(items.first.title, "You're now on Tier 3");
    expect(unread, 3); // welcome, tier 2, tier 3
    await api.markNotificationsRead();
    expect((await api.notifications()).$2, 0);
  });

  test('changing the PIN needs the old one and is used from then on', () async {
    await expectLater(
      api.changePin(oldPin: '000001', newPin: '246810'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wrong_pin')),
    );
    await api.changePin(oldPin: '135790', newPin: '246810');
    await api.verifyPin('246810');
    await expectLater(api.verifyPin('135790'), throwsA(isA<ApiException>()));
    expect((await api.notifications()).$1.first.title, 'PIN changed');
  });

  test('this phone is listed and cannot be removed', () async {
    final devices = await api.devices();
    expect(devices.single.thisPhone, isTrue);
    await expectLater(
      api.removeDevice(devices.single.id),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'this_device')),
    );
  });

  test('bills: plans set the price, failures refund, the same key pays once', () async {
    final billers = await api.billers();
    expect(billers.where((b) => b.category == BillCategory.tv), hasLength(3));

    final tv = await api.payBill(
      billerId: 'gotv',
      planCode: 'gotv-max',
      customer: '1234567891',
      amount: 1,
      pin: '135790',
      idempotencyKey: 'tv',
    );
    expect(tv.amount, 850000);
    expect(tv.status, BillStatus.success);
    final again = await api.payBill(
      billerId: 'gotv',
      planCode: 'gotv-max',
      customer: '1234567891',
      amount: 1,
      pin: '135790',
      idempotencyKey: 'tv',
    );
    expect(again.id, tv.id);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 850000);

    final failed = await api.payBill(
      billerId: 'mtn-airtime',
      customer: '08031234560',
      amount: 10000,
      pin: '135790',
      idempotencyKey: 'a',
    );
    expect(failed.status, BillStatus.refunded);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 850000);

    final light = await api.payBill(
      billerId: 'ikedc',
      customer: '45123456781',
      amount: 500000,
      pin: '135790',
      idempotencyKey: 'e',
    );
    expect(light.token, hasLength(24));

    await expectLater(
      api.validateBillCustomer(billerId: 'dstv', customer: '1234567898'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'customer_not_found')),
    );
    final lines = await api.statement();
    expect(lines.first.kind, 'bill_payment');
    expect(lines.first.description, 'Ikeja Electric · meter 45123456781');
  });

  test('savings: goals move freely, locked plans hold until maturity or give back profit', () async {
    final goal = await api.createPot(
      kind: PotKind.goal,
      name: 'Phone',
      target: 1000000,
      amount: 200000,
      idempotencyKey: 'g',
    );
    expect(goal.balance, 200000);
    expect((await api.createPot(kind: PotKind.goal, name: 'Phone', idempotencyKey: 'g')).id, goal.id);
    expect((await api.depositToPot(goal.id, 100000, idempotencyKey: 'd')).balance, 300000);
    expect((await api.depositToPot(goal.id, 100000, idempotencyKey: 'd')).balance, 300000);
    expect((await api.withdrawFromPot(goal.id, amount: 50000, idempotencyKey: 'w')).balance, 250000);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 250000);

    final plan = await api.createPot(
      kind: PotKind.locked,
      name: 'Rent',
      lockDays: 90,
      amount: 1200000,
      idempotencyKey: 'l',
    );
    expect(plan.expectedRateBps, 1200);
    await expectLater(
      api.withdrawFromPot(plan.id, idempotencyKey: 'x'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'savings_locked')),
    );

    api.shareDemoProfit();
    final (pots, _) = await api.savings();
    final withProfit = pots.firstWhere((p) => p.id == plan.id);
    expect(withProfit.profitEarned, 12000);

    final broken = await api.withdrawFromPot(plan.id, breakEarly: true, idempotencyKey: 'b');
    expect(broken.open, isFalse);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 250000);

    now = now.add(const Duration(days: 31));
    final short = await api.createPot(
      kind: PotKind.locked,
      name: 'Trip',
      lockDays: 30,
      amount: 100000,
      idempotencyKey: 's',
    );
    now = now.add(const Duration(days: 30));
    expect((await api.withdrawFromPot(short.id, idempotencyKey: 's2')).open, isFalse);
  });

  test('a friend who joins with your code and verifies pays you once', () async {
    final mine = await api.referrals();
    expect(mine.code, startsWith('AV'));
    await expectLater(
      api.joinReferral(mine.code),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'own_code')),
    );

    await api.logout();
    final c = await api.startOtp('08029998888');
    await api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '246810');
    expect((await api.joinReferral(mine.code.toLowerCase())).joinedWith, mine.code);
    await expectLater(
      api.joinReferral(mine.code),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'code_used')),
    );
    await api.verifyKyc(kind: 'bvn', number: '22212345671');
    await api.verifyKyc(kind: 'nin', number: '12345678901');

    await api.logout();
    final c2 = await api.startOtp('08031234567');
    await api.verify(challengeId: c2, code: DemoAvoraApi.code, pin: '135790');
    final after = await api.referrals();
    expect(after.invited, 1);
    expect(after.earned, DemoAvoraApi.referralReward);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit + DemoAvoraApi.referralReward);
  });

  test('the support assistant answers from the help centre', () async {
    expect(await api.helpArticles(), hasLength(10));
    final m = await api.sendSupportMessage('what are the transfer fees?');
    expect(m, hasLength(2));
    expect(m.last.sender, 'bot');
    expect(m.last.body, startsWith('How much do transfers cost?'));
    final h = await api.sendSupportMessage('I want to speak to an agent');
    expect(h.last.body, contains('support team'));
  });

  test('Avora tags: claim one, find people, send free and instant, once per key', () async {
    await expectLater(
      api.updateProfile(tag: '@1bad'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_request')),
    );
    await expectLater(
      api.updateProfile(tag: 'tolu'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'tag_taken')),
    );
    final me = await api.updateProfile(name: ' Ada   Obi ', tag: '@Ada_O');
    expect((me.name, me.tag), ('Ada Obi', 'ada_o'));

    expect((await api.findPerson('@TOLU')).name, 'Tolu Adeyemi');
    final chidi = await api.findPerson('+234 801 111 0002');
    expect((chidi.handle, chidi.phone), ('@chidi', '0801 *** 0002'));
    await expectLater(api.findPerson('@ada_o'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'self')));
    await expectLater(
      api.findPerson('@nobody'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'person_not_found')),
    );

    Future<P2PTransfer> pay(String key) =>
        api.sendToAvora(to: '@tolu', amount: 1500000, note: 'Suya', pin: '135790', idempotencyKey: key);
    final t = await pay('k1');
    expect((await pay('k1')).id, t.id);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 1500000);
    final line = (await api.statement()).first;
    expect((line.kind, line.description, line.amount), ('p2p_out', 'To Tolu Adeyemi (@tolu)', -1500000));
    expect((await api.p2pTransfer(t.id)).other.tag, 'tolu');

    // Tolu sees it arrive, free, with the note.
    await api.logout();
    final c = await api.startOtp('08011110001');
    await api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '135790');
    final got = await api.p2pTransfer(t.id);
    expect((got.outgoing, got.amount, got.note, got.other.handle), (false, 1500000, 'Suya', '@ada_o'));
    final (items, _) = await api.notifications();
    expect(items.first.body, 'From Ada Obi (@ada_o): Suya');
  });
}
