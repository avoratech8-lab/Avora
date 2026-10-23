import 'package:avora/src/pay_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips through the QR text', () {
    const c = PayCode(bankCode: '302', accountNumber: '9012345678', amount: 250050, note: 'Rent & bills');
    final back = PayCode.parse(c.encode())!;
    expect(back.bankCode, '302');
    expect(back.accountNumber, '9012345678');
    expect(back.amount, 250050);
    expect(back.note, 'Rent & bills');
  });

  test('reads a bare account number and rejects anything else', () {
    expect(PayCode.parse(' 0123456789 ')!.bankCode, '');
    expect(PayCode.parse('https://example.com'), isNull);
    expect(PayCode.parse('avora:pay?account=123'), isNull);
    expect(PayCode.parse('avora:pay?account=0123456789&amount=-5')!.amount, 0);
  });

  test('a request explains how to pay without Avora', () {
    final text = const PayCode(
      bankCode: '302',
      accountNumber: '9012345678',
      amount: 500000,
      note: 'lunch',
    ).requestText();
    expect(text, startsWith('Please send me ₦5,000.00 for lunch.'));
    expect(text, contains('Account number: 9012345678'));
  });
}
