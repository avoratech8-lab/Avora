import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../ui/widgets.dart';

/// Account details for adding money from any Nigerian bank app.
void showReceiveSheet(BuildContext context, String accountNumber) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final details = 'Bank: TAJBank\nAccount number: $accountNumber\nName: My Avora account';
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add money', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Transfer from any bank app to this account. It lands in seconds.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(18),
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
            const SizedBox(height: 12),
            Text(
              'Transfers of ₦10,000 or more carry the government ₦50 stamp duty (EMTL).',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              label: 'Share account details',
              onPressed: () => SharePlus.instance.share(ShareParams(text: details)),
            ),
          ],
        ),
      );
    },
  );
}
