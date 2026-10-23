import 'package:avora/src/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatNaira', () {
    expect(formatNaira(0), '₦0.00');
    expect(formatNaira(5), '₦0.05');
    expect(formatNaira(123450), '₦1,234.50');
    expect(formatNaira(100000000), '₦1,000,000.00');
    expect(formatNaira(-1000), '-₦10.00');
  });

  test('parseNaira', () {
    expect(parseNaira('5000'), 500000);
    expect(parseNaira('5,000'), 500000);
    expect(parseNaira('₦ 250.5'), 25050);
    expect(parseNaira('0.01'), 1);
    for (final bad in ['', '0', 'abc', '1.234', '-5', '1e3', '10000000001']) {
      expect(parseNaira(bad), isNull, reason: bad);
    }
  });
}
