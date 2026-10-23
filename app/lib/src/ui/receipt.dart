import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import 'theme.dart';
import 'widgets.dart';

enum ReceiptTone { pending, good, bad, warn }

/// A receipt page: status at the top, details on a card, share and done.
class ReceiptView extends StatelessWidget {
  const ReceiptView({
    super.key,
    required this.tone,
    required this.title,
    required this.explanation,
    required this.amount,
    required this.rows,
    required this.shareText,
    this.highlight,
    this.note,
  });

  final ReceiptTone tone;
  final String title;
  final String explanation;
  final String amount;
  final List<(String, String)> rows;
  final String shareText;
  final (String, String)? highlight; // e.g. an electricity token, shown big with copy
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (tone) {
      ReceiptTone.good => (Brand.green, Icons.check_rounded),
      ReceiptTone.bad => (Brand.warning, Icons.replay_rounded),
      ReceiptTone.warn => (Brand.warning, Icons.support_agent_rounded),
      ReceiptTone.pending => (theme.colorScheme.primary, Icons.schedule_rounded),
    };
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              children: [
                const SizedBox(height: 8),
                Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.6, end: 1),
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.elasticOut,
                    builder: (context, s, child) => Transform.scale(scale: s, child: child),
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                      child: tone == ReceiptTone.pending
                          ? Padding(
                              padding: const EdgeInsets.all(26),
                              child: CircularProgressIndicator(color: color, strokeWidth: 3),
                            )
                          : Icon(icon, color: color, size: 44),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  key: const Key('status-title'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  explanation,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                Text(amount, textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
                if (highlight != null) ...[
                  const SizedBox(height: 18),
                  _Highlight(label: highlight!.$1, value: highlight!.$2),
                ],
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    child: Column(
                      children: [for (final (l, v) in rows) DetailRow(label: l, value: v)],
                    ),
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    note!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('share'),
                    onPressed: () => SharePlus.instance.share(ShareParams(text: shareText, subject: 'Avora receipt')),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Share receipt'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('done'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Highlight extends StatelessWidget {
  const _Highlight({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Brand.lime.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(18)),
      child: Column(
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          SelectableText(
            value,
            key: const Key('highlight'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(letterSpacing: 1.2),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) showMessage(context, '$label copied');
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}

/// Plain-text receipt for sharing on WhatsApp, SMS or email.
String receiptText(String heading, String amount, String status, List<(String, String)> rows) =>
    ['Avora receipt', heading, 'Amount: $amount', 'Status: $status', for (final (l, v) in rows) '$l: $v'].join('\n');
