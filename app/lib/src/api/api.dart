import 'models.dart';

/// Everything the app asks of the backend. [HttpAvoraApi] talks to the real
/// server; [DemoAvoraApi] runs in memory so the app can be tried with no
/// server and no real money.
abstract class AvoraApi {
  bool get isDemo;

  /// Texts a code to [phone] and returns the challenge id.
  Future<String> startOtp(String phone);

  /// Signs up (choosing [pin]) or signs in (checking [pin]).
  Future<Session> verify({required String challengeId, required String code, required String pin});

  Future<Wallet> wallet();
  Future<List<StatementLine>> statement();
  Future<String> nameEnquiry({required String bankCode, required String accountNumber});
  Future<Quote> quote(int amount);
  Future<Transfer> send({
    required String bankCode,
    required String accountNumber,
    required int amount,
    required String narration,
    required String pin,
    required String idempotencyKey,
  });
  Future<Transfer> transfer(String id);

  /// Networks, DisCos and TV providers.
  Future<List<Biller>> billers();

  /// The name on a meter or smartcard, so the customer can check it.
  Future<String> validateBillCustomer({required String billerId, required String customer});

  Future<BillPayment> payBill({
    required String billerId,
    String? planCode,
    required String customer,
    required int amount,
    required String pin,
    required String idempotencyKey,
  });
  Future<BillPayment> billPayment(String id);

  Future<(List<SavingsPot>, SavingsRates)> savings();
  Future<SavingsPot> createPot({
    required PotKind kind,
    required String name,
    int target = 0,
    int lockDays = 0,
    int amount = 0,
    required String idempotencyKey,
  });
  Future<SavingsPot> depositToPot(String id, int amount, {required String idempotencyKey});

  /// Takes [amount] out of a goal pot, or everything out of a locked plan
  /// (which must have matured unless [breakEarly]).
  Future<SavingsPot> withdrawFromPot(
    String id, {
    int amount = 0,
    bool breakEarly = false,
    required String idempotencyKey,
  });
  Future<void> logout();
}

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.status = 0});

  final String code;
  final String message; // safe to show the customer
  final int status;

  bool get isUnauthorized => code == 'unauthorized';

  @override
  String toString() => 'ApiException($code, $status): $message';
}
