import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../ui/theme.dart';
import 'bill_receipt_screen.dart';
import 'insights_screen.dart';
import 'schedule_screens.dart';
import 'split_screens.dart';
import 'transfer_screen.dart';

/// The bell: money in, transfers, refunds, security and account news.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification>? _items;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null && _error == null) _load();
  }

  Future<void> _load() async {
    final api = AppScope.of(context).api;
    try {
      final (items, unread) = await api.notifications();
      if (!mounted) return;
      setState(() => _items = items);
      // Opening the list counts as reading it; the dots stay until next time.
      if (unread > 0) await api.markNotificationsRead();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static (IconData, Color) _look(String kind) => switch (kind) {
    'money_in' => (Icons.south_west_rounded, Brand.green),
    'transfer' => (Icons.north_east_rounded, const Color(0xFF2563EB)),
    'bill' => (Icons.replay_rounded, Brand.warning),
    'security' => (Icons.shield_outlined, Brand.danger),
    'budget' => (Icons.flag_outlined, Brand.warning),
    'split' => (Icons.call_split_rounded, const Color(0xFF9333EA)),
    'schedule' => (Icons.event_repeat_rounded, Brand.green),
    'card' => (Icons.credit_card_rounded, const Color(0xFF2563EB)),
    _ => (Icons.campaign_outlined, Brand.deepGreen),
  };

  VoidCallback? _open(AppNotification n) {
    final Widget? page = switch (n.kind) {
      'transfer' => TransferScreen(transferId: n.ref),
      'bill' => BillReceiptScreen(paymentId: n.ref),
      'budget' => const InsightsScreen(),
      'split' => SplitScreen(splitId: n.ref),
      'schedule' => const SchedulesScreen(),
      _ => null,
    };
    if (page == null || (n.ref.isEmpty && n.kind != 'budget' && n.kind != 'schedule')) return null;
    return () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: items == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : const Text("We couldn't load your notifications."),
            )
          : items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none_rounded, size: 56, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text("You're all caught up", style: theme.textTheme.titleMedium),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final n = items[i];
                final (icon, color) = _look(n.kind);
                return Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _open(n),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: color, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: Text(n.title, style: theme.textTheme.titleSmall)),
                                    if (!n.read)
                                      Container(
                                        key: Key('unread-${n.id}'),
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(color: Brand.green, shape: BoxShape.circle),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(n.body, style: theme.textTheme.bodyMedium),
                                const SizedBox(height: 6),
                                Text(
                                  formatWhen(n.createdAt),
                                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
