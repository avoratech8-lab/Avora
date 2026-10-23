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
    expect(unread, 4); // welcome, Tolu's split, tier 2, tier 3
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
    expect(await api.helpArticles(), hasLength(11));
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

  test('cashback on airtime and data only, capped, and none on a refund', () async {
    Future<BillPayment> pay(String biller, String customer, int amount, {String? plan}) => api.payBill(
      billerId: biller,
      planCode: plan,
      customer: customer,
      amount: amount,
      pin: '135790',
      idempotencyKey: '$biller-$customer-$amount',
    );
    expect((await pay('mtn-airtime', '08031234567', 100000)).cashback, 2000); // 2% of ₦1,000
    expect((await pay('glo-airtime', '08051234567', 3000000)).cashback, Biller.maxCashback);
    expect((await pay('mtn-airtime', '08031234560', 100000)).cashback, 0); // declined
    expect((await pay('dstv', '1234567891', 0, plan: 'dstv-padi')).cashback, 0);
    expect(
      (await api.wallet()).balance,
      DemoAvoraApi.welcomeCredit - 100000 + 2000 - 3000000 + Biller.maxCashback - 440000,
    );
    final lines = await api.statement();
    expect(lines.where((l) => l.kind == 'cashback').map((l) => l.description), [
      'Cashback: Glo airtime · 08051234567',
      'Cashback: MTN airtime · 08031234567',
    ]);

    final bet = await pay('bet9ja', 'BN48213', 50000);
    expect((bet.status, bet.customerName, bet.cashback), (BillStatus.success, 'DEMO CUSTOMER 8213', 0));
    final pin = await pay('jamb', '1234567891', 0, plan: 'jamb-utme');
    expect(pin.token, hasLength(14));
  });

  test('insights total the month by category, and budgets alert at 80% and 100%', () async {
    await api.setBudget('data', 180000);
    await api.setBudget(allSpending, 1000000);
    await expectLater(api.setBudget('shoes', 100), throwsA(isA<ApiException>()));

    await api.payBill(
      billerId: 'mtn-data',
      planCode: 'mtn-2gb-7d',
      customer: '08031234567',
      amount: 0,
      pin: '135790',
      idempotencyKey: 'd',
    );
    await send('0123456781', 900000, key: 't1');
    await send('0123456780', 50000, key: 't2'); // declined and refunded
    await api.updateProfile(tag: 'ada');
    await api.sendToAvora(to: '@tolu', amount: 20000, note: '', pin: '135790', idempotencyKey: 'p');
    await api.transfer((await api.statement()).firstWhere((l) => l.ref.isNotEmpty && l.kind == 'transfer_hold').ref);

    final i = await api.insights();
    expect(i.month, DateTime(2026, 10));
    expect(i.moneyIn, DemoAvoraApi.welcomeCredit + 4500); // welcome credit and ₦45 cashback
    expect(i.cashback, 4500);
    expect(
      [for (final c in i.categories) '${c.category} ${c.amount}/${c.budget} x${c.count}'],
      ['transfers 900000/0 x2', 'data 150000/180000 x1', 'avora 20000/0 x1'],
    );
    expect(i.moneyOut, 1070000);
    expect(i.days[22], 1070000);

    final (items, _) = await api.notifications();
    expect(
      items.map((n) => n.title),
      containsAll(["You've reached your monthly budget", '80% of your data budget used']),
    );
    expect(items.where((n) => n.kind == 'budget'), hasLength(2));

    expect((await api.insights(month: DateTime(2026, 9))).moneyOut, 0);
    expect(await api.setBudget('data', 0), {allSpending: 1000000});
  });

  test('cards: freeze, limit, close; round-ups save the change', () async {
    final c = await api.createCard('Netflix');
    expect((c.name, c.frozen, c.last4.length), ('Netflix', false, 4));
    final d = await api.cardDetails(c.id, '135790');
    expect(d.number, hasLength(16));
    expect(d.number.substring(12), c.last4);
    await expectLater(api.cardDetails(c.id, '000000'), throwsA(isA<ApiException>()));

    final pot = await api.createPot(kind: PotKind.goal, name: 'Change', idempotencyKey: 'pot');
    await api.setRoundUp(potId: pot.id, step: 10000);

    final ok = await api.testCardPayment(c.id, merchant: 'Netflix', amount: 440000, key: 'a');
    expect(ok.approved, isTrue);
    expect((await api.testCardPayment(c.id, merchant: 'Netflix', amount: 440000, key: 'a')).id, ok.id);
    await api.freezeCard(c.id, true);
    expect((await api.testCardPayment(c.id, merchant: 'Bolt', amount: 100000, key: 'b')).declineReason, 'card frozen');
    await api.freezeCard(c.id, false);
    await api.setCardLimit(c.id, 500000);
    expect(
      (await api.testCardPayment(c.id, merchant: 'Jumia', amount: 125050, key: 'c')).declineReason,
      'over monthly limit',
    );
    await api.setCardLimit(c.id, 0);
    expect((await api.testCardPayment(c.id, merchant: 'Jumia', amount: 125050, key: 'd')).approved, isTrue);

    // ₦4,400 is already round; ₦1,250.50 rounds up by ₦49.50.
    final (pots, _) = await api.savings();
    expect(pots.single.balance, 4950);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 440000 - 125050 - 4950);
    final card = (await api.cards()).cards.single;
    expect((card.spentThisMonth, card.monthlyLimit), (565050, 0));
    expect(await api.cardPayments(c.id), hasLength(4));
    expect((await api.insights()).categories.first.category, 'cards');

    await api.closeCard(c.id, '135790');
    expect((await api.cards()).cards, isEmpty);
    await api.setRoundUp(potId: '', step: 10000);
    expect((await api.roundUp()).on, isFalse);
  });

  test('schedules run on their date, skip ahead, and say when they fail', () async {
    final weekly = await api.createSchedule(
      kind: ScheduleKind.avora,
      name: 'Pocket money',
      amount: 300000,
      frequency: Frequency.weekly,
      startsAt: now,
      target: const ScheduleTarget(to: '@TOLU'),
      pin: '135790',
    );
    expect((weekly.target.to, weekly.target.accountName), ('@tolu', 'Tolu Adeyemi'));
    await expectLater(
      api.createSchedule(
        kind: ScheduleKind.avora,
        name: '',
        amount: 100,
        frequency: Frequency.once,
        startsAt: now,
        target: const ScheduleTarget(to: '@tolu'),
        pin: '000000',
      ),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wrong_pin')),
    );

    // Opening the list pays what's due and moves it to next week.
    var list = (await api.schedules()).schedules;
    expect((list.single.runs, list.single.lastOk, list.single.nextRun), (1, true, DateTime(2026, 10, 30, 12)));
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 300000);
    expect((await api.notifications()).$1.first.title, 'Scheduled: ₦3,000.00 for Pocket money');

    // Three weeks away pays once, not three times.
    now = DateTime(2026, 11, 20, 13);
    list = (await api.schedules()).schedules;
    expect((list.single.runs, list.single.nextRun), (2, DateTime(2026, 11, 27, 12)));

    await api.pauseSchedule(weekly.id, true);
    now = DateTime(2026, 12, 20, 13);
    expect((await api.schedules()).schedules.single.runs, 2);
    final resumed = await api.pauseSchedule(weekly.id, false);
    expect(resumed.nextRun, DateTime(2026, 12, 25, 12));

    final big = await api.createSchedule(
      kind: ScheduleKind.transfer,
      name: 'Car',
      amount: 4900000,
      frequency: Frequency.once,
      startsAt: now,
      target: const ScheduleTarget(bankCode: '058', accountNumber: '0123456781'),
      pin: '135790',
    );
    final ran = await api.runScheduleNow(big.id);
    expect((ran.lastOk, ran.lastMessage, ran.done), (false, 'Your balance was too low.', true));
    expect((await api.notifications()).$1.first.title, "Car didn't go");

    await api.cancelSchedule(weekly.id);
    expect((await api.schedules()).schedules.map((s) => s.name), ['Car']);
  });

  test('monthly schedules keep the day, or use the last day of a short month', () {
    final start = DateTime(2026, 1, 31, 9);
    expect(Frequency.monthly.at(start, 1), DateTime(2026, 2, 28, 9));
    expect(Frequency.monthly.at(start, 2), DateTime(2026, 3, 31, 9));
    expect(Frequency.monthly.at(start, 12), DateTime(2027, 1, 31, 9));
    expect(Frequency.weekly.at(start, 1), DateTime(2026, 2, 7, 9));
  });

  test('splits: friends pay or decline, each once', () async {
    // Tolu asked every new customer to chip in for suya.
    final asked = (await api.splits()).single;
    expect((asked.title, asked.awaitingMe, asked.myShare!.amount), ('Suya night', true, 250000));
    final paid = await api.paySplit(asked.id, '135790');
    expect(paid.myShare!.status, ShareStatus.paid);
    await expectLater(
      api.paySplit(asked.id, '135790'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'split_settled')),
    );
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 250000);

    await expectLater(
      api.createSplit(title: 'Dinner', total: 900000, people: [('@tolu', 600000), ('@chidi', 600000)]),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_request')),
    );
    final mine = await api.createSplit(
      title: 'Dinner',
      total: 900000,
      people: [('@tolu', 300000), ('08011110002', 300000)],
    );
    expect((mine.mine, mine.collected, mine.pendingCount), (true, 0, 2));

    // Demo friends pay a few seconds later.
    now = now.add(const Duration(seconds: 10));
    final later = await api.split(mine.id);
    expect((later.collected, later.pendingCount), (600000, 0));
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 250000 + 600000);
    expect((await api.notifications()).$1.first.kind, 'split');
  });
}
