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

  /// Changes the PIN; other phones are signed out.
  Future<void> changePin({required String oldPin, required String newPin});

  /// Checks the PIN without moving money, to unlock the app.
  Future<void> verifyPin(String pin);

  Future<List<Device>> devices();
  Future<void> removeDevice(int id);

  Future<KycStatus> kycStatus();

  /// Verifies a BVN or NIN ([kind] is 'bvn' or 'nin') to raise the tier.
  Future<KycStatus> verifyKyc({required String kind, required String number});

  /// The latest notifications and how many are unread.
  Future<(List<AppNotification>, int)> notifications();
  Future<void> markNotificationsRead();

  Future<Profile> profile();

  /// Sets my name and/or @tag; empty values are left as they are.
  Future<Profile> updateProfile({String name = '', String tag = ''});

  /// Finds an Avora customer by @tag or phone number.
  Future<Person> findPerson(String query);

  /// Sends money to another Avora customer: free and instant.
  Future<P2PTransfer> sendToAvora({
    required String to,
    required int amount,
    required String note,
    required String pin,
    required String idempotencyKey,
  });
  Future<P2PTransfer> p2pTransfer(String id);

  /// Money in and out for the month holding [month] (this month if null).
  Future<Insights> insights({DateTime? month});

  /// Monthly budgets by category ([allSpending] for everything).
  Future<Map<String, int>> budgets();

  /// Sets a monthly budget; 0 removes it.
  Future<Map<String, int>> setBudget(String category, int amount);

  Future<CardList> cards();
  Future<VirtualCard> createCard(String name);
  Future<VirtualCard> freezeCard(String id, bool frozen);

  /// Caps what a card can spend each month; 0 removes the cap.
  Future<VirtualCard> setCardLimit(String id, int amount);
  Future<CardDetails> cardDetails(String id, String pin);
  Future<void> closeCard(String id, String pin);
  Future<List<CardPayment>> cardPayments(String id);

  /// Sandbox only: pays a test merchant with the card, as if online.
  Future<CardPayment> testCardPayment(String id, {required String merchant, required int amount, required String key});

  Future<RoundUp> roundUp();

  /// Turns round-ups on into a goal pot, or off when [potId] is ''.
  Future<RoundUp> setRoundUp({required String potId, required int step});

  Future<ReferralSummary> referrals();

  /// Records the invite code this customer joined with.
  Future<ReferralSummary> joinReferral(String code);

  Future<List<HelpArticle>> helpArticles();
  Future<List<SupportMessage>> supportMessages();

  /// Sends a chat message; the reply comes back with the conversation.
  Future<List<SupportMessage>> sendSupportMessage(String body);

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
