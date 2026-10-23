import 'dart:convert';

import 'package:avora/src/api/api.dart';
import 'package:avora/src/api/http_api.dart';
import 'package:avora/src/api/models.dart';
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

  test('bills: billers parse and payments send the plan and key', () async {
    await creds.setToken('tok');
    final api = apiWith(
      (r) => switch (r.url.path) {
        '/v1/bills/billers' => json({
          'billers': [
            {
              'id': 'dstv',
              'name': 'DStv',
              'category': 'tv',
              'customer_label': 'Smartcard number',
              'plans': [
                {'code': 'dstv-padi', 'name': 'Padi', 'amount': 440000},
              ],
              'min_amount': 0,
              'max_amount': 0,
            },
          ],
        }),
        _ => json({
          'id': 'p1',
          'wallet_id': 1,
          'biller_id': 'dstv',
          'biller_name': 'DStv',
          'category': 'tv',
          'plan_code': 'dstv-padi',
          'plan_name': 'Padi',
          'customer': '1234567891',
          'customer_name': 'ADA',
          'amount': 440000,
          'status': 'success',
          'created_at': '2026-10-23T10:00:00Z',
          'updated_at': '2026-10-23T10:00:00Z',
        }),
      },
    );
    final b = (await api.billers()).single;
    expect(b.category, BillCategory.tv);
    expect(b.plans.single.amount, 440000);

    final p = await api.payBill(
      billerId: 'dstv',
      planCode: 'dstv-padi',
      customer: '1234567891',
      amount: 440000,
      pin: '135790',
      idempotencyKey: 'k',
    );
    expect(p.status, BillStatus.success);
    expect(requests.last.headers['Idempotency-Key'], 'k');
    expect(jsonDecode(requests.last.body)['plan_code'], 'dstv-padi');

    await api.payBill(
      billerId: 'mtn-airtime',
      customer: '08031234567',
      amount: 10000,
      pin: '135790',
      idempotencyKey: 'k2',
    );
    expect((jsonDecode(requests.last.body) as Map).containsKey('plan_code'), isFalse);
  });

  test('security calls: device name on sign-in, KYC, notifications, devices', () async {
    final api = HttpAvoraApi(
      baseUrl: Uri.parse('https://api.example.test'),
      credentials: creds,
      deviceName: 'Tecno Spark 20',
      client: MockClient((r) async {
        requests.add(r);
        return switch ('${r.method} ${r.url.path}') {
          'POST /v1/auth/verify' => json({'token': 'tok', 'user_id': 1, 'wallet_id': 7}),
          'POST /v1/me/kyc' => json({
            'tier': 2,
            'bvn_verified': true,
            'nin_verified': false,
            'limits': {},
            'tiers': [
              {'tier': 1, 'daily_send': 5000000, 'max_balance': 30000000, 'needs': 'Phone number'},
              {'tier': 2, 'daily_send': 20000000, 'max_balance': 50000000, 'needs': 'BVN or NIN'},
            ],
          }),
          'GET /v1/me/notifications' => json({
            'notifications': [
              {
                'id': 3,
                'kind': 'money_in',
                'title': '₦5,000.00 received',
                'body': 'From ADA OBI',
                'ref': 's1',
                'created_at': '2026-10-23T09:00:00Z',
                'read_at': null,
              },
            ],
            'unread': 1,
          }),
          'GET /v1/me/devices' => json({
            'devices': [
              {
                'id': 1,
                'name': 'Tecno Spark 20',
                'bound_at': '2026-10-01T09:00:00Z',
                'this_phone': true,
                'signed_in': true,
              },
            ],
          }),
          _ => http.Response('', 204),
        };
      }),
    );
    requests = [];

    await api.verify(challengeId: 'c', code: '123456', pin: '135790');
    expect(requests.last.headers['X-Device-Name'], 'Tecno Spark 20');

    final k = await api.verifyKyc(kind: 'bvn', number: '22212345671');
    expect(jsonDecode(requests.last.body), {'type': 'bvn', 'number': '22212345671'});
    expect(k.limits.dailySend, 20000000);

    final (items, unread) = await api.notifications();
    expect(items.single.read, isFalse);
    expect(unread, 1);
    await api.markNotificationsRead();
    expect(requests.last.url.path, '/v1/me/notifications/read');

    expect((await api.devices()).single.thisPhone, isTrue);
    await api.removeDevice(4);
    expect('${requests.last.method} ${requests.last.url.path}', 'DELETE /v1/me/devices/4');

    await api.changePin(oldPin: '135790', newPin: '246810');
    expect(jsonDecode(requests.last.body), {'old_pin': '135790', 'new_pin': '246810'});
  });
}
