import 'money.dart';

/// What an Avora QR code or payment request carries: where to send money
/// and, for a request, how much.
///
/// Encoded as `avora:pay?bank=302&account=9012345678&amount=500000&note=Rent`
/// (amount in kobo). Any other QR holding just a 10-digit account number is
/// read too, leaving the bank to be chosen.
class PayCode {
  const PayCode({this.bankCode = '', required this.accountNumber, this.amount = 0, this.note = ''});

  /// Avora wallets live at the partner bank.
  static const partnerBank = '302';

  final String bankCode;
  final String accountNumber;
  final int amount; // kobo; 0 lets the payer choose
  final String note;

  String encode() => Uri(
    scheme: 'avora',
    path: 'pay',
    queryParameters: {
      'bank': bankCode,
      'account': accountNumber,
      if (amount > 0) 'amount': '$amount',
      if (note.isNotEmpty) 'note': note,
    },
  ).toString();

  static PayCode? parse(String raw) {
    final s = raw.trim();
    if (RegExp(r'^\d{10}$').hasMatch(s)) return PayCode(accountNumber: s);
    final uri = Uri.tryParse(s);
    if (uri == null || uri.scheme != 'avora' || uri.path != 'pay') return null;
    final q = uri.queryParameters;
    final account = q['account'] ?? '';
    if (!RegExp(r'^\d{10}$').hasMatch(account)) return null;
    final amount = int.tryParse(q['amount'] ?? '') ?? 0;
    return PayCode(
      bankCode: RegExp(r'^\d{3,6}$').hasMatch(q['bank'] ?? '') ? q['bank']! : '',
      accountNumber: account,
      amount: amount > 0 && amount <= 100000000000 ? amount : 0,
      note: (q['note'] ?? '').length > 60 ? q['note']!.substring(0, 60) : q['note'] ?? '',
    );
  }

  /// Text to send with a payment request, for people without Avora.
  String requestText() {
    final what = amount > 0 ? 'Please send me ${formatNaira(amount)}' : 'You can send me money';
    final why = note.isEmpty ? '' : ' for $note';
    return '$what$why.\n\nBank: TAJBank\nAccount number: $accountNumber\n\n'
        'On Avora? Open this to pay in two taps: ${encode()}';
  }
}
