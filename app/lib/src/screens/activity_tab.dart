import 'package:flutter/material.dart';

import '../dates.dart';
import '../money.dart';
import '../ui/transaction_tile.dart';
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

    final moneyIn = shell.lines.where((l) => l.amount > 0).fold<int>(0, (a, l) => a + l.amount);
    final moneyOut = shell.lines.where((l) => l.amount < 0).fold<int>(0, (a, l) => a - l.amount);

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
            Row(
              children: [
                Expanded(
                  child: _Total(label: 'Money in', amount: moneyIn, icon: Icons.south_west_rounded),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Total(label: 'Money out', amount: moneyOut, icon: Icons.north_east_rounded),
                ),
              ],
            ),
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

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.amount, required this.icon});

  final String label;
  final int amount;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(formatNaira(amount), style: theme.textTheme.titleMedium),
            ),
          ],
        ),
      ),
    );
  }
}
