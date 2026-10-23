import 'package:avora/src/api/demo_api.dart';
import 'package:avora/src/app.dart';
import 'package:avora/src/credentials.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sign up, send money, see it delivered, sign out', (tester) async {
    final creds = await Credentials.load(MemoryKeyValueStore());
    final api = DemoAvoraApi(credentials: creds);
    await tester.pumpWidget(AvoraApp(api: api, credentials: creds));

    // Sign up.
    await tester.enterText(find.byKey(const Key('phone')), '0803 123 4567');
    await tester.tap(find.byKey(const Key('continue')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('code')), DemoAvoraApi.code);
    await tester.enterText(find.byKey(const Key('pin')), '135790');
    await tester.tap(find.byKey(const Key('verify')));
    await tester.pumpAndSettle();
    expect(find.text('₦50,000.00'), findsOneWidget);
    expect(find.text('Welcome credit (demo money)'), findsOneWidget);

    // Send ₦2,500 to a GTBank account.
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bank')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GTBank').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account')), '0123456781');
    await tester.pumpAndSettle();
    expect(find.text('DEMO USER 6781'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('amount')), '2,500');
    await tester.tap(find.byKey(const Key('review')));
    await tester.pumpAndSettle();
    expect(find.text('Free'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('send-pin')), '135790');
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Delivered'), findsOneWidget);

    // Back home, the balance and activity show it.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('₦47,500.00'), findsOneWidget);
    expect(find.text('Transfer to DEMO USER 6781 (0123456781)'), findsOneWidget);

    // Sign out returns to the phone screen.
    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phone')), findsOneWidget);
  });

  testWidgets('a declined transfer says the money came back', (tester) async {
    final creds = await Credentials.load(MemoryKeyValueStore());
    final api = DemoAvoraApi(credentials: creds);
    final c = await api.startOtp('08031234567');
    await api.verify(challengeId: c, code: DemoAvoraApi.code, pin: '135790');
    final t = await api.send(
      bankCode: '058',
      accountNumber: '0123456780',
      amount: 1000,
      narration: '',
      pin: '135790',
      idempotencyKey: 'x',
    );

    await tester.pumpWidget(AvoraApp(api: api, credentials: creds));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Refund:'));
    await tester.pumpAndSettle();
    expect(find.text("Didn't go through"), findsOneWidget);
    expect(find.text('beneficiary bank declined'), findsOneWidget);
    expect(t.id, isNotEmpty);
  });
}
