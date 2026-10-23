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
  Future<void> logout() async {
    try {
      await _call('POST', '/v1/auth/logout');
    } finally {
      await credentials.setToken(null);
    }
  }
}
