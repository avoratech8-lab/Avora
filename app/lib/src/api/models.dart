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

  Map<String, dynamic> toJson() => {'id': id, 'account_number': accountNumber, 'balance': balance};
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

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'description': description,
    'ref': ref,
    'amount': amount,
    'at': at.toUtc().toIso8601String(),
  };
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

enum BillCategory { airtime, data, electricity, tv, internet, education, betting }

BillCategory billCategory(String s) => BillCategory.values.where((c) => c.name == s).firstOrNull ?? BillCategory.tv;

class BillPlan {
  BillPlan({required this.code, required this.name, required this.amount});

  factory BillPlan.fromJson(Map<String, dynamic> j) =>
      BillPlan(code: j['code'] as String, name: j['name'] as String, amount: j['amount'] as int);

  final String code;
  final String name;
  final int amount; // kobo
}

/// A network, DisCo, TV, internet, exam or betting provider, with its
/// fixed-price plans (data bundles, TV packages, exam PINs). Airtime,
/// electricity and betting take any amount.
class Biller {
  Biller({
    required this.id,
    required this.name,
    required this.category,
    required this.customerLabel,
    required this.plans,
    required this.minAmount,
    required this.maxAmount,
    this.cashbackBps = 0,
  });

  /// Cashback on one payment is capped at ₦500.
  static const maxCashback = 50000;

  factory Biller.fromJson(Map<String, dynamic> j) => Biller(
    id: j['id'] as String,
    name: j['name'] as String,
    category: billCategory(j['category'] as String),
    customerLabel: j['customer_label'] as String,
    plans: [for (final p in (j['plans'] as List? ?? const [])) BillPlan.fromJson(p as Map<String, dynamic>)],
    minAmount: j['min_amount'] as int? ?? 0,
    maxAmount: j['max_amount'] as int? ?? 0,
    cashbackBps: j['cashback_bps'] as int? ?? 0,
  );

  final String id;
  final String name;
  final BillCategory category;
  final String customerLabel; // "Phone number", "Meter number", "Smartcard number"
  final List<BillPlan> plans;
  final int minAmount;
  final int maxAmount;
  final int cashbackBps; // paid back once the biller confirms

  bool get hasPlans => plans.isNotEmpty;

  /// Paid to a phone number, with no name to check.
  bool get byPhone => customerLabel == 'Phone number';
  bool get needsLookup => !byPhone;

  int cashback(int amount) => (amount * cashbackBps ~/ 10000).clamp(0, maxCashback);

  /// "2%" or "2.5%".
  String get cashbackRate => '${(cashbackBps / 100).toStringAsFixed(cashbackBps % 100 == 0 ? 0 : 1)}%';
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
    this.cashback = 0,
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
    cashback: j['cashback'] as int? ?? 0,
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
  final int cashback; // earned back; 0 if refunded
  final BillStatus status;
  final String token; // electricity token or exam PIN
  final String reference;
  final String failureReason;
  final DateTime createdAt;
}

enum PotKind { goal, locked }

class SavingsTerm {
  SavingsTerm({required this.days, required this.rateBps});

  factory SavingsTerm.fromJson(Map<String, dynamic> j) =>
      SavingsTerm(days: j['days'] as int, rateBps: j['rate_bps'] as int);

  final int days;
  final int rateBps; // expected yearly profit rate, not promised
}

/// Expected (indicative) yearly profit rates shown before saving.
class SavingsRates {
  SavingsRates({required this.goalBps, required this.terms});

  factory SavingsRates.fromJson(Map<String, dynamic> j) => SavingsRates(
    goalBps: j['goal_rate_bps'] as int,
    terms: [for (final t in j['locked_terms'] as List) SavingsTerm.fromJson(t as Map<String, dynamic>)],
  );

  final int goalBps;
  final List<SavingsTerm> terms;
}

class SavingsPot {
  SavingsPot({
    required this.id,
    required this.kind,
    required this.name,
    required this.target,
    required this.lockDays,
    required this.maturesAt,
    required this.balance,
    required this.profitEarned,
    required this.expectedRateBps,
    required this.open,
    required this.createdAt,
  });

  factory SavingsPot.fromJson(Map<String, dynamic> j) => SavingsPot(
    id: j['id'] as String,
    kind: j['kind'] == 'locked' ? PotKind.locked : PotKind.goal,
    name: j['name'] as String,
    target: j['target'] as int? ?? 0,
    lockDays: j['lock_days'] as int? ?? 0,
    maturesAt: j['matures_at'] == null ? null : DateTime.parse(j['matures_at'] as String),
    balance: j['balance'] as int,
    profitEarned: j['profit_earned'] as int? ?? 0,
    expectedRateBps: j['expected_rate_bps'] as int? ?? 0,
    open: j['status'] != 'closed',
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final PotKind kind;
  final String name;
  final int target;
  final int lockDays;
  final DateTime? maturesAt;
  final int balance;
  final int profitEarned;
  final int expectedRateBps;
  final bool open;
  final DateTime createdAt;

  bool isMatured(DateTime now) => maturesAt == null || !now.isBefore(maturesAt!);
  double get progress => target <= 0 ? 0 : (balance / target).clamp(0, 1).toDouble();
}

/// Rough profit if the bank's results match the expected rate.
int expectedProfit(int amount, int rateBps, int days) => amount * rateBps * days ~/ (10000 * 365);

/// A phone the customer has signed in on.
class Device {
  Device({
    required this.id,
    required this.name,
    required this.boundAt,
    required this.thisPhone,
    required this.signedIn,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as int,
    name: j['name'] as String? ?? '',
    boundAt: DateTime.parse(j['bound_at'] as String),
    thisPhone: j['this_phone'] as bool? ?? false,
    signedIn: j['signed_in'] as bool? ?? false,
  );

  final int id;
  final String name;
  final DateTime boundAt;
  final bool thisPhone;
  final bool signedIn;
}

/// What a KYC tier allows.
class KycTier {
  KycTier({required this.tier, required this.dailySend, required this.maxBalance, required this.needs});

