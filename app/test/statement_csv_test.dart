import 'package:avora/src/api/models.dart';
import 'package:avora/src/screens/protect_screens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the CSV has the summary, a running balance and quoted descriptions', () {
    final s = PeriodStatement(
      accountName: 'Ada Obi',
      accountNumber: '9012345678',
      from: DateTime(2026, 10, 1),
      to: DateTime(2026, 10, 31),
      openingBalance: 100000,
      moneyIn: 50000,
      moneyOut: 2550,
      closingBalance: 147450,
      lines: [
        StatementLine(
          kind: 'inbound_credit',
          description: 'From TUNDE',
          ref: 'S1',
          amount: 50000,
          at: DateTime(2026, 10, 2, 9),
        ),
        StatementLine(
          kind: 'bill_payment',
          description: 'MTN airtime, "top-up"',
          ref: 'b1',
          amount: -2550,
          at: DateTime(2026, 10, 3, 14, 5),
        ),
      ],
    );
    final rows = statementCsv(s).trim().split('\r\n');
    expect(rows[1], 'Account name,Ada Obi');
    expect(rows[4], 'Opening balance,1000.00');
    expect(rows[7], 'Closing balance,1474.50');
    expect(rows[9], 'Date,Time,Description,Money in,Money out,Balance,Reference');
    expect(rows[10], '2026-10-02,09:00,From TUNDE,500.00,,1500.00,S1');
    expect(rows[11], '2026-10-03,14:05,"MTN airtime, ""top-up""",,25.50,1474.50,b1');
  });
}
