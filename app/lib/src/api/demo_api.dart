import 'dart:async';
import 'dart:math';

import '../credentials.dart';
import '../ids.dart';
import '../money.dart';
import 'api.dart';
import 'bill_catalog.dart';
import 'help_catalog.dart';
import 'models.dart';

/// An in-memory stand-in for the backend, so the app can be tried with no
/// server and no real money. It follows the backend's sandbox rules:
///
/// * the sign-in code is always 000000;
/// * new customers get a ₦50,000 demo credit;
/// * account numbers ending in 8 are not found, 0 are declined and refunded,
///   9 stay with the bank for a few seconds, and anything else is delivered;
/// * 5 free transfers a month, then ₦10 each;
/// * bills: meter or smartcard numbers ending in 8 are not found, and a
///   phone, meter or smartcard ending in 0 fails and is refunded;
/// * KYC: any 11-digit BVN or NIN is accepted except ones ending in 0, and
///   the tiers' daily limits apply as on the server.
class DemoAvoraApi implements AvoraApi {
  DemoAvoraApi({required this.credentials, DateTime Function()? clock, this.pendingFor = const Duration(seconds: 6)})
    : _now = clock ?? DateTime.now {
    // A few people to find and pay by @tag in the demo.
    for (final (phone, name, tag) in demoPeople) {
      final u = _DemoUser(_users.length + 1, '90${phone.substring(phone.length - 8)}', '135790')
        ..phone = phone
        ..name = name
        ..tag = tag;
      _users[phone] = u;
    }
  }

  /// Demo customers anyone can send to.
  static const demoPeople = [
    ('08011110001', 'Tolu Adeyemi', 'tolu'),
    ('08011110002', 'Chidi Okafor', 'chidi'),
    ('08011110003', 'Amina Bello', 'amina'),
  ];

  static const code = '000000';
  static const welcomeCredit = 5000000;
  static const freeTransfers = 5;
  static const feeAfterFree = 1000;

  final Credentials credentials;
  final DateTime Function() _now;
  final Duration pendingFor;

  final _challenges = <String, String>{}; // challenge id -> phone
  final _users = <String, _DemoUser>{}; // phone -> user
  final _tokens = <String, _DemoUser>{};

  @override
  bool get isDemo => true;

  _DemoUser get _me {
    final u = _tokens[credentials.token];
    if (u == null) throw ApiException('unauthorized', 'Please sign in again.', status: 401);
    return u;
  }

  @override
  Future<String> startOtp(String phone) async {
    final id = randomId();
    _challenges[id] = phone;
    return id;
  }

  @override
  Future<Session> verify({required String challengeId, required String code, required String pin}) async {
    final phone = _challenges[challengeId];
    if (phone == null || code != DemoAvoraApi.code) {
      throw ApiException('invalid_code', 'That code is wrong or has expired.', status: 401);
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw ApiException('invalid_request', 'PIN must be 6 digits.', status: 400);
    }
    final known = _users[phone];
    if (known != null && known.pin != pin) throw ApiException('wrong_pin', 'That PIN is wrong.', status: 401);
    _challenges.remove(challengeId);

    final newUser = known == null;
    if (newUser) {
      final u = _DemoUser(_users.length + 1, '90${phone.substring(phone.length - 8)}', pin)..phone = phone;
      u.lines.add(
        StatementLine(
          kind: 'inbound_credit',
          description: 'Welcome credit (demo money)',
          ref: '',
          amount: welcomeCredit,
          at: _now(),
        ),
      );
      u.balance = welcomeCredit;
      u.devices.add(Device(id: 1, name: 'This phone', boundAt: _now(), thisPhone: true, signedIn: true));
      _notify(
        u,
        'account',
        'Welcome to Avora',
        'We added ${formatNaira(welcomeCredit)} of demo money so you can try things out.',
      );
      _users[phone] = u;
    }
    final token = randomId();
    _tokens[token] = _users[phone]!;
    await credentials.setToken(token);
    return Session(token: token, walletId: _users[phone]!.id, newUser: newUser, newDevice: newUser);
  }

  @override
  Future<Wallet> wallet() async {
    final u = _me;
    return Wallet(id: u.id, accountNumber: u.accountNumber, balance: u.balance);
  }

  @override
  Future<List<StatementLine>> statement() async {
    final u = _me;
    for (final t in u.transfers.values) {
      _settle(u, t);
    }
    return u.lines.reversed.toList();
  }

  @override
  Future<String> nameEnquiry({required String bankCode, required String accountNumber}) async {
    _me;
    if (!RegExp(r'^\d{10}$').hasMatch(accountNumber) || accountNumber.endsWith('8')) {
      throw ApiException('account_not_found', 'No account found with that number at that bank.', status: 404);
    }
    return 'DEMO USER ${accountNumber.substring(6)}';
  }

