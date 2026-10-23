import 'dart:async';

import '../credentials.dart';
import '../ids.dart';
import 'api.dart';
import 'models.dart';

/// An in-memory stand-in for the backend, so the app can be tried with no
/// server and no real money. It follows the backend's sandbox rules:
///
/// * the sign-in code is always 000000;
/// * new customers get a ₦50,000 demo credit;
/// * account numbers ending in 8 are not found, 0 are declined and refunded,
///   9 stay with the bank for a few seconds, and anything else is delivered;
/// * 5 free transfers a month, then ₦10 each.
class DemoAvoraApi implements AvoraApi {
  DemoAvoraApi({required this.credentials, DateTime Function()? clock, this.pendingFor = const Duration(seconds: 6)})
    : _now = clock ?? DateTime.now;

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
      final u = _DemoUser(_users.length + 1, '90${phone.substring(phone.length - 8)}', pin);
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
  final String pin;
  int balance = 0;
  final lines = <StatementLine>[];
  final transfers = <String, Transfer>{};
  final byKey = <String, String>{};
}
