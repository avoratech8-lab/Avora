import 'package:flutter/material.dart';

import '../api/models.dart';
import 'bill_receipt_screen.dart';
import 'transfer_screen.dart';

/// Opens the receipt behind a statement line, if it has one.
VoidCallback? opener(BuildContext context, StatementLine line, Future<void> Function() refresh) {
  if (line.ref.isEmpty) return null;
  Widget? page;
  if (line.isTransfer) page = TransferScreen(transferId: line.ref);
  if (line.kind.startsWith('bill_')) page = BillReceiptScreen(paymentId: line.ref);
  if (page == null) return null;
  final p = page;
  return () async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => p));
    await refresh();
  };
}