  @override
  Future<Quote> quote(int amount) async {
    if (amount <= 0) throw ApiException('invalid_request', 'Amount must be more than zero.', status: 400);
    final left = freeTransfers - _usedThisMonth(_me);
    final fee = left > 0 ? 0 : feeAfterFree;
    return Quote(amount: amount, fee: fee, total: amount + fee, freeTransfersLeft: left > 0 ? left : 0);
  }

  int _usedThisMonth(_DemoUser u) {
    final now = _now();
    return u.transfers.values.where((t) => t.createdAt.year == now.year && t.createdAt.month == now.month).length;
  }

  @override
  Future<Transfer> send({
    required String bankCode,
    required String accountNumber,
    required int amount,
    required String narration,
    required String pin,
    required String idempotencyKey,
  }) async {
    final u = _me;
    final existing = u.byKey[idempotencyKey];
    if (existing != null) return transfer(existing);
    if (u.pin != pin) {
      throw ApiException('wrong_pin', 'That PIN is wrong.', status: 401);
    }
    final name = await nameEnquiry(bankCode: bankCode, accountNumber: accountNumber);
    final q = await quote(amount);
    _checkLimit(u, amount);
    if (q.total > u.balance) {
      throw ApiException('insufficient_funds', 'Your balance is too low for this transfer and its fee.', status: 422);
    }

    final id = randomId();
    final t = Transfer(
      id: id,
      bankCode: bankCode,
      accountNumber: accountNumber,
      accountName: name,
      narration: narration,
      amount: amount,
      fee: q.fee,
      status: TransferStatus.sent,
      sessionId: '',
      failureReason: '',
      createdAt: _now(),
    );
    u.balance -= q.total;
    u.lines.add(
      StatementLine(
        kind: 'transfer_hold',
        description: 'Transfer to $name ($accountNumber)',
        ref: id,
        amount: -q.total,
        at: t.createdAt,
      ),
    );
    u.transfers[id] = t;
    u.byKey[idempotencyKey] = id;
    _budgetAlerts(u);
    return transfer(id);
  }

  /// Moves a sent transfer to its final state once the sandbox rule says so.
  Transfer _settle(_DemoUser u, Transfer t) {
    if (t.status != TransferStatus.sent) return t;
    final last = t.accountNumber[9];
    if (last == '9' && _now().difference(t.createdAt) < pendingFor) return t;

    final declined = last == '0';
    final done = Transfer(
      id: t.id,
      bankCode: t.bankCode,
      accountNumber: t.accountNumber,
      accountName: t.accountName,
      narration: t.narration,
      amount: t.amount,
      fee: t.fee,
      status: declined ? TransferStatus.refunded : TransferStatus.delivered,
      sessionId: 'DEMO${t.id.substring(0, 12).toUpperCase()}',
      failureReason: declined ? 'beneficiary bank declined' : '',
      createdAt: t.createdAt,
    );
    u.transfers[t.id] = done;
    if (declined) {
      _notify(
        u,
        'transfer',
        'Transfer refunded',
        "Your transfer to ${t.accountName} didn't go through. ${formatNaira(t.amount + t.fee)} is back in your wallet.",
        t.id,
      );
    } else {
      _notify(u, 'transfer', 'Transfer delivered', '${formatNaira(t.amount)} reached ${t.accountName}.', t.id);
    }
    if (declined) {
      u.balance += t.amount + t.fee;
      u.lines.add(
        StatementLine(
          kind: 'transfer_refund',
          description: 'Refund: transfer to ${t.accountName} did not go through',
          ref: t.id,
          amount: t.amount + t.fee,
          at: _now(),
        ),
      );
    }
    return done;
  }

  @override
  Future<Transfer> transfer(String id) async {
    final u = _me;
    final t = u.transfers[id];
    if (t == null) throw ApiException('not_found', 'Not found.', status: 404);
    return _settle(u, t);
  }

  final _billers = demoBillers();

  Biller _biller(String id) => _billers.firstWhere(
    (b) => b.id == id,
    orElse: () => throw ApiException('invalid_request', 'Unknown biller.', status: 400),
  );

  @override
  Future<List<Biller>> billers() async {
    _me;
    return _billers;
  }

  @override
  Future<String> validateBillCustomer({required String billerId, required String customer}) async {
    _me;
    final b = _biller(billerId);
    final ok = b.category == BillCategory.betting
        ? RegExp(r'^[A-Za-z0-9]{4,20}$').hasMatch(customer)
        : RegExp(r'^\d{10,13}$').hasMatch(customer);
    if (!ok || (b.needsLookup && customer.endsWith('8'))) {
      throw ApiException('customer_not_found', 'We could not find that ${b.customerLabel.toLowerCase()}.', status: 404);
    }
    return b.needsLookup ? 'DEMO CUSTOMER ${customer.substring(customer.length - 4)}' : '';
  }

