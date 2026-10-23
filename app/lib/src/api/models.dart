class Session {
  Session({required this.token, required this.walletId, required this.newUser, required this.newDevice});

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    token: j['token'] as String,
    walletId: j['wallet_id'] as int,
    newUser: j['new_user'] as bool? ?? false,
    newDevice: j['new_device'] as bool? ?? false,
  );

  final String token;
  final int walletId;
  final bool newUser;
  final bool newDevice;
}

class Wallet {
  Wallet({required this.id, required this.accountNumber, required this.balance});

  factory Wallet.fromJson(Map<String, dynamic> j) =>
      Wallet(id: j['id'] as int, accountNumber: j['account_number'] as String, balance: j['balance'] as int);

  final int id;
  final String accountNumber;
  final int balance; // kobo
}

class StatementLine {
  StatementLine({
    required this.kind,
    required this.description,
    required this.ref,
    required this.amount,
    required this.at,
  });

  factory StatementLine.fromJson(Map<String, dynamic> j) => StatementLine(
    kind: j['kind'] as String,
    description: j['description'] as String,
    ref: j['ref'] as String? ?? '',
    amount: j['amount'] as int,
    at: DateTime.parse(j['at'] as String),
  );

  final String kind;
  final String description;
  final String ref; // transfer id for transfer lines
  final int amount; // kobo; positive means money in
  final DateTime at;

  bool get isTransfer => kind.startsWith('transfer_');
}

class Quote {
  Quote({required this.amount, required this.fee, required this.total, required this.freeTransfersLeft});

  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
    amount: j['amount'] as int,
    fee: j['fee'] as int,
    total: j['total'] as int,
    freeTransfersLeft: j['free_transfers_left'] as int,
  );

  final int amount;
  final int fee;
  final int total;
  final int freeTransfersLeft;
}

enum TransferStatus { held, sent, delivered, refunded, needsReview }

TransferStatus _status(String s) => switch (s) {
  'held' => TransferStatus.held,
  'sent' => TransferStatus.sent,
  'delivered' => TransferStatus.delivered,
  'refunded' => TransferStatus.refunded,
  _ => TransferStatus.needsReview,
};

class Transfer {
  Transfer({
    required this.id,
    required this.bankCode,
    required this.accountNumber,
    required this.accountName,
    required this.narration,
    required this.amount,
    required this.fee,
    required this.status,
    required this.sessionId,
    required this.failureReason,
    required this.createdAt,
  });

  factory Transfer.fromJson(Map<String, dynamic> j) => Transfer(
    id: j['id'] as String,
    bankCode: j['bank_code'] as String,
    accountNumber: j['account_number'] as String,
    accountName: j['account_name'] as String,
    narration: j['narration'] as String? ?? '',
    amount: j['amount'] as int,
    fee: j['fee'] as int,
    status: _status(j['status'] as String),
    sessionId: j['session_id'] as String? ?? '',
    failureReason: j['failure_reason'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String bankCode;
  final String accountNumber;
  final String accountName;
  final String narration;
  final int amount;
  final int fee;
  final TransferStatus status;
  final String sessionId;
  final String failureReason;
  final DateTime createdAt;

  bool get isFinal => status == TransferStatus.delivered || status == TransferStatus.refunded;
}

enum BillCategory { airtime, data, electricity, tv }

BillCategory billCategory(String s) => switch (s) {
  'airtime' => BillCategory.airtime,
  'data' => BillCategory.data,
  'electricity' => BillCategory.electricity,
  _ => BillCategory.tv,
};

class BillPlan {
  BillPlan({required this.code, required this.name, required this.amount});

  factory BillPlan.fromJson(Map<String, dynamic> j) =>
      BillPlan(code: j['code'] as String, name: j['name'] as String, amount: j['amount'] as int);

  final String code;
  final String name;
  final int amount; // kobo
}

/// A network, DisCo or TV provider, with its fixed-price plans (data
/// bundles, TV packages). Airtime and electricity take any amount.
class Biller {
  Biller({
    required this.id,
    required this.name,
    required this.category,
    required this.customerLabel,
    required this.plans,
    required this.minAmount,
    required this.maxAmount,
  });

  factory Biller.fromJson(Map<String, dynamic> j) => Biller(
    id: j['id'] as String,
    name: j['name'] as String,
    category: billCategory(j['category'] as String),
    customerLabel: j['customer_label'] as String,
    plans: [for (final p in (j['plans'] as List? ?? const [])) BillPlan.fromJson(p as Map<String, dynamic>)],
    minAmount: j['min_amount'] as int? ?? 0,
    maxAmount: j['max_amount'] as int? ?? 0,
  );

  final String id;
  final String name;
  final BillCategory category;
  final String customerLabel; // "Phone number", "Meter number", "Smartcard number"
  final List<BillPlan> plans;
  final int minAmount;
  final int maxAmount;

  bool get hasPlans => plans.isNotEmpty;
  bool get needsLookup => category == BillCategory.electricity || category == BillCategory.tv;
}

enum BillStatus { success, pending, refunded }

class BillPayment {
  BillPayment({
    required this.id,
    required this.billerId,
    required this.billerName,
    required this.category,
    required this.planName,
    required this.customer,
    required this.customerName,
    required this.amount,
    required this.status,
    required this.token,
    required this.reference,
    required this.failureReason,
    required this.createdAt,
  });

  factory BillPayment.fromJson(Map<String, dynamic> j) => BillPayment(
    id: j['id'] as String,
    billerId: j['biller_id'] as String,
    billerName: j['biller_name'] as String,
    category: billCategory(j['category'] as String),
    planName: j['plan_name'] as String? ?? '',
    customer: j['customer'] as String,
    customerName: j['customer_name'] as String? ?? '',
    amount: j['amount'] as int,
    status: switch (j['status'] as String) {
      'success' => BillStatus.success,
      'refunded' => BillStatus.refunded,
      _ => BillStatus.pending,
    },
    token: j['token'] as String? ?? '',
    reference: j['reference'] as String? ?? '',
    failureReason: j['failure_reason'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String billerId;
  final String billerName;
  final BillCategory category;
  final String planName;
  final String customer;
  final String customerName;
  final int amount;
  final BillStatus status;
  final String token; // electricity prepaid token
  final String reference;
  final String failureReason;
  final DateTime createdAt;
}
