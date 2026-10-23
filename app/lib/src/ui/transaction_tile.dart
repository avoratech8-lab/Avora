import 'package:flutter/material.dart';

import '../api/models.dart';
import '../dates.dart';
import '../money.dart';
import 'theme.dart';

/// One line of activity: what it was, when, and how much.
class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.line, this.onTap});

  final StatementLine line;
  final VoidCallback? onTap;

  static (IconData, Color) look(StatementLine line, ColorScheme scheme) => switch (line.kind) {
    'inbound_credit' => (Icons.south_west_rounded, Brand.green),
    'referral_reward' => (Icons.card_giftcard_rounded, Brand.green),
    'p2p_in' => (Icons.bolt_rounded, Brand.green),
    'p2p_out' => (Icons.bolt_rounded, Brand.deepGreen),
    'transfer_refund' || 'bill_refund' => (Icons.replay_rounded, Brand.warning),
    'bill_payment' => (_billIcon(line.description), const Color(0xFF2563EB)),
    _ => (Icons.north_east_rounded, scheme.onSurfaceVariant),
  };

  static IconData _billIcon(String d) {
    final s = d.toLowerCase();
    if (s.contains('airtime')) return Icons.phone_android_rounded;
    if (s.contains('data')) return Icons.wifi_rounded;
    if (s.contains('electric') || s.contains('meter')) return Icons.bolt_rounded;
    if (RegExp(r'dstv|gotv|startimes|\btv\b').hasMatch(s)) return Icons.tv_rounded;
    return Icons.receipt_long_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = look(line, theme.colorScheme);
    final incoming = line.amount > 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${dayLabel(line.at)} · ${formatTime(line.at)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${incoming ? '+' : '−'}${formatNaira(line.amount.abs())}',
              style: theme.textTheme.titleSmall?.copyWith(color: incoming ? Brand.green : theme.colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