  @override
  Future<BillPayment> payBill({
    required String billerId,
    String? planCode,
    required String customer,
    required int amount,
    required String pin,
    required String idempotencyKey,
  }) async {
    final u = _me;
    final existing = u.billsByKey[idempotencyKey];
    if (existing != null) return u.bills[existing]!;
    if (u.pin != pin) throw ApiException('wrong_pin', 'That PIN is wrong.', status: 401);

    final b = _biller(billerId);
    BillPlan? plan;
    if (b.hasPlans) {
      plan = b.plans.firstWhere(
        (p) => p.code == planCode,
        orElse: () => throw ApiException('invalid_request', 'Choose a plan.', status: 400),
      );
      amount = plan.amount;
    } else if (amount < b.minAmount || amount > b.maxAmount) {
      throw ApiException('invalid_request', 'Amount must be between the minimum and maximum.', status: 400);
    }
    final name = await validateBillCustomer(billerId: billerId, customer: customer);
    _checkLimit(u, amount);
    if (amount > u.balance) {
      throw ApiException('insufficient_funds', 'Your balance is too low for this payment.', status: 422);
    }

    final id = randomId();
    final failed = customer.endsWith('0');
    final what = billDescription(b, plan?.name ?? '', customer);
    final cashback = failed ? 0 : b.cashback(amount);
    final pay = BillPayment(
      id: id,
      billerId: b.id,
      billerName: b.name,
      category: b.category,
      planName: plan?.name ?? '',
      customer: customer,
      customerName: name,
      amount: amount,
      cashback: cashback,
      status: failed ? BillStatus.refunded : BillStatus.success,
      token: failed
          ? ''
          : switch (b.category) {
              BillCategory.electricity => _token(),
              BillCategory.education => _token(12),
              _ => '',
            },
      reference: 'DEMOBILL${id.substring(0, 10).toUpperCase()}',
      failureReason: failed ? 'biller declined' : '',
      createdAt: _now(),
    );
    u.balance -= amount;
    u.lines.add(StatementLine(kind: 'bill_payment', description: what, ref: id, amount: -amount, at: pay.createdAt));
    if (cashback > 0) {
      u.balance += cashback;
      u.lines.add(
        StatementLine(kind: 'cashback', description: 'Cashback: $what', ref: id, amount: cashback, at: _now()),
      );
    }
    if (failed) {
      _notify(
        u,
        'bill',
        'Payment refunded',
        "$what didn't go through. ${formatNaira(amount)} is back in your wallet.",
        id,
      );
      u.balance += amount;
      u.lines.add(
        StatementLine(kind: 'bill_refund', description: 'Refund: $what', ref: id, amount: amount, at: _now()),
      );
    }
    u.bills[id] = pay;
    u.billsByKey[idempotencyKey] = id;
    _budgetAlerts(u);
    return pay;
  }

  String _token([int n = 20]) {
    final digits = randomId().codeUnits.map((c) => c % 10).take(n).join();
    return [for (var i = 0; i < n; i += 4) digits.substring(i, i + 4)].join('-');
  }

  @override
  Future<BillPayment> billPayment(String id) async {
    final p = _me.bills[id];
    if (p == null) throw ApiException('not_found', 'Not found.', status: 404);
    return p;
  }

  final rates = SavingsRates(
    goalBps: 800,
    terms: [
      SavingsTerm(days: 30, rateBps: 1000),
      SavingsTerm(days: 90, rateBps: 1200),
      SavingsTerm(days: 180, rateBps: 1400),
      SavingsTerm(days: 365, rateBps: 1600),
    ],
  );

  @override
  Future<(List<SavingsPot>, SavingsRates)> savings() async {
    final u = _me;
    final pots = u.pots.values.toList()
      ..sort((a, b) => a.open == b.open ? b.createdAt.compareTo(a.createdAt) : (a.open ? -1 : 1));
    return (pots, rates);
  }

  void _move(_DemoUser u, int fromWallet, String kind, String description, String ref) {
    if (fromWallet > 0 && fromWallet > u.balance) {
      throw ApiException('insufficient_funds', 'Your balance is too low for this.', status: 422);
    }
    u.balance -= fromWallet;
    u.lines.add(StatementLine(kind: kind, description: description, ref: ref, amount: -fromWallet, at: _now()));
  }

