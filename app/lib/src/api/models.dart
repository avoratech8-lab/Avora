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
