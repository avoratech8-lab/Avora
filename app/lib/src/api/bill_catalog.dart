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
  ];
}