  SavingsPot _pot(SavingsPot p, {int? balance, int? profit, bool? open}) => SavingsPot(
    id: p.id,
    kind: p.kind,
    name: p.name,
    target: p.target,
    lockDays: p.lockDays,
    maturesAt: p.maturesAt,
    balance: balance ?? p.balance,
    profitEarned: profit ?? p.profitEarned,
    expectedRateBps: p.expectedRateBps,
    open: open ?? p.open,
    createdAt: p.createdAt,
  );

  @override
  Future<SavingsPot> createPot({
    required PotKind kind,
    required String name,
    int target = 0,
    int lockDays = 0,
    int amount = 0,
    required String idempotencyKey,
  }) async {
    final u = _me;
    final existing = u.potsByKey[idempotencyKey];
    if (existing != null) return u.pots[existing]!;
    name = name.trim();
    if (name.isEmpty || name.length > 40) {
      throw ApiException('invalid_request', 'Give it a name of up to 40 characters.', status: 400);
    }
    int rate = rates.goalBps;
    if (kind == PotKind.locked) {
      final term = rates.terms.where((t) => t.days == lockDays);
      if (term.isEmpty) throw ApiException('invalid_request', 'Choose one of the offered terms.', status: 400);
      if (amount < 100000) throw ApiException('invalid_request', 'A locked plan starts at ₦1,000.', status: 400);
      rate = term.first.rateBps;
    }
    final id = randomId();
    if (amount > 0) _move(u, amount, 'savings_deposit', 'Saved to $name', id);
    final now = _now();
    final pot = SavingsPot(
      id: id,
      kind: kind,
      name: name,
      target: kind == PotKind.goal ? target : 0,
      lockDays: kind == PotKind.locked ? lockDays : 0,
      maturesAt: kind == PotKind.locked ? now.add(Duration(days: lockDays)) : null,
      balance: amount,
      profitEarned: 0,
      expectedRateBps: rate,
      open: true,
      createdAt: now,
    );
    u.pots[id] = pot;
    u.potsByKey[idempotencyKey] = id;
    return pot;
  }

  SavingsPot _ownPot(_DemoUser u, String id) {
    final p = u.pots[id];
    if (p == null) throw ApiException('not_found', 'Not found.', status: 404);
    if (!p.open) throw ApiException('savings_closed', 'This savings pot is closed.', status: 409);
    return p;
  }

  @override
  Future<SavingsPot> depositToPot(String id, int amount, {required String idempotencyKey}) async {
    final u = _me;
    if (!u.potMoves.add(idempotencyKey)) return u.pots[id]!;
    final p = _ownPot(u, id);
    if (p.kind == PotKind.locked) {
      throw ApiException('savings_locked', 'Start a new plan to lock more money.', status: 409);
    }
    if (amount <= 0) throw ApiException('invalid_request', 'Amount must be more than zero.', status: 400);
    try {
      _move(u, amount, 'savings_deposit', 'Saved to ${p.name}', id);
    } catch (_) {
      u.potMoves.remove(idempotencyKey);
      rethrow;
    }
    return u.pots[id] = _pot(p, balance: p.balance + amount);
  }

  @override
  Future<SavingsPot> withdrawFromPot(
    String id, {
    int amount = 0,
    bool breakEarly = false,
    required String idempotencyKey,
  }) async {
    final u = _me;
    if (u.potMoves.contains(idempotencyKey)) return u.pots[id]!;
    final p = _ownPot(u, id);
    var forfeit = 0;
    if (p.kind == PotKind.goal) {
      if (amount <= 0) throw ApiException('invalid_request', 'Amount must be more than zero.', status: 400);
      if (amount > p.balance) {
        throw ApiException('insufficient_funds', 'That is more than this pot holds.', status: 422);
      }
    } else {
      final early = !p.isMatured(_now());
      if (early && !breakEarly) {
        throw ApiException(
          'savings_locked',
          "This plan is locked until it matures. You can break it early, but you'll give back its profit share.",
          status: 409,
        );
      }
      amount = p.balance;
      if (early) forfeit = p.profitEarned;
    }
    u.potMoves.add(idempotencyKey);
    _move(
      u,
      -(amount - forfeit),
      'savings_withdraw',
      forfeit > 0 ? 'From ${p.name} (broken early, profit share returned)' : 'From ${p.name}',
      id,
    );
    return u.pots[id] = _pot(
      p,
      balance: p.balance - amount,
      profit: p.profitEarned - forfeit,
      open: p.kind == PotKind.goal,
    );
  }

  /// Demo only: shares a month of profit at the expected rates, so the
  /// savings screens can be tried.
  void shareDemoProfit() {
    final u = _me;
    for (final p in u.pots.values.toList()) {
      if (!p.open || p.balance <= 0) continue;
      final share = p.balance * p.expectedRateBps ~/ 10000 ~/ 12;
      u.pots[p.id] = _pot(p, balance: p.balance + share, profit: p.profitEarned + share);
    }
  }

