import 'package:avora/src/api/demo_api.dart';
import 'package:avora/src/app.dart';
import 'package:avora/src/credentials.dart';
import 'package:avora/src/recipients.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> typeOnPad(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.byKey(Key('key-$d')).last);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<(DemoAvoraApi, Credentials, RecentRecipients)> demo() async {
  final store = MemoryKeyValueStore();
  final creds = await Credentials.load(store);
  return (DemoAvoraApi(credentials: creds), creds, await RecentRecipients.load(store));
}

Future<void> signedIn(DemoAvoraApi api) async {
  final c = await api.startOtp('08031234567');
  await api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '135790');
}

void main() {
  setUp(() {
    // A phone-sized screen, so the number pads fit.
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
      ..physicalSize = const Size(1170, 2532)
      ..devicePixelRatio = 3;
  });

  testWidgets('sign up, send money, see the receipt, send again, sign out', (tester) async {
    final (api, creds, recipients) = await demo();
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));

    // Sign up.
    await tester.tap(find.byKey(const Key('get-started')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('phone')), '0803 123 4567');
    await tester.tap(find.byKey(const Key('continue')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, DemoAvoraApi.code);
    await typeOnPad(tester, '135790');
    expect(find.text('₦50,000.00'), findsOneWidget);

    // Send ₦2,500 to a GTBank account.
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bank')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bank-search')), 'gt');
    await tester.pumpAndSettle();
    await tester.tap(find.text('GTBank'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account')), '0123456781');
    await tester.pumpAndSettle();
    expect(find.text('DEMO USER 6781'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, '2500');
    expect(find.textContaining('2,500'), findsWidgets);
    await tester.tap(find.byKey(const Key('review')));
    await tester.pumpAndSettle();
    expect(find.text('Free'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, '135790');
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.byKey(const Key('share')), findsOneWidget);

    // Back home: balance, activity and "Send again" show it.
    await tester.tap(find.byKey(const Key('done')));
    await tester.pumpAndSettle();
    expect(find.text('₦47,500.00'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Send again'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Send again'), findsOneWidget);
    expect(recipients.items.single.accountNumber, '0123456781');

    // Activity tab filters.
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Transfer to DEMO USER 6781 (0123456781)'), findsOneWidget);
    await tester.tap(find.text('Money in').last);
    await tester.pumpAndSettle();
    expect(find.text('Transfer to DEMO USER 6781 (0123456781)'), findsNothing);
    expect(find.text('Welcome credit (demo money)'), findsWidgets);

    // Sign out from Me returns to the welcome screen and forgets recipients.
    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('sign-out')), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sign-out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('get-started')), findsOneWidget);
    expect(recipients.items, isEmpty);
  });

  testWidgets('a wrong PIN shakes and lets you try again', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await api.logout();
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.tap(find.byKey(const Key('get-started')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('phone')), '08031234567');
    await tester.tap(find.byKey(const Key('continue')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, DemoAvoraApi.code);
    await typeOnPad(tester, '111111');
    expect(find.text('That PIN is wrong.'), findsOneWidget);
    await typeOnPad(tester, '135790');
    expect(find.byKey(const Key('balance')), findsOneWidget);
  });

  testWidgets('buy data and see the receipt', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('action-data')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('biller-airtel-data')));
    await tester.enterText(find.byKey(const Key('bill-customer')), '08021234567');
    await tester.tap(find.byKey(const Key('plan-airtel-2gb-7d')));
    await tester.pumpAndSettle();
    expect(find.text('Pay ₦1,500.00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bill-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, '135790');
    expect(find.text('Successful'), findsOneWidget);
    expect(find.text('Data sent to 08021234567.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('done')));
    await tester.pumpAndSettle();
    expect(find.text('₦48,500.00'), findsOneWidget);
  });

  testWidgets('electricity shows the meter name and a token', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('action-electricity')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bill-customer')), '45123456781');
    await tester.pumpAndSettle();
    expect(find.text('DEMO CUSTOMER 6781'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('bill-amount')), '5000');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bill-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, '135790');
    expect(find.text('Electricity token'), findsOneWidget);
    expect(find.byKey(const Key('highlight')), findsOneWidget);
  });

  testWidgets('a declined transfer says the money came back', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await api.send(
      bankCode: '058',
      accountNumber: '0123456780',
      amount: 1000,
      narration: '',
      pin: '135790',
      idempotencyKey: 'x',
    );

    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Refund:'));
    await tester.pumpAndSettle();
    expect(find.text("Didn't go through"), findsOneWidget);
    expect(find.text('beneficiary bank declined'), findsOneWidget);
  });
}
