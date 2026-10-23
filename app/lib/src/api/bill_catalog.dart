import 'models.dart';

/// The demo app's billers. The backend serves the real list; prices here are
/// samples, not live tariffs.
List<Biller> demoBillers() {
  BillPlan p(String code, String name, int naira) => BillPlan(code: code, name: name, amount: naira * 100);

  List<BillPlan> data(String net) => [
    p('$net-1gb-1d', '1GB · 1 day', 500),
    p('$net-2gb-7d', '2GB · 7 days', 1500),
    p('$net-3.5gb-30d', '3.5GB · 30 days', 2500),
    p('$net-10gb-30d', '10GB · 30 days', 4500),
    p('$net-25gb-30d', '25GB · 30 days', 9000),
  ];

  const networks = {'mtn': 'MTN', 'airtel': 'Airtel', 'glo': 'Glo', '9mobile': '9mobile'};
  const discos = {
    'ikedc': 'Ikeja Electric',
    'ekedc': 'Eko Electric',
    'aedc': 'Abuja Electric',
    'ibedc': 'Ibadan Electric',
    'phed': 'Port Harcourt Electric',
    'kedco': 'Kano Electric',
    'eedc': 'Enugu Electric',
  };
  const books = {
    'bet9ja': 'Bet9ja',
    'sportybet': 'SportyBet',
    'betking': 'BetKing',
    '1xbet': '1xBet',
    'nairabet': 'NairaBet',
    'msport': 'MSport',
  };

  return [
    for (final n in networks.entries)
      Biller(
        id: '${n.key}-airtime',
        name: n.value,
        category: BillCategory.airtime,
        customerLabel: 'Phone number',
        plans: const [],
        minAmount: 5000,
        maxAmount: 5000000,
        cashbackBps: 200,
      ),
    for (final n in networks.entries)
      Biller(
        id: '${n.key}-data',
        name: n.value,
        category: BillCategory.data,
        customerLabel: 'Phone number',
        plans: data(n.key),
        minAmount: 0,
        maxAmount: 0,
        cashbackBps: 300,
      ),
    for (final d in discos.entries)
      Biller(
        id: d.key,
        name: d.value,
        category: BillCategory.electricity,
        customerLabel: 'Meter number',
        plans: const [],
        minAmount: 100000,
        maxAmount: 50000000,
      ),
    Biller(
      id: 'dstv',
      name: 'DStv',
      category: BillCategory.tv,
      customerLabel: 'Smartcard number',
      plans: [
        p('dstv-padi', 'Padi', 4400),
        p('dstv-yanga', 'Yanga', 6000),
        p('dstv-confam', 'Confam', 11000),
        p('dstv-compact', 'Compact', 19000),
        p('dstv-premium', 'Premium', 44500),
      ],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'gotv',
      name: 'GOtv',
      category: BillCategory.tv,
      customerLabel: 'IUC number',
      plans: [
        p('gotv-smallie', 'Smallie', 1900),
        p('gotv-jinja', 'Jinja', 3900),
        p('gotv-jolli', 'Jolli', 5800),
        p('gotv-max', 'Max', 8500),
        p('gotv-supa', 'Supa', 11400),
      ],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'startimes',
      name: 'StarTimes',
      category: BillCategory.tv,
      customerLabel: 'Smartcard number',
      plans: [
        p('startimes-nova', 'Nova', 1900),
        p('startimes-basic', 'Basic', 3700),
        p('startimes-classic', 'Classic', 5500),
      ],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'spectranet',
      name: 'Spectranet',
      category: BillCategory.internet,
      customerLabel: 'Customer ID',
      plans: [
        p('spectranet-30gb', '30GB · 30 days', 10000),
        p('spectranet-65gb', '65GB · 30 days', 20000),
        p('spectranet-unlimited', 'Unlimited · 30 days', 35000),
      ],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'smile',
      name: 'Smile',
      category: BillCategory.internet,
      customerLabel: 'Account number',
      plans: [
        p('smile-6gb', '6GB · 30 days', 3000),
        p('smile-20gb', '20GB · 30 days', 8000),
        p('smile-unlimited', 'Unlimited Lite · 30 days', 20000),
      ],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'waec',
      name: 'WAEC',
      category: BillCategory.education,
      customerLabel: 'Phone number',
      plans: [p('waec-result', 'Result checker PIN', 3900)],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'neco',
      name: 'NECO',
      category: BillCategory.education,
      customerLabel: 'Phone number',
      plans: [p('neco-result', 'Result token', 1300)],
      minAmount: 0,
      maxAmount: 0,
    ),
    Biller(
      id: 'jamb',
      name: 'JAMB',
      category: BillCategory.education,
      customerLabel: 'Profile code',
      plans: [p('jamb-utme', 'UTME ePIN', 7700), p('jamb-de', 'Direct Entry ePIN', 7700)],
      minAmount: 0,
      maxAmount: 0,
    ),
    for (final b in books.entries)
      Biller(
        id: b.key,
        name: b.value,
        category: BillCategory.betting,
        customerLabel: 'User ID',
        plans: const [],
        minAmount: 10000,
        maxAmount: 50000000,
      ),
  ];
}