  void _notify(_DemoUser u, String kind, String title, String body, [String ref = '']) => u.notifications.add(
    AppNotification(
      id: u.notifications.length + 1,
      kind: kind,
      title: title,
      body: body,
      ref: ref,
      createdAt: _now(),
      read: false,
    ),
  );

  static final tiers = [
    KycTier(tier: 1, dailySend: 5000000, maxBalance: 30000000, needs: 'Phone number'),
    KycTier(tier: 2, dailySend: 20000000, maxBalance: 50000000, needs: 'BVN or NIN'),
    KycTier(tier: 3, dailySend: 500000000, maxBalance: 0, needs: 'BVN and NIN'),
  ];

  int _tier(_DemoUser u) => u.bvn && u.nin ? 3 : (u.bvn || u.nin ? 2 : 1);

  /// Transfers and bills since midnight count against the tier's daily limit.
  void _checkLimit(_DemoUser u, int amount) {
    final now = _now();
    final midnight = DateTime(now.year, now.month, now.day);
    final today =
        u.transfers.values
            .where((t) => !t.createdAt.isBefore(midnight) && t.status != TransferStatus.refunded)
            .fold<int>(0, (a, t) => a + t.amount) +
        u.bills.values
            .where((b) => !b.createdAt.isBefore(midnight) && b.status != BillStatus.refunded)
            .fold<int>(0, (a, b) => a + b.amount) +
        u.p2p.values.where((t) => t.outgoing && !t.createdAt.isBefore(midnight)).fold<int>(0, (a, t) => a + t.amount);
    final tier = _tier(u);
    final limit = tiers[tier - 1].dailySend;
    if (today + amount > limit) {
      var msg =
          'Tier $tier accounts can send up to ${formatNaira(limit)} a day, and you have '
          '${formatNaira(max(0, limit - today))} left today.';
      if (tier < 3) msg += ' Verify your BVN or NIN under Me → Limits to raise it.';
      throw ApiException('daily_limit', msg, status: 403);
    }
  }

  @override
  Future<void> changePin({required String oldPin, required String newPin}) async {
    final u = _me;
    if (u.pin != oldPin) throw ApiException('wrong_pin', 'That PIN is wrong.', status: 401);
    if (!RegExp(r'^\d{6}$').hasMatch(newPin)) {
      throw ApiException('invalid_request', 'PIN must be 6 digits.', status: 400);
    }
    if (newPin == oldPin) {
      throw ApiException('invalid_request', 'Choose a PIN different from your current one.', status: 400);
    }
    u.pin = newPin;
    _notify(
      u,
      'security',
      'PIN changed',
      "Your PIN was changed and your other phones were signed out. If this wasn't you, contact support now.",
    );
  }

  @override
  Future<void> verifyPin(String pin) async {
    if (_me.pin != pin) throw ApiException('wrong_pin', 'That PIN is wrong.', status: 401);
  }

  @override
  Future<List<Device>> devices() async => List.of(_me.devices);

  @override
  Future<void> removeDevice(int id) async {
    final u = _me;
    final d = u.devices.where((d) => d.id == id).firstOrNull;
    if (d == null) throw ApiException('not_found', 'Not found.', status: 404);
    if (d.thisPhone) {
      throw ApiException('this_device', "This is the phone you're using. Sign out instead.", status: 409);
    }
    u.devices.remove(d);
  }

  @override
  Future<KycStatus> kycStatus() async {
    final u = _me;
    return KycStatus(tier: _tier(u), bvnVerified: u.bvn, ninVerified: u.nin, tiers: tiers);
  }

  @override
  Future<KycStatus> verifyKyc({required String kind, required String number}) async {
    final u = _me;
    if (kind != 'bvn' && kind != 'nin') throw ApiException('invalid_request', 'Choose BVN or NIN.', status: 400);
    if (!RegExp(r'^\d{11}$').hasMatch(number)) {
      throw ApiException('invalid_request', '${kind.toUpperCase()} must be 11 digits.', status: 400);
    }
    if (number.endsWith('0')) {
      throw ApiException(
        'kyc_mismatch',
        "Those details don't match the records. Check the number and try again.",
        status: 422,
      );
    }
    final before = _tier(u);
    if (kind == 'bvn') {
      u.bvn = true;
    } else {
      u.nin = true;
    }
    final after = _tier(u);
    if (before < 2 && after >= 2) _rewardReferrer(u);
    if (after > before) {
      _notify(
        u,
        'account',
        "You're now on Tier $after",
        'You can now send up to ${formatNaira(tiers[after - 1].dailySend)} a day.',
      );
    }
    return kycStatus();
  }

