import 'models.dart';

/// The help centre for demo mode. The server has the same articles and
/// answers (backend/internal/support), so keep the two in step.
class _A {
  const _A(this.id, this.topic, this.title, this.body, this.keywords);

  final String id;
  final String topic;
  final String title;
  final String body;
  final List<String> keywords;
}

const _articles = [
  _A(
    'transfer-pending',
    'Transfers',
    'My transfer hasn\'t arrived',
    'Most transfers arrive in seconds. If the other bank is slow, your receipt says "With the bank" and we keep checking. If the bank declines it or doesn\'t confirm, the full amount and fee come back to your wallet automatically. You don\'t need to call anyone.',
    ['arrived', 'pending', 'didn\'t receive', 'not received', 'delay', 'stuck', 'where is my'],
  ),
  _A(
    'transfer-fees',
    'Transfers',
    'How much do transfers cost?',
    'Your first 5 transfers each month are free. After that each transfer costs ₦10. The fee is always shown before you approve.',
    ['fee', 'charge', 'cost', 'free', 'how much'],
  ),
  _A(
    'wrong-account',
    'Transfers',
    'I sent money to the wrong account',
    'We check the account name before you send, so look at the receipt first. If it went to the wrong person, chat with an agent here with the receipt; we will ask the other bank to recall it. Recalls depend on the receiver\'s bank and aren\'t guaranteed.',
    ['wrong account', 'wrong person', 'mistake', 'reverse', 'recall'],
  ),
  _A(
    'add-money',
    'Wallet',
    'How do I add money?',
    'Send money from any bank app to your Avora account number at TAJBank. It shows on Home and under Add money. Credits of ₦10,000 or more carry the government\'s ₦50 electronic money transfer levy.',
    ['add money', 'fund', 'deposit', 'top up', 'account number', 'receive'],
  ),
  _A(
    'limits',
    'Account',
    'Why can\'t I send more?',
    'Each account tier has a daily limit set by the CBN: Tier 1 ₦50,000, Tier 2 ₦200,000 and Tier 3 ₦5,000,000. Verify your BVN or NIN under Me → Limits to move up. A newly added phone can send up to ₦20,000 in its first 24 hours.',
    ['limit', 'tier', 'upgrade', 'bvn', 'nin', 'can\'t send', 'maximum'],
  ),
  _A(
    'pin',
    'Security',
    'I forgot my PIN or it\'s locked',
    'After 5 wrong PINs the account locks for 30 minutes to keep it safe. If you remember your PIN, change it under Me → Security. If you\'ve forgotten it, chat with an agent and we will verify you and help you reset it.',
    ['pin', 'forgot', 'locked', 'reset', 'password'],
  ),
  _A(
    'fraud',
    'Security',
    'I think someone else is using my account',
    'Change your PIN now under Me → Security, which signs out your other phones, and remove any phone you don\'t know under Phones signed in. Then chat with an agent. Avora staff will never ask for your PIN or sign-in code.',
    ['fraud', 'hacked', 'scam', 'stolen', 'someone else', 'unauthorized', 'unauthorised'],
  ),
  _A(
    'bill-failed',
    'Bills',
    'My airtime, data or electricity didn\'t come',
    'If the provider declines a payment, the full amount comes back to your wallet automatically and your receipt shows it. For electricity, the token is on the receipt; type it into your meter.',
    ['airtime', 'data', 'electricity', 'token', 'meter', 'dstv', 'gotv', 'startimes', 'bill', 'recharge'],
  ),
  _A(
    'savings-profit',
    'Savings',
    'How does interest-free savings work?',
    'Avora savings are non-interest. Your savings are invested with our partner bank under mudarabah, and you get a share of the profit it actually makes, paid after each month. The rates shown are expected, not promised. Goal pots can be emptied any time; locked plans earn more but give back their profit share if you break them early.',
    ['saving', 'profit', 'interest', 'halal', 'mudarabah', 'locked', 'goal'],
  ),
  _A(
    'referrals',
    'Account',
    'How do referral rewards work?',
    'Share your invite code from Me → Invite friends. When a friend joins with it and verifies their BVN or NIN, you get a reward in your wallet. Friends can add a code within 30 days of joining.',
    ['refer', 'invite', 'code', 'reward', 'bonus'],
  ),
];

List<HelpArticle> demoHelpArticles() => [
  for (final a in _articles) HelpArticle(id: a.id, topic: a.topic, title: a.title, body: a.body),
];

const supportHandoff =
    "I've passed this to our support team. An agent will reply here, usually within 15 minutes between 7am and 10pm.";

/// Picks the article that best matches [question], or hands over to a person.
String supportAnswer(String question) {
  final q = question.toLowerCase();
  if (['agent', 'human', 'person', 'customer care', 'speak to'].any(q.contains)) return supportHandoff;
  _A? best;
  var score = 0;
  for (final a in _articles) {
    final n = a.keywords.where(q.contains).length;
    if (n > score) {
      best = a;
      score = n;
    }
  }
  if (best == null) return supportHandoff;
  return '${best.title}\n\n${best.body}\n\nIf that doesn\'t help, type "agent" to talk to a person.';
}
