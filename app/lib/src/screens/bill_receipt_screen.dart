import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/receipt.dart';

/// Receipt for a bill payment: airtime, data, electricity, TV, internet,
/// exam PINs or betting top-ups.
class BillReceiptScreen extends StatefulWidget {
  const BillReceiptScreen({super.key, required this.paymentId, this.initial});

  final String paymentId;
  final BillPayment? initial;

  @override
  State<BillReceiptScreen> createState() => _BillReceiptScreenState();
}

class _BillReceiptScreenState extends State<BillReceiptScreen> {
  BillPayment? _p;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _p = widget.initial;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_p == null && _error == null) {
      AppScope.of(context).api
          .billPayment(widget.paymentId)
          .then(
            (p) {
              if (mounted) setState(() => _p = p);
            },
            onError: (Object e) {
              if (mounted) setState(() => _error = e);
            },
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: p == null
          ? Center(
              child: _error == null ? const CircularProgressIndicator() : const Text("We couldn't load this payment."),
            )
          : _receipt(p),
    );
  }

  Widget _receipt(BillPayment p) {
    final (title, explanation, tone) = switch (p.status) {
      BillStatus.success => ('Successful', _doneText(p), ReceiptTone.good),
      BillStatus.refunded => ("Didn't go through", 'The full amount is back in your wallet.', ReceiptTone.bad),
      BillStatus.pending => (
        'Processing…',
        'The provider is confirming. This usually takes a few seconds.',
        ReceiptTone.pending,
      ),
    };
    final rows = <(String, String)>[
      (
        'Service',
        switch (p.category) {
          BillCategory.airtime => 'Airtime',
          BillCategory.data => 'Data',
          BillCategory.electricity => 'Electricity',
          BillCategory.tv => 'TV',
          BillCategory.internet => 'Internet',
          BillCategory.education => 'Exam PIN',
          BillCategory.betting => 'Betting top-up',
        },
      ),
      ('Provider', p.billerName),
      if (p.planName.isNotEmpty) ('Plan', p.planName),
      ('Number', p.customer),
      if (p.customerName.isNotEmpty) ('Name', p.customerName),
      if (p.cashback > 0) ('Cashback', '+${formatNaira(p.cashback)} to your wallet'),
      ('Date', formatWhen(p.createdAt)),
      if (p.reference.isNotEmpty) ('Reference', p.reference),
      if (p.failureReason.isNotEmpty) ('Reason', p.failureReason),
    ];
    final highlight = p.token.isEmpty
        ? null
        : (p.category == BillCategory.education ? 'Your ${p.planName}' : 'Electricity token', p.token);
    return ReceiptView(
      tone: tone,
      title: title,
      explanation: explanation,
      amount: formatNaira(p.amount),
      rows: rows,
      highlight: highlight,
      shareText: receiptText('${p.billerName} ${p.planName}'.trim(), formatNaira(p.amount), title, [
        ?highlight,
        ...rows,
      ]),
    );
  }

  String _doneText(BillPayment p) => switch (p.category) {
    BillCategory.airtime => 'Airtime sent to ${p.customer}.',
    BillCategory.data => 'Data sent to ${p.customer}.',
    BillCategory.electricity => 'Type this token into your meter to load your units.',
    BillCategory.tv => 'Your subscription is active. It can take a few minutes to show on your TV.',
    BillCategory.internet => 'Your ${p.billerName} plan is active.',
    BillCategory.education => 'Here is your PIN. Keep it safe; you need it on the ${p.billerName} website.',
    BillCategory.betting => 'Your ${p.billerName} wallet has been funded.',
  };
}