  @override
  Future<(List<AppNotification>, int)> notifications() async {
    final u = _me;
    for (final t in u.transfers.values.toList()) {
      _settle(u, t);
    }
    return (u.notifications.reversed.toList(), u.notifications.where((n) => !n.read).length);
  }

  @override
  Future<void> markNotificationsRead() async {
    final u = _me;
    for (var i = 0; i < u.notifications.length; i++) {
      final n = u.notifications[i];
      if (n.read) continue;
      u.notifications[i] = AppNotification(
        id: n.id,
        kind: n.kind,
        title: n.title,
        body: n.body,
        ref: n.ref,
        createdAt: n.createdAt,
        read: true,
      );
    }
  }

  static String _last10(String phone) {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    return d.length >= 10 ? d.substring(d.length - 10) : d;
  }

  static String _mask(String phone) {
    final d = _last10(phone);
    return d.length == 10 ? '0${d.substring(0, 3)} *** ${d.substring(6)}' : '';
  }

  Person _person(_DemoUser u) =>
      Person(tag: u.tag, name: u.name.isEmpty ? 'Avora customer' : u.name, phone: _mask(u.phone));

  static String _who(_DemoUser u) => switch ((u.name, u.tag)) {
    ('', '') => 'an Avora customer',
    ('', final t) => '@$t',
    (final n, '') => n,
    (final n, final t) => '$n (@$t)',
  };

  @override
  Future<Profile> profile() async {
    final u = _me;
    return Profile(name: u.name, tag: u.tag, phone: u.phone, accountNumber: u.accountNumber);
  }

  static const _reserved = {
    'avora',
    'admin',
    'support',
    'help',
    'official',
    'security',
    'tajbank',
    'cbn',
    'agent',
    'staff',
  };

  @override
  Future<Profile> updateProfile({String name = '', String tag = ''}) async {
    final u = _me;
    final n = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
    final t = tag.trim().replaceFirst('@', '').toLowerCase();
    if (n.isNotEmpty && (n.length < 2 || n.length > 40)) {
      throw ApiException('invalid_request', 'Name must be 2 to 40 characters.', status: 400);
    }
    if (t.isNotEmpty) {
      if (!RegExp(r'^[a-z][a-z0-9_]{2,19}$').hasMatch(t)) {
        throw ApiException(
          'invalid_request',
          'A tag is 3 to 20 letters, numbers or _, starting with a letter.',
          status: 400,
        );
      }
      if (_reserved.contains(t) || _users.values.any((x) => x != u && x.tag == t)) {
        throw ApiException('tag_taken', 'That tag is taken. Try another.', status: 409);
      }
      u.tag = t;
    }
    if (n.isNotEmpty) u.name = n;
    return profile();
  }

  _DemoUser _find(String query) {
    final me = _me;
    final q = query.trim();
    _DemoUser? found;
    if (q.startsWith('@') || (q.isNotEmpty && !RegExp(r'^[+\d]').hasMatch(q))) {
      final t = q.replaceFirst('@', '').toLowerCase();
      found = _users.values.where((x) => x.tag.isNotEmpty && x.tag == t).firstOrNull;
    } else {
      final d = _last10(q);
      if (d.length != 10) throw ApiException('invalid_request', 'Enter an @tag or a phone number.', status: 400);
      found = _users.values.where((x) => _last10(x.phone) == d).firstOrNull;
    }
    if (found == null) {
      throw ApiException('person_not_found', 'No Avora customer has that tag or phone number.', status: 404);
    }
    if (found == me) throw ApiException('self', "That's you. Pick someone else.", status: 400);
    return found;
  }

  @override
  Future<Person> findPerson(String query) async => _person(_find(query));

  @override
  Future<P2PTransfer> sendToAvora({
    required String to,
    required int amount,
    required String note,
    required String pin,
    required String idempotencyKey,
  }) async {
    final u = _me;
    final existing = u.p2pByKey[idempotencyKey];
    if (existing != null) return u.p2p[existing]!;
    if (u.pin != pin) throw ApiException('wrong_pin', 'That PIN is wrong.', status: 401);
    if (amount <= 0) throw ApiException('invalid_request', 'Amount must be more than zero.', status: 400);
    _checkLimit(u, amount);
    final other = _find(to);
    if (amount > u.balance) {
      throw ApiException(
        'insufficient_funds',
        'Your balance is too low for this payment, including any fee.',
        status: 422,
      );
    }
    final id = randomId();
    final at = _now();
    final n = note.trim();
    u.balance -= amount;
    other.balance += amount;
    u.lines.add(StatementLine(kind: 'p2p_out', description: 'To ${_who(other)}', ref: id, amount: -amount, at: at));
    other.lines.add(StatementLine(kind: 'p2p_in', description: 'From ${_who(u)}', ref: id, amount: amount, at: at));
    u.p2p[id] = P2PTransfer(id: id, outgoing: true, amount: amount, note: n, other: _person(other), createdAt: at);
    other.p2p[id] = P2PTransfer(id: id, outgoing: false, amount: amount, note: n, other: _person(u), createdAt: at);
    u.p2pByKey[idempotencyKey] = id;
    _notify(other, 'money_in', '${formatNaira(amount)} received', 'From ${_who(u)}${n.isEmpty ? '' : ': $n'}', id);
    _budgetAlerts(u);
    return u.p2p[id]!;
  }

