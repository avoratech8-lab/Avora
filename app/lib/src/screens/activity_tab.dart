import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/transaction_tile.dart';
import 'insights_screen.dart';
import 'open_line.dart';
import 'shell_screen.dart';

enum _Filter { all, moneyIn, moneyOut }

/// Every statement line, grouped by day, with filters and search.
class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key, required this.shell});

  final ShellScreenState shell;

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  _Filter _filter = _Filter.all;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shell = widget.shell;
    final lines = shell.lines.where((l) {
      if (_filter == _Filter.moneyIn && l.amount <= 0) return false;
      if (_filter == _Filter.moneyOut && l.amount >= 0) return false;
      return _query.isEmpty || l.description.toLowerCase().contains(_query.toLowerCase());
    }).toList();

    final children = <Widget>[];
    String? day;
    for (final l in lines) {
      final d = dayLabel(l.at);
      if (d != day) {
        day = d;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text(d, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        );
      }
      children.add(TransactionTile(line: l, onTap: opener(context, l, shell.refresh)));
    }

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: shell.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text('Activity', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            _MonthCard(key: ValueKey('${shell.lines.length} ${shell.lines.firstOrNull?.ref}')),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(hintText: 'Search activity', prefixIcon: Icon(Icons.search_rounded)),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final (f, label) in [
                  (_Filter.all, 'All'),
                  (_Filter.moneyIn, 'Money in'),
                  (_Filter.moneyOut, 'Money out'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
              ],
            ),
            if (lines.isEmpty)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Text(
                    shell.lines.isEmpty ? 'No activity yet.' : 'Nothing matches.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              ...children,
          ],
        ),
      ),
    );
  }
}

/// This month's spending at a glance, opening the full insights.
class _MonthCard extends StatefulWidget {
  const _MonthCard({super.key});

  @override
  State<_MonthCard> createState() => _MonthCardState();
}

class _MonthCardState extends State<_MonthCard> {
  Insights? _i;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    AppScope.of(context).api.insights().then((i) {
      if (mounted) setState(() => _i = i);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = _i;
    final top = i?.categories.where((c) => c.amount > 0).take(3).toList() ?? const [];
    return Card(
      child: InkWell(
        key: const Key('insights-card'),
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const InsightsScreen()));
          if (!context.mounted) return;
          final fresh = await AppScope.of(context).api.insights();
          if (mounted) setState(() => _i = fresh);
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.insights_rounded, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      i == null ? 'This month' : 'Spent in ${formatMonth(i.month).split(' ').first}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Text('Insights', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                  Icon(Icons.chevron_right_rounded, size: 18, color: theme.colorScheme.primary),
                ],
              ),
              const SizedBox(height: 6),
              Text(i == null ? '…' : formatNaira(i.moneyOut), style: theme.textTheme.headlineSmall),
              if (i != null && i.budget > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (i.moneyOut / i.budget).clamp(0, 1).toDouble(),
                    minHeight: 6,
                    color: i.moneyOut >= i.budget
                        ? Brand.danger
                        : i.moneyOut * 10 >= i.budget * 8
                        ? Brand.warning
                        : Brand.green,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'of ${formatNaira(i.budget)} budget',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (top.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    for (final c in top)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 8, color: categoryLook(c.category).$3),
                          const SizedBox(width: 4),
                          Text(
                            '${categoryLook(c.category).$1} ${formatNaira(c.amount).replaceAll('.00', '')}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
