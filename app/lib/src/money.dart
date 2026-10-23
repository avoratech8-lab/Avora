/// Money is always handled as integer kobo (₦1 = 100 kobo), never doubles.
library;

/// Formats kobo as naira, e.g. 123450 -> "₦1,234.50".
String formatNaira(int kobo) {
  final negative = kobo < 0;
  final abs = kobo.abs();
  final naira = (abs ~/ 100).toString();
  final buf = StringBuffer();
  for (var i = 0; i < naira.length; i++) {
    if (i > 0 && (naira.length - i) % 3 == 0) buf.write(',');
    buf.write(naira[i]);
  }
  final k = (abs % 100).toString().padLeft(2, '0');
  return '${negative ? '-' : ''}₦$buf.$k';
}

final _amountRe = RegExp(r'^\d+(\.\d{1,2})?$');

/// Parses what a customer typed ("5,000" or "250.5") into kobo. Returns
/// null for anything that isn't a positive amount with at most 2 decimals.
int? parseNaira(String input) {
  final cleaned = input.replaceAll(RegExp(r'[₦,\s]'), '');
  if (!_amountRe.hasMatch(cleaned)) return null;
  final parts = cleaned.split('.');
  final naira = int.tryParse(parts[0]);
  if (naira == null || naira > 1000000000) return null;
  final kobo = parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0;
  final total = naira * 100 + kobo;
  return total > 0 ? total : null;
}