  static const _budgetLabels = {
    allSpending: 'monthly',
    'transfers': 'bank transfers',
    'avora': 'Avora transfers',
    'airtime': 'airtime',
    'data': 'data',
    'electricity': 'electricity',
    'tv': 'TV',
    'internet': 'internet',
    'education': 'exam PINs',
    'betting': 'betting',
    'other': 'other',
  };

  /// The spending category a statement line counts toward, or null if it
  /// isn't spending. Refunds count against the payment they reverse.
  String? _bucket(_DemoUser u, StatementLine l) => switch (l.kind) {
    'transfer_hold' || 'transfer_refund' => 'transfers',
    'bill_payment' || 'bill_refund' => u.bills[l.ref]?.category.name,
    'p2p_out' => 'avora',
    'p2p_in' || 'savings_deposit' || 'savings_withdraw' || 'cashback' => null,
    _ => l.amount < 0 ? 'other' : null,
  };

  Insights _insights(_DemoUser u, DateTime month) {
    final start = DateTime(month.year, month.month);
    final end = DateTime(month.year, month.month + 1);
    final prevStart = DateTime(month.year, month.month - 1);
    final days = List.filled(end.subtract(const Duration(days: 1)).day, 0);
    final spent = <String, int>{};
    final counts = <String, int>{};
    var moneyIn = 0, saved = 0, cashback = 0, previous = 0;
    for (final l in u.lines) {
      final b = _bucket(u, l);
      if (!l.at.isBefore(prevStart) && l.at.isBefore(start)) {
        if (b != null) previous -= l.amount;
        continue;
      }
      if (l.at.isBefore(start) || !l.at.isBefore(end)) continue;
      if (b != null) {
        spent[b] = (spent[b] ?? 0) - l.amount;
        if (!l.kind.endsWith('_refund')) counts[b] = (counts[b] ?? 0) + 1;
        days[l.at.day - 1] -= l.amount;
      } else if (l.kind.startsWith('savings_')) {
        saved -= l.amount;
      } else if (l.amount > 0) {
        moneyIn += l.amount;
        if (l.kind == 'cashback') cashback += l.amount;
      }
    }
    final cats = [
      for (final c in spendCategories)
        if (spent.containsKey(c) || u.budgets.containsKey(c))
          SpendCategory(category: c, amount: max(spent[c] ?? 0, 0), count: counts[c] ?? 0, budget: u.budgets[c] ?? 0),
    ]..sort((a, b) => b.amount - a.amount);
    return Insights(
      month: start,
      moneyIn: moneyIn,
      moneyOut: cats.fold(0, (a, c) => a + c.amount),
      saved: saved,
      cashback: cashback,
      previousOut: max(previous, 0),
      budget: u.budgets[allSpending] ?? 0,
      categories: cats,
      days: [for (final d in days) max(d, 0)],
    );
  }

  /// Tells the customer once a month when a budget reaches 80%, then 100%.
  void _budgetAlerts(_DemoUser u) {
    final m = _insights(u, _now());
    final month = '${m.month.year}-${m.month.month}';
    for (final (c, spent, budget) in [
      (allSpending, m.moneyOut, m.budget),
      for (final c in m.categories) (c.category, c.amount, c.budget),
    ]) {
      if (budget == 0 || spent * 100 < budget * 80) continue;
      final full = spent >= budget;
      if (!u.budgetAlerts.add('$month $c ${full ? 100 : 80}')) continue;
      _notify(
        u,
        'budget',
        full ? "You've reached your ${_budgetLabels[c]} budget" : '80% of your ${_budgetLabels[c]} budget used',
        "You've spent ${formatNaira(spent)} of ${formatNaira(budget)} this month.",
      );
    }
  }

  @override
  Future<Insights> insights({DateTime? month}) async => _insights(_me, month ?? _now());

  @override
  Future<Map<String, int>> budgets() async => Map.of(_me.budgets);

  @override
  Future<Map<String, int>> setBudget(String category, int amount) async {
    final u = _me;
    if (category != allSpending && !spendCategories.contains(category)) {
      throw ApiException('invalid_request', 'Unknown category.', status: 400);
    }
    if (amount < 0) throw ApiException('invalid_request', 'A budget cannot be negative.', status: 400);
    if (amount == 0) {
      u.budgets.remove(category);
    } else {
      u.budgets[category] = amount;
    }
    return budgets();
  }