  factory KycTier.fromJson(Map<String, dynamic> j) => KycTier(
    tier: j['tier'] as int,
    dailySend: j['daily_send'] as int,
    maxBalance: j['max_balance'] as int,
    needs: j['needs'] as String? ?? '',
  );

  final int tier;
  final int dailySend; // kobo
  final int maxBalance; // kobo; 0 means no cap
  final String needs;
}

class KycStatus {
  KycStatus({required this.tier, required this.bvnVerified, required this.ninVerified, required this.tiers});

  factory KycStatus.fromJson(Map<String, dynamic> j) => KycStatus(
    tier: j['tier'] as int,
    bvnVerified: j['bvn_verified'] as bool? ?? false,
    ninVerified: j['nin_verified'] as bool? ?? false,
    tiers: (j['tiers'] as List).map((t) => KycTier.fromJson(t as Map<String, dynamic>)).toList(),
  );

  final int tier;
  final bool bvnVerified;
  final bool ninVerified;
  final List<KycTier> tiers;

  KycTier get limits => tiers.firstWhere((t) => t.tier == tier, orElse: () => tiers.first);
}

class AppNotification {
  AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.ref,
    required this.createdAt,
    required this.read,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: j['id'] as int,
    kind: j['kind'] as String,
    title: j['title'] as String,
    body: j['body'] as String? ?? '',
    ref: j['ref'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String),
    read: j['read_at'] != null,
  );

  final int id;
  final String kind;
  final String title;
  final String body;
  final String ref;
  final DateTime createdAt;
  final bool read;
}

class ReferralSummary {
  ReferralSummary({
    required this.code,
    required this.reward,
    required this.invited,
    required this.rewarded,
    required this.earned,
    required this.joinedWith,
    required this.canAddCode,
  });

  factory ReferralSummary.fromJson(Map<String, dynamic> j) => ReferralSummary(
    code: j['code'] as String,
    reward: j['reward'] as int? ?? 0,
    invited: j['invited'] as int? ?? 0,
    rewarded: j['rewarded'] as int? ?? 0,
    earned: j['earned'] as int? ?? 0,
    joinedWith: j['joined_with'] as String? ?? '',
    canAddCode: j['can_add_code'] as bool? ?? false,
  );

  final String code;
  final int reward; // kobo per verified friend
  final int invited;
  final int rewarded;
  final int earned; // kobo
  final String joinedWith;
  final bool canAddCode;
}

class HelpArticle {
  const HelpArticle({required this.id, required this.topic, required this.title, required this.body});

  factory HelpArticle.fromJson(Map<String, dynamic> j) => HelpArticle(
    id: j['id'] as String,
    topic: j['topic'] as String,
    title: j['title'] as String,
    body: j['body'] as String,
  );

  final String id;
  final String topic;
  final String title;
  final String body;
}

class SupportMessage {
  SupportMessage({required this.id, required this.sender, required this.body, required this.createdAt});

  factory SupportMessage.fromJson(Map<String, dynamic> j) => SupportMessage(
    id: j['id'] as int,
    sender: j['sender'] as String,
    body: j['body'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final int id;
  final String sender; // customer, bot or agent
  final String body;
  final DateTime createdAt;

  bool get mine => sender == 'customer';
}

/// My name, tag and account details.
class Profile {
  Profile({required this.name, required this.tag, required this.phone, required this.accountNumber});

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    name: j['name'] as String? ?? '',
    tag: j['tag'] as String? ?? '',
    phone: j['phone'] as String? ?? '',
    accountNumber: j['account_number'] as String? ?? '',
  );

  final String name;
  final String tag; // without the @
  final String phone;
  final String accountNumber;
}

/// Another Avora customer, as a payer sees them.
class Person {
  const Person({required this.tag, required this.name, required this.phone});

  factory Person.fromJson(Map<String, dynamic> j) =>
      Person(tag: j['tag'] as String? ?? '', name: j['name'] as String? ?? '', phone: j['phone'] as String? ?? '');

  final String tag;
  final String name;
  final String phone; // masked

  /// What to send to: the tag if they have one, otherwise the phone.
  String get handle => tag.isNotEmpty ? '@$tag' : phone;
}

/// A free, instant transfer between Avora wallets.
class P2PTransfer {
  P2PTransfer({
    required this.id,
    required this.outgoing,
    required this.amount,
    required this.note,
    required this.other,
    required this.createdAt,
  });

  factory P2PTransfer.fromJson(Map<String, dynamic> j) => P2PTransfer(
    id: j['id'] as String,
    outgoing: j['direction'] == 'out',
    amount: j['amount'] as int,
    note: j['note'] as String? ?? '',
    other: Person.fromJson(j['other'] as Map<String, dynamic>),
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final bool outgoing;
  final int amount;
  final String note;
  final Person other;
  final DateTime createdAt;
}
