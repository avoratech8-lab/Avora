import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../dates.dart';
import '../money.dart';

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
      body: SafeArea(
        child: t == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : const Text("We couldn't load this transfer. Pull down on the home screen to refresh."),
              )
            : _Details(t: t),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.t});

  final Transfer t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = statusInfo(t.status);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: s.done
              ? Icon(s.icon, size: 64, color: s.good ? theme.colorScheme.primary : theme.colorScheme.error)
              : const SizedBox(width: 56, height: 56, child: CircularProgressIndicator()),
        ),
        const SizedBox(height: 16),
        Text(
          s.title,
          key: const Key('status-title'),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(s.explanation, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Text(formatNaira(t.amount), textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
        const SizedBox(height: 24),
        _row('To', t.accountName),
        _row('Account', '${t.accountNumber} · ${bankName(t.bankCode)}'),
        if (t.narration.isNotEmpty) _row('For', t.narration),
        _row('Fee', t.fee == 0 ? 'Free' : formatNaira(t.fee)),
        _row('Date', formatWhen(t.createdAt)),
        if (t.sessionId.isNotEmpty) _row('Session ID', t.sessionId, selectable: true),
        _row('Reference', t.id, selectable: true),
        if (t.status == TransferStatus.refunded && t.failureReason.isNotEmpty) _row('Reason', t.failureReason),
        if (t.sessionId.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'If the person says they did not get it, give them the session ID. Their bank can trace it.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _row(String label, String value, {bool selectable = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 96, child: Text(label)),
        Expanded(
          child: selectable ? SelectableText(value, textAlign: TextAlign.end) : Text(value, textAlign: TextAlign.end),
        ),
      ],
    ),
  );
}

class StatusInfo {
  const StatusInfo(this.title, this.explanation, this.icon, {this.done = false, this.good = false});

  final String title;
  final String explanation;
  final IconData icon;
  final bool done;
  final bool good;
}

/// What each status means, in words a customer can act on.
StatusInfo statusInfo(TransferStatus s) => switch (s) {
  TransferStatus.held || TransferStatus.sent => const StatusInfo(
    'Sending…',
    'Your money is on its way. This usually takes a few seconds.',
    Icons.schedule,
  ),
  TransferStatus.delivered => const StatusInfo(
    'Delivered',
    'The money has reached their account.',
    Icons.check_circle,
    done: true,
    good: true,
  ),
  TransferStatus.refunded => const StatusInfo(
    "Didn't go through",
    'The full amount, fee included, is back in your wallet.',
    Icons.undo,
    done: true,
  ),
  TransferStatus.needsReview => const StatusInfo(
    "We're checking with the bank",
    "Your money is safe. The bank hasn't confirmed yet, so our team is checking. "
        "If it didn't arrive, you'll get a full refund.",
    Icons.support_agent,
  ),
};