  @override
  Future<P2PTransfer> p2pTransfer(String id) async {
    final t = _me.p2p[id];
    if (t == null) throw ApiException('not_found', 'Not found.', status: 404);
    return t;
  }

  static const referralReward = 50000;

  String _code(_DemoUser u) => 'AVDEMO${u.id.toString().padLeft(2, '0')}';

  @override
  Future<ReferralSummary> referrals() async {
    final u = _me;
    final invited = _users.values.where((x) => x.referrer == u).toList();
    final rewarded = invited.where((x) => x.referralPaid).length;
    return ReferralSummary(
      code: _code(u),
      reward: referralReward,
      invited: invited.length,
      rewarded: rewarded,
      earned: rewarded * referralReward,
      joinedWith: u.referrer == null ? '' : _code(u.referrer!),
      canAddCode: u.referrer == null,
    );
  }

  @override
  Future<ReferralSummary> joinReferral(String code) async {
    final u = _me;
    final c = code.trim().toUpperCase();
    if (c.isEmpty) throw ApiException('invalid_request', 'Enter a code.', status: 400);
    final referrer = _users.values.where((x) => _code(x) == c).firstOrNull;
    if (referrer == null) {
      throw ApiException('unknown_code', "We don't recognise that invite code. Check it and try again.", status: 404);
    }
    if (referrer == u) {
      throw ApiException('own_code', "That's your own invite code. Share it with friends instead.", status: 400);
    }
    if (u.referrer != null) {
      throw ApiException('code_used', "You've already joined with an invite code.", status: 409);
    }
    u.referrer = referrer;
    if (_tier(u) >= 2) _rewardReferrer(u);
    return referrals();
  }

  void _rewardReferrer(_DemoUser u) {
    final r = u.referrer;
    if (r == null || u.referralPaid) return;
    u.referralPaid = true;
    r.balance += referralReward;
    r.lines.add(
      StatementLine(
        kind: 'referral_reward',
        description: 'Referral reward',
        ref: '',
        amount: referralReward,
        at: _now(),
      ),
    );
    _notify(
      r,
      'money_in',
      '${formatNaira(referralReward)} referral reward',
      'A friend you invited just verified their account. Thanks for spreading the word!',
    );
  }

  @override
  Future<List<HelpArticle>> helpArticles() async => demoHelpArticles();

  @override
  Future<List<SupportMessage>> supportMessages() async => List.of(_me.support);

  @override
  Future<List<SupportMessage>> sendSupportMessage(String body) async {
    final u = _me;
    final text = body.trim();
    if (text.isEmpty) throw ApiException('invalid_request', 'Write a message.', status: 400);
    u.support.add(SupportMessage(id: u.support.length + 1, sender: 'customer', body: text, createdAt: _now()));
    u.support.add(
      SupportMessage(id: u.support.length + 1, sender: 'bot', body: supportAnswer(text), createdAt: _now()),
    );
    return List.of(u.support);
  }

  @override
  Future<void> logout() async {
    _tokens.remove(credentials.token);
    await credentials.setToken(null);
  }
}

class _DemoUser {
  _DemoUser(this.id, this.accountNumber, this.pin);

  final int id;
  final String accountNumber;
  String pin;
  int balance = 0;
  bool bvn = false;
  bool nin = false;
  final devices = <Device>[];
  String phone = '';
  String name = '';
  String tag = '';
  final p2p = <String, P2PTransfer>{};
  final p2pByKey = <String, String>{};
  final support = <SupportMessage>[];
  _DemoUser? referrer;
  bool referralPaid = false;
  final notifications = <AppNotification>[];
  final lines = <StatementLine>[];
  final transfers = <String, Transfer>{};
  final byKey = <String, String>{};
  final bills = <String, BillPayment>{};
  final billsByKey = <String, String>{};
  final pots = <String, SavingsPot>{};
  final potsByKey = <String, String>{};
  final potMoves = <String>{};
  final budgets = <String, int>{};
  final budgetAlerts = <String>{}; // "2026-10 data 80"
}

/// How a bill payment reads on the statement; the backend uses the same words.
String billDescription(Biller b, String plan, String customer) => switch (b.category) {
  BillCategory.airtime => '${b.name} airtime · $customer',
  BillCategory.data => '${b.name} data $plan · $customer',
  BillCategory.electricity => '${b.name} · meter $customer',
  BillCategory.tv || BillCategory.internet => '${b.name} $plan · $customer',
  BillCategory.education => '${b.name} $plan',
  BillCategory.betting => '${b.name} top-up · $customer',
};
