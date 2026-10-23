import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../credentials.dart';
import 'api.dart';
import 'models.dart';

class HttpAvoraApi implements AvoraApi {
  HttpAvoraApi({required this.baseUrl, required this.credentials, this.deviceName = '', http.Client? client})
    : _client = client ?? http.Client();

  final Uri baseUrl;

  /// Shown under Me → Devices and in the new-phone notification.
  final String deviceName;
  final Credentials credentials;
  final http.Client _client;

  @override
  bool get isDemo => false;

  Future<dynamic> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    final uri = baseUrl.replace(path: '${baseUrl.path}$path', queryParameters: query);
    final req = http.Request(method, uri)
      ..headers['X-Device-ID'] = credentials.deviceId
      ..headers['Accept'] = 'application/json';
    final token = credentials.token;
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (headers != null) req.headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }

    final http.Response resp;
    try {
      resp = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      throw ApiException('network', 'The network is slow. Check your connection and try again.');
    } on http.ClientException {
      throw ApiException('network', 'No connection. Check your internet and try again.');
    }

    final decoded = resp.body.isEmpty ? null : jsonDecode(resp.body);
    if (resp.statusCode >= 200 && resp.statusCode < 300) return decoded;

    final err = decoded is Map<String, dynamic> ? decoded['error'] as Map<String, dynamic>? : null;
    final e = ApiException(
      err?['code'] as String? ?? 'unknown',
      err?['message'] as String? ?? 'Something went wrong. Please try again.',
      status: resp.statusCode,
    );
    if (e.isUnauthorized) await credentials.setToken(null);
    throw e;
  }

  @override
  Future<String> startOtp(String phone) async {
    final j = await _call('POST', '/v1/auth/otp', body: {'phone': phone});
    return j['challenge_id'] as String;
  }

  @override
  Future<Session> verify({required String challengeId, required String code, required String pin}) async {
    final j = await _call(
      'POST',
      '/v1/auth/verify',
      body: {'challenge_id': challengeId, 'code': code, 'pin': pin},
      headers: {if (deviceName.isNotEmpty) 'X-Device-Name': deviceName},
    );
    final s = Session.fromJson(j as Map<String, dynamic>);
    await credentials.setToken(s.token);
    return s;
  }

  @override
  Future<Wallet> wallet() async => Wallet.fromJson(await _call('GET', '/v1/me/wallet'));

  @override
  Future<List<StatementLine>> statement() async {
    final j = await _call('GET', '/v1/me/statement', query: {'limit': '50'});
    return (j['lines'] as List).map((l) => StatementLine.fromJson(l as Map<String, dynamic>)).toList();
  }

  @override
  Future<String> nameEnquiry({required String bankCode, required String accountNumber}) async {
    final j = await _call('POST', '/v1/name-enquiry', body: {'bank_code': bankCode, 'account_number': accountNumber});
    return j['account_name'] as String;
  }

  @override
  Future<Quote> quote(int amount) async =>
      Quote.fromJson(await _call('GET', '/v1/transfers/quote', query: {'amount': '$amount'}));

  @override
  Future<Transfer> send({
    required String bankCode,
    required String accountNumber,
    required int amount,
    required String narration,
    required String pin,
    required String idempotencyKey,
  }) async {
    final j = await _call(
      'POST',
      '/v1/transfers',
      body: {
        'bank_code': bankCode,
        'account_number': accountNumber,
        'amount': amount,
        'narration': narration,
        'pin': pin,
      },
      headers: {'Idempotency-Key': idempotencyKey},
    );
    return Transfer.fromJson(j as Map<String, dynamic>);
  }

  @override
  Future<Transfer> transfer(String id) async => Transfer.fromJson(await _call('GET', '/v1/transfers/$id'));

  @override
  Future<List<Biller>> billers() async {
    final j = await _call('GET', '/v1/bills/billers');
    return [for (final b in j['billers'] as List) Biller.fromJson(b as Map<String, dynamic>)];
  }

  @override
  Future<String> validateBillCustomer({required String billerId, required String customer}) async {
    final j = await _call('POST', '/v1/bills/validate', body: {'biller_id': billerId, 'customer': customer});
    return j['customer_name'] as String;
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
    final j = await _call(
      'POST',
      '/v1/bills/payments',
      body: {'biller_id': billerId, 'plan_code': ?planCode, 'customer': customer, 'amount': amount, 'pin': pin},
      headers: {'Idempotency-Key': idempotencyKey},
    );
    return BillPayment.fromJson(j as Map<String, dynamic>);
  }

  @override
  Future<BillPayment> billPayment(String id) async =>
      BillPayment.fromJson(await _call('GET', '/v1/bills/payments/$id'));

  @override
  Future<(List<SavingsPot>, SavingsRates)> savings() async {
    final j = await _call('GET', '/v1/savings');
    return (
      [for (final p in j['pots'] as List) SavingsPot.fromJson(p as Map<String, dynamic>)],
      SavingsRates.fromJson(j['rates'] as Map<String, dynamic>),
    );
  }

  @override
  Future<SavingsPot> createPot({
    required PotKind kind,
    required String name,
    int target = 0,
    int lockDays = 0,
    int amount = 0,
    required String idempotencyKey,
  }) async => SavingsPot.fromJson(
    await _call(
      'POST',
      '/v1/savings',
      body: {'kind': kind.name, 'name': name, 'target': target, 'lock_days': lockDays, 'amount': amount},
      headers: {'Idempotency-Key': idempotencyKey},
    ),
  );

  @override
  Future<SavingsPot> depositToPot(String id, int amount, {required String idempotencyKey}) async => SavingsPot.fromJson(
    await _call(
      'POST',
      '/v1/savings/$id/deposit',
      body: {'amount': amount},
      headers: {'Idempotency-Key': idempotencyKey},
    ),
  );

  @override
  Future<SavingsPot> withdrawFromPot(
    String id, {
    int amount = 0,
    bool breakEarly = false,
    required String idempotencyKey,
  }) async => SavingsPot.fromJson(
    await _call(
      'POST',
      '/v1/savings/$id/withdraw',
      body: {'amount': amount, 'break_early': breakEarly},
      headers: {'Idempotency-Key': idempotencyKey},
    ),
  );

  @override
  Future<void> changePin({required String oldPin, required String newPin}) =>
      _call('POST', '/v1/me/pin', body: {'old_pin': oldPin, 'new_pin': newPin});

  @override
  Future<void> verifyPin(String pin) => _call('POST', '/v1/me/pin/verify', body: {'pin': pin});

  @override
  Future<List<Device>> devices() async {
    final j = await _call('GET', '/v1/me/devices');
    return (j['devices'] as List).map((d) => Device.fromJson(d as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> removeDevice(int id) => _call('DELETE', '/v1/me/devices/$id');

  @override
  Future<KycStatus> kycStatus() async => KycStatus.fromJson(await _call('GET', '/v1/me/kyc'));

  @override
  Future<KycStatus> verifyKyc({required String kind, required String number}) async =>
      KycStatus.fromJson(await _call('POST', '/v1/me/kyc', body: {'type': kind, 'number': number}));

  @override
  Future<(List<AppNotification>, int)> notifications() async {
    final j = await _call('GET', '/v1/me/notifications');
    final list = (j['notifications'] as List).map((n) => AppNotification.fromJson(n as Map<String, dynamic>)).toList();
    return (list, j['unread'] as int? ?? 0);
  }

  @override
  Future<void> markNotificationsRead() => _call('POST', '/v1/me/notifications/read');

  @override
  Future<Profile> profile() async => Profile.fromJson(await _call('GET', '/v1/me/profile'));

  @override
  Future<Profile> updateProfile({String name = '', String tag = ''}) async =>
      Profile.fromJson(await _call('PATCH', '/v1/me/profile', body: {'name': name, 'tag': tag}));

  @override
  Future<Person> findPerson(String query) async =>
      Person.fromJson(await _call('GET', '/v1/p2p/find', query: {'q': query}));

  @override
  Future<P2PTransfer> sendToAvora({
    required String to,
    required int amount,
    required String note,
    required String pin,
    required String idempotencyKey,
  }) async => P2PTransfer.fromJson(
    await _call(
      'POST',
      '/v1/p2p',
      body: {'to': to, 'amount': amount, 'note': note, 'pin': pin},
      headers: {'Idempotency-Key': idempotencyKey},
    ),
  );

  @override
  Future<P2PTransfer> p2pTransfer(String id) async => P2PTransfer.fromJson(await _call('GET', '/v1/p2p/$id'));

  @override
  Future<Insights> insights({DateTime? month}) async => Insights.fromJson(
    await _call(
      'GET',
      '/v1/me/insights',
      query: month == null ? null : {'month': '${month.year}-${month.month.toString().padLeft(2, '0')}'},
    ),
  );

  @override
  Future<Map<String, int>> budgets() async => _budgets(await _call('GET', '/v1/me/budgets'));

  @override
  Future<Map<String, int>> setBudget(String category, int amount) async =>
      _budgets(await _call('PUT', '/v1/me/budgets/$category', body: {'amount': amount}));

  Map<String, int> _budgets(Map<String, dynamic> j) => {
    for (final e in (j['budgets'] as Map<String, dynamic>? ?? const {}).entries) e.key: e.value as int,
  };

  @override
  Future<CardList> cards() async => CardList.fromJson(await _call('GET', '/v1/cards'));

  @override
  Future<VirtualCard> createCard(String name) async =>
      VirtualCard.fromJson(await _call('POST', '/v1/cards', body: {'name': name}));

  @override
  Future<VirtualCard> freezeCard(String id, bool frozen) async =>
      VirtualCard.fromJson(await _call('POST', '/v1/cards/$id/freeze', body: {'frozen': frozen}));

  @override
  Future<VirtualCard> setCardLimit(String id, int amount) async =>
      VirtualCard.fromJson(await _call('PUT', '/v1/cards/$id/limit', body: {'amount': amount}));

  @override
  Future<CardDetails> cardDetails(String id, String pin) async =>
      CardDetails.fromJson(await _call('POST', '/v1/cards/$id/details', body: {'pin': pin}));

  @override
  Future<void> closeCard(String id, String pin) => _call('POST', '/v1/cards/$id/terminate', body: {'pin': pin});

  @override
  Future<List<CardPayment>> cardPayments(String id) async {
    final j = await _call('GET', '/v1/cards/$id/payments');
    return [for (final p in (j['payments'] as List? ?? const [])) CardPayment.fromJson(p as Map<String, dynamic>)];
  }

  @override
  Future<CardPayment> testCardPayment(
    String id, {
    required String merchant,
    required int amount,
    required String key,
  }) async => CardPayment.fromJson(
    await _call(
      'POST',
      '/v1/sandbox/cards/$id/charge',
      body: {'merchant': merchant, 'amount': amount},
      headers: {'Idempotency-Key': key},
    ),
  );

  @override
  Future<RoundUp> roundUp() async => RoundUp.fromJson(await _call('GET', '/v1/me/roundup'));

  @override
  Future<RoundUp> setRoundUp({required String potId, required int step}) async =>
      RoundUp.fromJson(await _call('PUT', '/v1/me/roundup', body: {'pot_id': potId, 'step': step}));

  @override
  Future<ReferralSummary> referrals() async => ReferralSummary.fromJson(await _call('GET', '/v1/me/referrals'));

  @override
  Future<ReferralSummary> joinReferral(String code) async =>
      ReferralSummary.fromJson(await _call('POST', '/v1/me/referrals', body: {'code': code}));

  @override
  Future<List<HelpArticle>> helpArticles() async {
    final j = await _call('GET', '/v1/help/articles');
    return (j['articles'] as List).map((a) => HelpArticle.fromJson(a as Map<String, dynamic>)).toList();
  }

  List<SupportMessage> _messages(dynamic j) =>
      (j['messages'] as List).map((m) => SupportMessage.fromJson(m as Map<String, dynamic>)).toList();

  @override
  Future<List<SupportMessage>> supportMessages() async => _messages(await _call('GET', '/v1/support/messages'));

  @override
  Future<List<SupportMessage>> sendSupportMessage(String body) async =>
      _messages(await _call('POST', '/v1/support/messages', body: {'body': body}));

  @override
  Future<void> logout() async {
    try {
      await _call('POST', '/v1/auth/logout');
    } finally {
      await credentials.setToken(null);
    }
  }
}
