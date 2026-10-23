import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../ids.dart';
import '../money.dart';
import 'transfer_screen.dart';

/// Pick a bank, type the account number (we look up the name as soon as it
/// has 10 digits), enter an amount, then review and approve with the PIN.
class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _account = TextEditingController();
  final _amount = TextEditingController();
  final _narration = TextEditingController();

  Bank? _bank;
  String? _accountName;
  String? _lookupError;
  bool _lookingUp = false;
  int _lookup = 0; // ignores answers to lookups that are no longer current
  String? _amountError;
  bool _busy = false;

  @override
  void dispose() {
    _account.dispose();
    _amount.dispose();
    _narration.dispose();
    super.dispose();
  }

  void _recipientChanged() {
    final bank = _bank;
    final number = _account.text.trim();
    final id = ++_lookup;
    setState(() {
      _accountName = null;
      _lookupError = null;
      _lookingUp = false;
    });
    if (bank == null || !RegExp(r'^\d{10}$').hasMatch(number)) return;

    setState(() => _lookingUp = true);
    AppScope.of(context).api
        .nameEnquiry(bankCode: bank.code, accountNumber: number)
        .then(
          (name) {
            if (mounted && id == _lookup) setState(() => _accountName = name);
          },
          onError: (Object e) {
            if (mounted && id == _lookup) {
              setState(
                () => _lookupError = e is ApiException ? e.message : "We couldn't check that account. Try again.",
              );
            }
          },
        )
        .whenComplete(() {
          if (mounted && id == _lookup) setState(() => _lookingUp = false);
        });
  }

  Future<void> _review() async {
    final amount = parseNaira(_amount.text);
    setState(() => _amountError = amount == null ? 'Enter an amount, like 5,000' : null);
    if (amount == null || _accountName == null || _bank == null) return;

    setState(() => _busy = true);
    final api = AppScope.of(context).api;
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

    final transfer = await showModalBottomSheet<Transfer>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReviewSheet(
        api: api,
        bank: _bank!,
        accountNumber: _account.text.trim(),
        accountName: _accountName!,
        narration: _narration.text.trim(),
        quote: quote,
      ),
    );
    if (transfer != null && mounted) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => TransferScreen(transferId: transfer.id, initial: transfer),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _accountName != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Send money')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<Bank>(
              key: const Key('bank'),
              initialValue: _bank,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Bank', border: OutlineInputBorder()),
              items: [for (final b in banks) DropdownMenuItem(value: b, child: Text(b.name))],
              onChanged: (b) {
                _bank = b;
                _recipientChanged();
              },
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('account'),
              controller: _account,
              keyboardType: TextInputType.number,
              maxLength: 10,
              decoration: InputDecoration(
                labelText: 'Account number',
                border: const OutlineInputBorder(),
                errorText: _lookupError,
                helperText: _accountName,
                helperStyle: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                suffixIcon: _lookingUp
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : _accountName != null
                    ? Icon(Icons.verified, color: theme.colorScheme.primary)
                    : null,
              ),
              onChanged: (_) => _recipientChanged(),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '₦ ',
                errorText: _amountError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('narration'),
              controller: _narration,
              maxLength: 100,
              decoration: const InputDecoration(labelText: "What's it for? (optional)", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('review'),
              onPressed: ready ? _review : null,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Review'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows exactly what will leave the wallet, then takes the PIN. The
/// idempotency key is made once per review, so tapping Send twice (or
/// retrying after a dropped connection) can never send twice.
class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({
    required this.api,
    required this.bank,
    required this.accountNumber,
    required this.accountName,
    required this.narration,
    required this.quote,
  });

  final AvoraApi api;
  final Bank bank;
  final String accountNumber;
  final String accountName;
  final String narration;
  final Quote quote;

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  final _pin = TextEditingController();
  final _key = randomId();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final pin = _pin.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _error = 'Enter your 6-digit PIN');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final t = await widget.api.send(
        bankCode: widget.bank.code,
        accountNumber: widget.accountNumber,
        amount: widget.quote.amount,
        narration: widget.narration,
        pin: pin,
        idempotencyKey: _key,
      );
      if (mounted) Navigator.of(context).pop(t);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e is ApiException ? e.message : 'Something went wrong. Please try again.';
        _pin.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = widget.quote;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Confirm transfer', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          _row('To', widget.accountName),
          _row('Account', '${widget.accountNumber} · ${widget.bank.name}'),
          if (widget.narration.isNotEmpty) _row('For', widget.narration),
          const Divider(height: 24),
          _row('Amount', formatNaira(q.amount)),
          _row('Fee', q.fee == 0 ? 'Free' : formatNaira(q.fee)),
          _row('Total', formatNaira(q.total), bold: true),
          const SizedBox(height: 4),
          Text(
            q.fee == 0
                ? 'This one is free. You have ${q.freeTransfersLeft} free transfer${q.freeTransfersLeft == 1 ? '' : 's'} left this month.'
                : "You've used your free transfers this month.",
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('send-pin'),
            controller: _pin,
            autofocus: true,
            obscureText: true,
            maxLength: 6,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'PIN', errorText: _error, border: const OutlineInputBorder()),
            onSubmitted: (_) => _send(),
          ),
          FilledButton(
            key: const Key('confirm'),
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text('Send ${formatNaira(q.amount)}'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 80, child: Text(label)),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null,
          ),
        ),
      ],
    ),
  );
}
