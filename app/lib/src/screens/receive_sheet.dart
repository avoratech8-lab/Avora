import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../money.dart';
import '../pay_code.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'send_screen.dart';

/// Account details and a QR code for adding money from any bank app, or
/// being paid by another Avora customer.
void showReceiveSheet(BuildContext context, String accountNumber) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final details = 'Bank: TAJBank\nAccount number: $accountNumber\nName: My Avora account';
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add money', style: theme.textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                'Transfer from any bank app to this account, or let an Avora user scan your code.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Center(
                child: PayQr(
                  code: PayCode(bankCode: PayCode.partnerBank, accountNumber: accountNumber),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    const DetailRow(label: 'Bank', value: 'TAJBank'),
                    DetailRow(
                      label: 'Account number',
                      value: accountNumber,
                      bold: true,
                      trailing: InkWell(
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: accountNumber));
                          if (sheet.mounted) showMessage(sheet, 'Account number copied');
                        },
                        child: Icon(Icons.copy_rounded, size: 18, color: theme.colorScheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Transfers of ₦10,000 or more carry the government ₦50 stamp duty (EMTL).',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('request-money'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: () {
                        Navigator.pop(sheet);
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => RequestMoneyScreen(accountNumber: accountNumber)),
                        );
                      },
                      icon: const Icon(Icons.request_page_outlined),
                      label: const Text('Request'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Share',
                      onPressed: () => SharePlus.instance.share(ShareParams(text: details)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A QR code another Avora user can scan to pay.
class PayQr extends StatelessWidget {
  const PayQr({super.key, required this.code, this.size = 200});

  final PayCode code;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('pay-qr'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Brand.green.withValues(alpha: 0.25), width: 2),
      ),
      child: QrImageView(
        data: code.encode(),
        size: size,
        padding: EdgeInsets.zero,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Brand.deepGreen),
        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Brand.deepGreen),
      ),
    );
  }
}

/// Ask someone for an exact amount: a QR code to scan, or a message to send.
class RequestMoneyScreen extends StatefulWidget {
  const RequestMoneyScreen({super.key, required this.accountNumber});

  final String accountNumber;

  @override
  State<RequestMoneyScreen> createState() => _RequestMoneyScreenState();
}

class _RequestMoneyScreenState extends State<RequestMoneyScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  PayCode get _code => PayCode(
    bankCode: PayCode.partnerBank,
    accountNumber: widget.accountNumber,
    amount: parseNaira(_amount.text.replaceAll(',', '')) ?? 0,
    note: _note.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;
    return Scaffold(
      appBar: AppBar(title: const Text('Request money')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            TextField(
              key: const Key('request-amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
              style: theme.textTheme.headlineSmall,
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '₦ '),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('request-note'),
              controller: _note,
              maxLength: 60,
              decoration: const InputDecoration(labelText: "What's it for? (optional)", counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            Center(child: PayQr(code: code, size: 220)),
            const SizedBox(height: 12),
            Text(
              code.amount > 0
                  ? 'Scan with Avora to pay ${formatNaira(code.amount)}${code.note.isEmpty ? '' : ' for ${code.note}'}'
                  : 'Add an amount, or share this code to be paid any amount',
              key: const Key('request-caption'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            PrimaryButton(
              key: const Key('request-share'),
              label: 'Send request',
              onPressed: () => SharePlus.instance.share(ShareParams(text: code.requestText())),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scan an Avora QR code (or any QR holding an account number) to pay.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;
  String? _hint;

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final code = PayCode.parse(b.rawValue ?? '');
      if (code == null) continue;
      _done = true;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => SendScreen(payCode: code)));
      return;
    }
    if (capture.barcodes.isNotEmpty) setState(() => _hint = "That isn't a payment code. Try an Avora QR code.");
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Scan to pay'), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _detected,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'We need the camera to scan. Allow camera access for Avora in your phone settings.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Brand.lime, width: 3),
                borderRadius: BorderRadius.circular(28),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Column(
              children: [
                Text(
                  _hint ?? 'Point your camera at an Avora QR code',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context)
                          .pushReplacement(MaterialPageRoute<void>(builder: (_) => const SendScreen())),
                  child: const Text('Type an account number instead', style: TextStyle(color: Brand.lime)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
