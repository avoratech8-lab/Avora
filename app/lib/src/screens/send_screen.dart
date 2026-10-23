import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../ids.dart';
import '../money.dart';
import '../pay_code.dart';
import '../recipients.dart';
import '../ui/widgets.dart';
import 'avora_pay_screens.dart';
import 'transfer_screen.dart';

/// Step 1: who. Pick a bank, type the account number, and we look up the
/// name as soon as it has 10 digits. Saved recipients skip all of that.
class SendScreen extends StatefulWidget {
  const SendScreen({super.key, this.recipient, this.payCode});

  final Recipient? recipient;

  /// From a scanned QR code or a payment request.
  final PayCode? payCode;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _account = TextEditingController();
  Bank? _bank;
  String? _name;
  String? _error;
  bool _looking = false;
  int _lookup = 0; // ignores answers to lookups that are no longer current

  @override
  void initState() {
    super.initState();
    final r = widget.recipient;
    if (r != null) {
      _bank = banks.firstWhere((b) => b.code == r.bankCode, orElse: () => Bank(r.bankCode, bankName(r.bankCode)));
      _account.text = r.accountNumber;
      _name = r.accountName;
    }
    final code = widget.payCode;
    if (code != null) {
      if (code.bankCode.isNotEmpty) {
        _bank = banks.firstWhere(
          (b) => b.code == code.bankCode,
          orElse: () => Bank(code.bankCode, bankName(code.bankCode)),
        );
      }
      _account.text = code.accountNumber;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _changed();
      });
    }
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  void _changed() {
    final bank = _bank;
    final number = _account.text.trim();
    final id = ++_lookup;
    setState(() {
      _name = null;
      _error = null;
      _looking = false;
    });
    if (bank == null || !RegExp(r'^\d{10}$').hasMatch(number)) return;

    setState(() => _looking = true);
    AppScope.of(context).api
        .nameEnquiry(bankCode: bank.code, accountNumber: number)
        .then(
          (name) {
            if (mounted && id == _lookup) setState(() => _name = name);
          },
          onError: (Object e) {
            if (mounted && id == _lookup) {
              setState(() => _error = e is ApiException ? e.message : "We couldn't check that account. Try again.");
            }
          },
        )
        .whenComplete(() {
          if (mounted && id == _lookup) setState(() => _looking = false);
        });
  }

  Future<void> _pickBank() async {
    final b = await showModalBottomSheet<Bank>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _BankPicker(),
    );
    if (b != null) {
      _bank = b;
      _changed();
    }
  }

  void _continue(Recipient r) {
    final code = widget.payCode;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AmountScreen(recipient: r, amount: code?.amount ?? 0, note: code?.note ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recents = AppScope.of(context).recipients.items.where((r) => r.bankCode != avoraBank).toList();
    final bank = _bank;
    final name = _name;
    return Scaffold(
      appBar: AppBar(title: const Text('Send to bank')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  Text('Bank', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  Material(
                    color: theme.inputDecorationTheme.fillColor,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      key: const Key('bank'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: _pickBank,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Row(
                          children: [
                            if (bank != null)
                              InitialsAvatar(text: bank.name, size: 36)
                            else
                              const Icon(Icons.account_balance_outlined),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                bank?.name ?? 'Choose a bank',
                                style: bank == null
                                    ? theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                                    : theme.textTheme.titleSmall,
                              ),
                            ),
                            const Icon(Icons.expand_more_rounded),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text('Account number', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('account'),
                    controller: _account,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                    style: theme.textTheme.titleMedium?.copyWith(letterSpacing: 1.5),
                    decoration: InputDecoration(
                      hintText: '10 digits',
                      errorText: _error,
                      suffixIcon: _looking
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : null,
                    ),
                    onChanged: (_) => _changed(),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: name == null
                        ? const SizedBox(height: 8)
                        : Container(
                            key: ValueKey(name),
                            margin: const EdgeInsets.only(top: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                InitialsAvatar(text: name, size: 40),
                                const SizedBox(width: 12),
                                Expanded(child: Text(name, style: theme.textTheme.titleSmall)),
                                Icon(Icons.verified_rounded, color: theme.colorScheme.primary),
                              ],
                            ),
                          ),
                  ),
                  if (recents.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    Text('Recent', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final r in recents.take(6))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: InitialsAvatar(text: r.accountName),
                        title: Text(r.accountName, style: theme.textTheme.titleSmall),
                        subtitle: Text('${bankName(r.bankCode)} · ${r.accountNumber}'),
                        onTap: () => _continue(r),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                key: const Key('next'),
                label: 'Continue',
                onPressed: name == null || bank == null
                    ? null
                    : () => _continue(
                        Recipient(bankCode: bank.code, accountNumber: _account.text.trim(), accountName: name),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BankPicker extends StatefulWidget {
  const _BankPicker();

  @override
  State<_BankPicker> createState() => _BankPickerState();
}

class _BankPickerState extends State<_BankPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = banks.where((b) => b.name.toLowerCase().contains(_q.toLowerCase())).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Choose a bank', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('bank-search'),
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'Search banks', prefixIcon: Icon(Icons.search_rounded)),
                    onChanged: (v) => setState(() => _q = v.trim()),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  leading: InitialsAvatar(text: list[i].name, size: 40),
                  title: Text(list[i].name, style: theme.textTheme.titleSmall),
                  onTap: () => Navigator.pop(context, list[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 2: how much, on a big number pad, with a note.
class AmountScreen extends StatefulWidget {
  const AmountScreen({super.key, this.recipient, this.person, this.to = '', this.amount = 0, this.note = ''})
    : assert((recipient == null) != (person == null));

  /// A bank account to send to...
  final Recipient? recipient;

  /// ...or an Avora customer, paid by [to] (an @tag or phone number).
  final Person? person;
  final String to;

  /// Filled in from a payment request; the payer can still change them.
  final int amount;
  final String note;

  @override
  State<AmountScreen> createState() => _AmountScreenState();
}

class _AmountScreenState extends State<AmountScreen> {
  String _typed = '';
  final _note = TextEditingController();
  bool _busy = false;
  Wallet? _wallet;

  @override
  void initState() {
    super.initState();
    final a = widget.amount;
    if (a > 0) _typed = a % 100 == 0 ? '${a ~/ 100}' : '${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
    _note.text = widget.note;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wallet == null) {
      AppScope.of(context).api.wallet().then((w) {
        if (mounted) setState(() => _wallet = w);
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  int? get _amount => parseNaira(_typed);

  void _digit(String d) {
    final next = _typed + d;
    if (next == '0') return;
    final dot = next.indexOf('.');
    if (dot >= 0 && next.length - dot > 3) return;
    if ((dot < 0 ? next.length : dot) > 9) return;
    setState(() => _typed = next);
  }

  void _dot() {
    if (_typed.contains('.')) return;
    setState(() => _typed = _typed.isEmpty ? '0.' : '$_typed.');
  }

  String get _display {
    if (_typed.isEmpty) return '0';
    final parts = _typed.split('.');
    final whole = parts[0].isEmpty ? '0' : parts[0];
    final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return parts.length > 1 ? '$grouped.${parts[1]}' : grouped;
  }

  Future<void> _reviewAvora(Person p, int amount) async {
    final scope = AppScope.of(context);
    final note = _note.text.trim();
    final t = await showModalBottomSheet<P2PTransfer>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConfirmSheet(
        title: 'Send on Avora',
        avatar: p.name,
        headline: formatNaira(amount),
        rows: [
          ('To', p.name),
          if (p.tag.isNotEmpty) ('Tag', '@${p.tag}'),
          if (note.isNotEmpty) ('Note', note),
          ('Fee', 'Free'),
          ('Total', formatNaira(amount)),
        ],
        footnote: 'Avora to Avora is always free and arrives instantly.',
        action: (pin, key) =>
            scope.api.sendToAvora(to: widget.to, amount: amount, note: note, pin: pin, idempotencyKey: key),
      ),
    );
    if (t == null || !mounted) return;
    await scope.recipients.add(Recipient(bankCode: avoraBank, accountNumber: widget.to, accountName: p.name));
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => P2PReceiptScreen(id: t.id, initial: t),
      ),
      (route) => route.isFirst,
    );
  }

  Future<void> _review() async {
    final amount = _amount;
    if (amount == null) return;
    final person = widget.person;
    if (person != null) return _reviewAvora(person, amount);
    final api = AppScope.of(context).api;
    final scope = AppScope.of(context);
    setState(() => _busy = true);
    final Quote quote;
    try {
      quote = await api.quote(amount);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final r = widget.recipient!;
    final transfer = await showModalBottomSheet<Transfer>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConfirmSheet(
        title: 'Confirm transfer',
        avatar: r.accountName,
        headline: formatNaira(quote.amount),
        rows: [
          ('To', r.accountName),
          ('Account', '${r.accountNumber} · ${bankName(r.bankCode)}'),
          if (_note.text.trim().isNotEmpty) ('Note', _note.text.trim()),
          ('Fee', quote.fee == 0 ? 'Free' : formatNaira(quote.fee)),
          ('Total', formatNaira(quote.total)),
        ],
        footnote: quote.fee == 0
            ? 'This one is free. ${quote.freeTransfersLeft} free transfer${quote.freeTransfersLeft == 1 ? '' : 's'} left this month.'
            : "You've used this month's free transfers, so a ${formatNaira(quote.fee)} fee applies.",
        action: (pin, key) => api.send(
          bankCode: r.bankCode,
          accountNumber: r.accountNumber,
          amount: quote.amount,
          narration: _note.text.trim(),
          pin: pin,
          idempotencyKey: key,
        ),
      ),
    );
    if (transfer == null || !mounted) return;
    await scope.recipients.add(r);
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => TransferScreen(transferId: transfer.id, initial: transfer),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.recipient;
    final p = widget.person;
    final (who, where) = r != null
        ? (r.accountName, '${bankName(r.bankCode)} · ${r.accountNumber}')
        : (p!.name, p.tag.isNotEmpty ? 'Avora · @${p.tag} · free' : 'Avora · free');
    final amount = _amount;
    final w = _wallet;
    final over = w != null && amount != null && amount > w.balance;
    return Scaffold(
      appBar: AppBar(title: const Text('Amount')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    InitialsAvatar(text: who, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(who, style: theme.textTheme.titleSmall),
                          Text(where, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              FittedBox(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '₦',
                        style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      TextSpan(text: _display),
                    ],
                  ),
                  key: const Key('amount'),
                  style: theme.textTheme.displaySmall?.copyWith(fontSize: 48),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                over
                    ? 'More than your balance'
                    : w == null
                    ? ' '
                    : 'Balance: ${formatNaira(w.balance)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: over ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in [1000, 2000, 5000, 10000])
                    ActionChip(
                      label: Text(formatNaira(n * 100).replaceAll('.00', '')),
                      onPressed: () => setState(() => _typed = '$n'),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('narration'),
                controller: _note,
                maxLength: 100,
                decoration: const InputDecoration(
                  hintText: "What's it for? (optional)",
                  prefixIcon: Icon(Icons.edit_note_rounded),
                  counterText: '',
                ),
              ),
              const Spacer(),
              NumberPad(
                onDigit: _digit,
                extra: '.',
                onExtra: _dot,
                onBackspace: () {
                  if (_typed.isNotEmpty) setState(() => _typed = _typed.substring(0, _typed.length - 1));
                },
              ),
              const SizedBox(height: 8),
              PrimaryButton(
                key: const Key('review'),
                label: 'Continue',
                loading: _busy,
                onPressed: amount == null || over ? null : _review,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Review what will happen, then approve with the PIN on a number pad.
///
/// The idempotency key is made once per sheet, so a double tap or a retry
/// after a dropped connection can never pay twice. [action] gets the PIN
/// and that key and returns the result, which the sheet pops with.
class ConfirmSheet<T> extends StatefulWidget {
  const ConfirmSheet({
    super.key,
    required this.title,
    required this.avatar,
    required this.headline,
    required this.rows,
    required this.action,
    this.footnote,
  });

  final String title;
  final String avatar;
  final String headline;
  final List<(String, String)> rows;
  final String? footnote;
  final Future<T> Function(String pin, String idempotencyKey) action;

  @override
  State<ConfirmSheet<T>> createState() => _ConfirmSheetState<T>();
}

class _ConfirmSheetState<T> extends State<ConfirmSheet<T>> {
  final _key = randomId();
  bool _askPin = false;
  String _pin = '';
  bool _sending = false;
  String? _error;
  int _errorTick = 0;

  Future<void> _digit(String d) async {
    if (_sending || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < 6) return;
    await _approve(_pin);
  }

  /// Asks for a fingerprint or face instead of the PIN, when that's on.
  Future<void> _biometrics() async {
    if (_sending) return;
    final pin = await AppScope.of(context).security.pinByBiometrics('Approve ${widget.headline}');
    if (pin == null || !mounted) return;
    setState(() => _pin = pin);
    await _approve(pin);
  }

  Future<void> _approve(String pin) async {
    setState(() => _sending = true);
    try {
      final result = await widget.action(pin, _key);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _sending = false;
        _pin = '';
        _errorTick++;
        _error = e is ApiException ? e.message : 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          child: _askPin ? _pinStep(theme) : _summary(theme),
        ),
      ),
    );
  }

  Widget _summary(ThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      InitialsAvatar(text: widget.avatar, size: 56),
      const SizedBox(height: 10),
      Text(widget.title, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      Text(widget.headline, style: theme.textTheme.headlineMedium),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(color: theme.inputDecorationTheme.fillColor, borderRadius: BorderRadius.circular(18)),
        child: Column(
          children: [
            for (final (i, (l, v)) in widget.rows.indexed)
              DetailRow(label: l, value: v, bold: i == widget.rows.length - 1),
          ],
        ),
      ),
      if (widget.footnote != null) ...[
        const SizedBox(height: 10),
        Text(
          widget.footnote!,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
      const SizedBox(height: 20),
      PrimaryButton(
        key: const Key('confirm'),
        label: 'Confirm',
        onPressed: () {
          setState(() => _askPin = true);
          if (AppScope.of(context).security.biometricsOn) _biometrics();
        },
      ),
    ],
  );

  Widget _pinStep(ThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Enter your PIN', style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        'to approve ${widget.headline}',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 24),
      PinDots(key: const Key('send-pin'), filled: _pin.length, errorTick: _errorTick),
      SizedBox(
        height: 44,
        child: Center(
          child: _sending
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error == null
              ? null
              : Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                ),
        ),
      ),
      NumberPad(
        onDigit: _digit,
        onBackspace: () {
          if (_pin.isNotEmpty && !_sending) setState(() => _pin = _pin.substring(0, _pin.length - 1));
        },
        extraIcon: AppScope.of(context).security.biometricsOn ? Icons.fingerprint_rounded : null,
        onExtra: _biometrics,
      ),
    ],
  );
}
