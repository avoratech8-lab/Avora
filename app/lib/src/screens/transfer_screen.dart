import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/receipt.dart';

/// One transfer, kept up to date until it reaches a final state.
class TransferScreen extends StatefulWidget {
  const TransferScreen({
    super.key,
    required this.transferId,
    this.initial,
    this.pollEvery = const Duration(seconds: 3),
  });

  final String transferId;
  final Transfer? initial;
  final Duration pollEvery;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  Transfer? _t;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _t = widget.initial;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer == null) {
      _load();
      _timer = Timer.periodic(widget.pollEvery, (_) => _load());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_t?.isFinal ?? false) {
      _timer?.cancel();
      return;
    }
    try {
      final t = await AppScope.of(context).api.transfer(widget.transferId);
      if (!mounted) return;
      setState(() {
        _t = t;
        _error = null;
      });
      if (t.isFinal) _timer?.cancel();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: const Text('Transfer')),
      body: t == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : const Text("We couldn't load this transfer. Pull down on the home screen to refresh."),
            )
          : _receipt(t),
    );
  }

  Widget _receipt(Transfer t) {
    final s = statusInfo(t.status);
    final rows = <(String, String)>[
      ('To', t.accountName),
      ('Account', '${t.accountNumber} · ${bankName(t.bankCode)}'),
      if (t.narration.isNotEmpty) ('Note', t.narration),
      ('Fee', t.fee == 0 ? 'Free' : formatNaira(t.fee)),
      ('Date', formatWhen(t.createdAt)),
      if (t.sessionId.isNotEmpty) ('Session ID', t.sessionId),
      ('Reference', t.id),
      if (t.status == TransferStatus.refunded && t.failureReason.isNotEmpty) ('Reason', t.failureReason),
    ];
    return ReceiptView(
      tone: s.tone,
      title: s.title,
      explanation: s.explanation,
      amount: formatNaira(t.amount),
      rows: rows,
      shareText: receiptText('Transfer to ${t.accountName}', formatNaira(t.amount), s.title, rows),
      note: t.sessionId.isEmpty
          ? null
          : 'If they say it has not arrived, share this receipt. Their bank can trace the session ID.',
    );
  }
}

class StatusInfo {
  const StatusInfo(this.title, this.explanation, this.tone);

  final String title;
  final String explanation;
  final ReceiptTone tone;
}

/// What each status means, in words a customer can act on.
StatusInfo statusInfo(TransferStatus s) => switch (s) {
  TransferStatus.held || TransferStatus.sent => const StatusInfo(
    'Sending…',
    'Your money is on its way. This usually takes a few seconds.',
    ReceiptTone.pending,
  ),
  TransferStatus.delivered => const StatusInfo('Delivered', 'The money has reached their account.', ReceiptTone.good),
  TransferStatus.refunded => const StatusInfo(
    "Didn't go through",
    'The full amount, fee included, is back in your wallet.',
    ReceiptTone.bad,
  ),
  TransferStatus.needsReview => const StatusInfo(
    "We're checking with the bank",
    "Your money is safe. The bank hasn't confirmed yet, so our team is checking. "
        "If it didn't arrive, you'll get a full refund.",
    ReceiptTone.warn,
  ),
};
