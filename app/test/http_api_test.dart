import 'dart:convert';

import 'package:avora/src/api/api.dart';
import 'package:avora/src/api/http_api.dart';
import 'package:avora/src/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Credentials creds;
  late List<http.Request> requests;

  HttpAvoraApi apiWith(http.Response Function(http.Request) handler) {
    requests = [];
    return HttpAvoraApi(
      baseUrl: Uri.parse('https://api.example.test'),
      credentials: creds,
      client: MockClient((r) async {
        requests.add(r);
        return handler(r);
      }),
    );
  }

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  setUp(() async => creds = await Credentials.load(MemoryKeyValueStore()));

  test('verify stores the token and later calls send it with the device id', () async {
    final api = apiWith(
      (r) => switch (r.url.path) {
        '/v1/auth/verify' => json({'token': 'tok', 'user_id': 1, 'wallet_id': 7, 'new_user': true, 'new_device': true}),
        '/v1/me/wallet' => json({'id': 7, 'user_ref': 'u', 'account_number': '9012345678', 'balance': 150}),
        _ => json({}, 404),
      },
    );

    final s = await api.verify(challengeId: 'c', code: '123456', pin: '135790');
    expect(s.walletId, 7);
    expect(creds.token, 'tok');
    expect(jsonDecode(requests.single.body), {'challenge_id': 'c', 'code': '123456', 'pin': '135790'});

    final w = await api.wallet();
    expect(w.balance, 150);
    expect(requests.last.headers['Authorization'], 'Bearer tok');
    expect(requests.last.headers['X-Device-ID'], creds.deviceId);
  });

  test('send passes the idempotency key and parses the transfer', () async {
    await creds.setToken('tok');
    final api = apiWith(
      (r) => json({
        'id': 'abc',
        'wallet_id': 7,
        'bank_code': '058',
        'account_number': '0123456781',
        'account_name': 'ADA OBI',
        'narration': 'rent',
        'amount': 500000,
        'fee': 0,
        'status': 'sent',
        'created_at': '2026-10-23T10:00:00Z',
        'updated_at': '2026-10-23T10:00:00Z',
      }),
    );

    final t = await api.send(
      bankCode: '058',
      accountNumber: '0123456781',
      amount: 500000,
      narration: 'rent',
      pin: '135790',
      idempotencyKey: 'k1',
    );
    expect(t.accountName, 'ADA OBI');
    expect(t.isFinal, isFalse);
    expect(requests.single.headers['Idempotency-Key'], 'k1');
    expect(jsonDecode(requests.single.body)['amount'], 500000);
  });

  test('quote sends the amount as a query parameter', () async {
    await creds.setToken('tok');
    final api = apiWith((r) => json({'amount': 100, 'fee': 1000, 'total': 1100, 'free_transfers_left': 0}));
    final q = await api.quote(100);
    expect(q.total, 1100);
    expect(requests.single.url.queryParameters['amount'], '100');
  });

  test('errors carry the server message, and unauthorized signs out', () async {
    await creds.setToken('tok');
    var status = 422;
    final api = apiWith(
      (r) => json({
        'error': {'code': status == 401 ? 'unauthorized' : 'insufficient_funds', 'message': 'Nope.'},
      }, status),
    );

    await expectLater(api.wallet(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'insufficient_funds')));
    expect(creds.signedIn, isTrue);

    status = 401;
    await expectLater(api.wallet(), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Nope.')));
    expect(creds.signedIn, isFalse);
  });

  test('a dropped connection becomes a friendly network error', () async {
    final api = HttpAvoraApi(
      baseUrl: Uri.parse('https://api.example.test'),
      credentials: creds,
      client: MockClient((_) async => throw http.ClientException('down')),
    );
    await expectLater(
      api.startOtp('08031234567'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network')),
    );
  });

  test('the device id is made once and kept', () async {
    final store = MemoryKeyValueStore();
    final a = await Credentials.load(store);
    final b = await Credentials.load(store);
    expect(a.deviceId, hasLength(32));
    expect(b.deviceId, a.deviceId);
  });
}
