import 'package:avora/src/api/demo_api.dart';
import 'package:avora/src/api/models.dart';
import 'package:avora/src/app.dart';
import 'package:avora/src/credentials.dart';
import 'package:avora/src/pay_code.dart';
import 'package:avora/src/recipients.dart';
import 'package:avora/src/screens/send_screen.dart';
import 'package:avora/src/security.dart';
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

/// Says yes to every fingerprint check and counts them.
class FakeBiometrics implements Biometrics {
  int asked = 0;

  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return true;
  }
}

Future<void> openMe(WidgetTester tester, Key item) async {
  await tester.tap(find.text('Me'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.byKey(item), 200, scrollable: find.byType(Scrollable).last);
  // Bring it clear of the navigation bar before tapping.
  await tester.ensureVisible(find.byKey(item));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(item));
  await tester.pumpAndSettle();
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

  testWidgets('open a goal, add money, see it on the Savings tab', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Savings').last);
    await tester.pumpAndSettle();
    expect(find.text('Interest-free'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rent'));
    await tester.enterText(find.byKey(const Key('pot-target')), '100000');
    await tester.enterText(find.byKey(const Key('pot-amount')), '10000');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pot-create')));
    await tester.pumpAndSettle();
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('10% of ₦100,000.00'), findsOneWidget);

    await tester.tap(find.text('Rent'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pot-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('move-amount')), '5000');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pot-balance')), findsOneWidget);
    expect(find.text('₦15,000.00'), findsWidgets);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('savings-total')), findsOneWidget);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit - 1500000);
  });

  testWidgets('breaking a locked plan early asks first', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await api.createPot(kind: PotKind.locked, name: 'School fees', lockDays: 365, amount: 2000000, idempotencyKey: 'k');
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Savings').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('School fees'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pot-break')));
    await tester.pumpAndSettle();
    expect(find.text('Break this plan?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-break')));
    await tester.pumpAndSettle();
    expect(find.text('Closed'), findsWidgets);
    expect((await api.wallet()).balance, DemoAvoraApi.welcomeCredit);
  });

  testWidgets('verify a BVN on the Limits screen to reach Tier 2', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await openMe(tester, const Key('limits'));
    expect(find.text('Tier 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('verify-bvn')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('id-number')), '22212345670');
    await tester.pump();
    await tester.tap(find.byKey(const Key('id-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining("don't match"), findsOneWidget);
    await tester.enterText(find.byKey(const Key('id-number')), '22212345671');
    await tester.pump();
    await tester.tap(find.byKey(const Key('id-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Tier 2'), findsOneWidget);
    expect(find.text('₦200,000.00'), findsOneWidget);
    expect((await api.kycStatus()).bvnVerified, isTrue);
  });

  testWidgets('the bell shows unread notifications and clears them', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byKey(const Key('bell')), matching: find.text('1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bell')));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Avora'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('bell')), matching: find.text('1')), findsNothing);
  });

  testWidgets('change PIN: wrong confirmation, then the new PIN works', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await openMe(tester, const Key('security'));
    await tester.tap(find.byKey(const Key('change-pin')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, '135790');
    expect(find.text('New PIN'), findsOneWidget);
    await typeOnPad(tester, '246810');
    await typeOnPad(tester, '246811');
    expect(find.textContaining("don't match"), findsOneWidget);
    await typeOnPad(tester, '246810');
    await typeOnPad(tester, '246810');
    expect(find.text('PIN changed. Your other phones were signed out.'), findsOneWidget);
    await api.verifyPin('246810');
  });

  testWidgets('the app locks after time away and opens with the PIN', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    final security = Security.inMemory();
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients, security: security));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    security.left(now);
    security.returned(now.add(const Duration(seconds: 10)), signedIn: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-screen')), findsNothing); // under a minute

    security.left(now);
    security.returned(now.add(const Duration(minutes: 2)), signedIn: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-screen')), findsOneWidget);
    await typeOnPad(tester, '111111');
    expect(find.text('That PIN is wrong.'), findsOneWidget);
    await typeOnPad(tester, '135790');
    expect(find.byKey(const Key('lock-screen')), findsNothing);
    expect(find.byKey(const Key('balance')), findsOneWidget);
  });

  testWidgets('turn on fingerprint, then unlock and pay with it', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    final bio = FakeBiometrics();
    final security = Security.inMemory(biometrics: bio);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients, security: security));
    await tester.pumpAndSettle();

    await openMe(tester, const Key('security'));
    await tester.tap(find.byKey(const Key('biometrics')));
    await tester.pumpAndSettle();
    await typeOnPad(tester, '135790');
    expect(security.biometricsOn, isTrue);
    expect(bio.asked, 1);
    await tester.pump(const Duration(seconds: 5)); // let the snackbar go
    await tester.pumpAndSettle();

    // Locking asks for the fingerprint straight away.
    security.lock();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-screen')), findsNothing);
    expect(bio.asked, 2);

    // A payment is approved by fingerprint instead of the PIN.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-airtime')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('biller-mtn-airtime')));
    await tester.enterText(find.byKey(const Key('bill-customer')), '08031234567');
    await tester.enterText(find.byKey(const Key('bill-amount')), '500');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('bill-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bill-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Successful'), findsOneWidget);
    expect(bio.asked, 3);

    // Signing out forgets the stored PIN.
    await api.logout();
    await tester.pumpAndSettle();
    expect(security.biometricsOn, isFalse);
  });

  testWidgets('request money shows a QR code with the amount', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add money'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pay-qr')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('request-money')));
    await tester.tap(find.byKey(const Key('request-money')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('request-amount')), '5,000');
    await tester.enterText(find.byKey(const Key('request-note')), 'lunch');
    await tester.pumpAndSettle();
    expect(find.text('Scan with Avora to pay ₦5,000.00 for lunch'), findsOneWidget);
  });

  testWidgets('a scanned code fills in the account, name, amount and note', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const SendScreen(
          payCode: PayCode(bankCode: '058', accountNumber: '0123456781', amount: 350000, note: 'Suya'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('GTBank'), findsOneWidget);
    expect(find.text('DEMO USER 6781'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('3,500'), findsWidgets);
    expect(find.text('Suya'), findsOneWidget);
  });

  testWidgets('help centre search, then chat with the assistant', (tester) async {
    final (api, creds, recipients) = await demo();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await openMe(tester, const Key('help'));
    await tester.enterText(find.byKey(const Key('help-search')), 'PIN');
    await tester.pumpAndSettle();
    expect(find.text("I forgot my PIN or it's locked"), findsOneWidget);
    expect(find.text('How much do transfers cost?'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('open-chat')));
    await tester.tap(find.byKey(const Key('open-chat')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-input')), 'how do I raise my limit');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Each account tier has a daily limit'), findsOneWidget);
  });

  testWidgets('invite friends shows your code and takes a friend\'s', (tester) async {
    final (api, creds, recipients) = await demo();
    final c = await api.startOtp('08020000001');
    await api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '135790');
    final friendCode = (await api.referrals()).code;
    await api.logout();
    await signedIn(api);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds, recipients: recipients));
    await tester.pumpAndSettle();

    await openMe(tester, const Key('invite'));
    expect(find.byKey(const Key('invite-code')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('join-code')), 'AVNOPE00');
    await tester.pump();
    await tester.tap(find.byKey(const Key('join-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining("don't recognise"), findsOneWidget);
    await tester.enterText(find.byKey(const Key('join-code')), friendCode);
    await tester.pump();
    await tester.tap(find.byKey(const Key('join-submit')));
    await tester.pumpAndSettle();
    expect(find.text('You joined with $friendCode'), findsOneWidget);
  });
}
