class Bank {
  const Bank(this.code, this.name);

  final String code;
  final String name;
}

/// Banks shown in the send screen, by CBN bank code.
///
/// TODO: replace with the partner bank's live institution list (it carries
/// the NIP codes for fintechs like OPay and Moniepoint, which differ from
/// the 3-digit CBN codes) before launch.
const banks = <Bank>[
  Bank('044', 'Access Bank'),
  Bank('023', 'Citibank'),
  Bank('050', 'Ecobank'),
  Bank('070', 'Fidelity Bank'),
  Bank('011', 'First Bank'),
  Bank('214', 'FCMB'),
  Bank('058', 'GTBank'),
  Bank('030', 'Heritage Bank'),
  Bank('301', 'Jaiz Bank'),
  Bank('082', 'Keystone Bank'),
  Bank('076', 'Polaris Bank'),
  Bank('101', 'Providus Bank'),
  Bank('221', 'Stanbic IBTC'),
  Bank('068', 'Standard Chartered'),
  Bank('232', 'Sterling Bank'),
  Bank('302', 'TAJBank'),
  Bank('032', 'Union Bank'),
  Bank('033', 'UBA'),
  Bank('215', 'Unity Bank'),
  Bank('035', 'Wema Bank'),
  Bank('057', 'Zenith Bank'),
];

/// Recipients saved with this "bank" are Avora customers, paid by @tag.
const avoraBank = 'avora';

String bankName(String code) =>
    code == avoraBank ? 'Avora' : banks.firstWhere((b) => b.code == code, orElse: () => Bank(code, 'Bank $code')).name;
