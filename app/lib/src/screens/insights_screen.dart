import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// How a spending category looks: its name, icon and colour.
(String, IconData, Color) categoryLook(String c) => switch (c) {
  'transfers' => ('Bank transfers', Icons.account_balance_outlined, const Color(0xFF2563EB)),
  'avora' => ('Avora transfers', Icons.bolt_rounded, Brand.green),
  'airtime' => ('Airtime', Icons.phone_android_rounded, const Color(0xFFE8A317)),
  'data' => ('Data', Icons.wifi_rounded, const Color(0xFF7C3AED)),
  'electricity' => ('Electricity', Icons.lightbulb_outline_rounded, const Color(0xFFF97316)),
  'tv' => ('TV', Icons.tv_rounded, const Color(0xFFDB2777)),
  'internet' => ('Internet', Icons.router_rounded, const Color(0xFF0891B2)),
  'education' => ('Exam PINs', Icons.school_rounded, const Color(0xFF4F46E5)),
  'betting' => ('Betting', Icons.sports_soccer_rounded, const Color(0xFFD64545)),
  allSpending => ('All spending', Icons.pie_chart_outline_rounded, Brand.green),
  _ => ('Other', Icons.more_horiz_rounded, const Color(0xFF64748B)),
};

String _short(int kobo) => formatNaira(kobo).replaceAll('.00', '');

/// Where the money went this month, against last month and any budgets.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  late DateTime _month;
  Insights? _i;
  Object? _error;
  int _load = 0;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _month = DateTime(n.year, n.month);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_i == null && _error == null) _fetch();
  }

  bool get _thisMonth {
    final n = DateTime.now();
    return _month.year == n.year && _month.month == n.month;
  }

  Future<void> _fetch() async {
    final id = ++_load;
    try {
      final i = await AppScope.of(context).api.insights(month: _thisMonth ? null : _month);
      if (mounted && id == _load) setState(() => _i = i);
    } catch (e) {
      if (mounted && id == _load) setState(() => _error = e);
    }
  }

  void _go(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _i = null;
      _error = null;
    });
    _fetch();
  }

  Future<void> _editBudget(String category) async {
    final i = _i;
    if (i == null) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BudgetSheet(category: category, current: i.budgetFor(category)),
    );
    if (saved == true) _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = _i;
    return Scaffold(
      appBar: AppBar(title: const Text('Spending')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _fetch,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('month-prev'),
                    tooltip: 'Previous month',
                    onPressed: () => _go(-1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Expanded(
                    child: Text(
                      formatMonth(_month),
                      key: const Key('month'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const Key('month-next'),
                    tooltip: 'Next month',
                    onPressed: _thisMonth ? null : () => _go(1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (i == null)
                Padding(
                  padding: const EdgeInsets.all(48),
                  child: Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : Text(_error is ApiException ? (_error as ApiException).message : "We couldn't load this."),
                  ),
                )
              else ...[
                _Summary(i: i, thisMonth: _thisMonth, onBudget: () => _editBudget(allSpending)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _Stat(label: 'Money in', value: _short(i.moneyIn), icon: Icons.south_west_rounded),
                    const SizedBox(width: 10),
                    _Stat(label: 'Saved', value: _short(i.saved), icon: Icons.savings_outlined),
                    const SizedBox(width: 10),
                    _Stat(label: 'Cashback', value: _short(i.cashback), icon: Icons.redeem_rounded),
                  ],
                ),
                const SizedBox(height: 24),
                Text('Day by day', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                SizedBox(
                  height: 120,
                  child: _DayBars(days: i.days, today: _thisMonth ? DateTime.now().day : null),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: Text('Where it went', style: theme.textTheme.titleMedium)),
                    TextButton.icon(
                      key: const Key('add-budget'),
                      onPressed: () => _pickCategory(i),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Budget'),
                    ),
                  ],
                ),
                if (i.moneyOut > 0) ...[const SizedBox(height: 4), _Split(categories: i.categories, total: i.moneyOut)],
                const SizedBox(height: 8),
                if (i.moneyOut == 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Nothing spent in ${formatMonth(_month)}.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                for (final c in i.categories)
                  _CategoryRow(c: c, total: i.moneyOut, onTap: () => _editBudget(c.category)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickCategory(Insights i) async {
    final c = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in [allSpending, ...spendCategories.where((c) => c != 'other')])
                ListTile(
                  key: Key('pick-$c'),
                  leading: Icon(categoryLook(c).$2, color: categoryLook(c).$3),
                  title: Text(categoryLook(c).$1),
                  trailing: i.budgetFor(c) > 0 ? Text(_short(i.budgetFor(c))) : null,
                  onTap: () => Navigator.pop(sheet, c),
                ),
            ],
          ),
        ),
      ),
    );
    if (c != null) await _editBudget(c);
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.i, required this.thisMonth, required this.onBudget});

  final Insights i;
  final bool thisMonth;
  final VoidCallback onBudget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final white70 = Colors.white.withValues(alpha: 0.78);
    final diff = i.moneyOut - i.previousOut;
    final compare = i.previousOut == 0
        ? null
        : diff == 0
        ? 'Same as last month'
        : '${_short(diff.abs())} ${diff < 0 ? 'less' : 'more'} than last month';
    final left = i.budget - i.moneyOut;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(thisMonth ? 'Spent this month' : 'Spent', style: theme.textTheme.bodyMedium?.copyWith(color: white70)),
          const SizedBox(height: 4),
          Text(
            formatNaira(i.moneyOut),
            key: const Key('spent'),
            style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white),
          ),
          if (compare != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  diff <= 0 ? Icons.trending_down_rounded : Icons.trending_up_rounded,
                  color: diff <= 0 ? Brand.lime : const Color(0xFFFFC9A8),
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(compare, style: theme.textTheme.bodySmall?.copyWith(color: white70)),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (i.budget > 0) ...[
            _Meter(spent: i.moneyOut, budget: i.budget, onDark: true),
            const SizedBox(height: 8),
            InkWell(
              key: const Key('budget-all'),
              onTap: onBudget,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Budget ${_short(i.budget)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: white70),
                    ),
                  ),
                  Text(
                    left >= 0 ? '${_short(left)} left' : '${_short(-left)} over',
                    key: const Key('budget-left'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: left >= 0 ? Brand.lime : const Color(0xFFFFC9A8),
                    ),
                  ),
                ],
              ),
            ),
          ] else
            OutlinedButton.icon(
              key: const Key('budget-all'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.4)),
              ),
              onPressed: onBudget,
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: const Text('Set a monthly budget'),
            ),
        ],
      ),
    );
  }
}

/// A budget bar: green, amber from 80%, red past 100%.
class _Meter extends StatelessWidget {
  const _Meter({required this.spent, required this.budget, this.onDark = false});

  final int spent;
  final int budget;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final share = spent / budget;
    final color = share >= 1
        ? Brand.danger
        : share >= 0.8
        ? Brand.warning
        : (onDark ? Brand.lime : Brand.green);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LinearProgressIndicator(
        value: share.clamp(0, 1).toDouble(),
        minHeight: 8,
        color: color,
        backgroundColor: onDark
            ? Colors.white.withValues(alpha: 0.18)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(height: 6),
            FittedBox(child: Text(value, style: theme.textTheme.titleSmall)),
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Spending per day as bars; today's is highlighted.
class _DayBars extends StatelessWidget {
  const _DayBars({required this.days, this.today});

  final List<int> days;
  final int? today;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Spending by day',
      child: CustomPaint(
        size: Size.infinite,
        painter: _BarsPainter(days: days, today: today, bar: scheme.primary, faint: scheme.surfaceContainerHighest),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.days, required this.today, required this.bar, required this.faint});

  final List<int> days;
  final int? today;
  final Color bar;
  final Color faint;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final top = days.reduce((a, b) => a > b ? a : b);
    final slot = size.width / days.length;
    final w = slot * 0.62;
    for (var d = 0; d < days.length; d++) {
      final future = today != null && d + 1 > today!;
      final h = top == 0 ? 0.0 : (days[d] / top) * (size.height - 4);
      final x = d * slot + (slot - w) / 2;
      final paint = Paint()
        ..color = future
            ? faint.withValues(alpha: 0.5)
            : d + 1 == today
            ? Brand.lime
            : days[d] == 0
            ? faint
            : bar;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h.clamp(3, size.height), w, h.clamp(3, size.height)),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.days != days || old.today != today || old.bar != bar;
}

/// One bar split by category, as a quick picture of where it went.
class _Split extends StatelessWidget {
  const _Split({required this.categories, required this.total});

  final List<SpendCategory> categories;
  final int total;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 14,
        child: Row(
          children: [
            for (final c in categories.where((c) => c.amount > 0))
              Expanded(
                flex: (c.amount * 1000 ~/ total).clamp(1, 1000),
                child: Container(margin: const EdgeInsets.only(right: 2), color: categoryLook(c.category).$3),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.c, required this.total, required this.onTap});

  final SpendCategory c;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (name, icon, color) = categoryLook(c.category);
    final share = total == 0 ? 0 : (c.amount * 100 / total).round();
    final sub = [
      if (c.count > 0) '${c.count} payment${c.count == 1 ? '' : 's'}',
      if (c.amount > 0) '$share%',
      if (c.budget > 0) 'budget ${_short(c.budget)}',
    ].join(' · ');
    return InkWell(
      key: Key('cat-${c.category}'),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: theme.textTheme.titleSmall),
                      if (sub.isNotEmpty)
                        Text(
                          sub,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                Text(formatNaira(c.amount), style: theme.textTheme.titleSmall),
              ],
            ),
            if (c.budget > 0) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: _Meter(spent: c.amount, budget: c.budget),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BudgetSheet extends StatefulWidget {
  const _BudgetSheet({required this.category, required this.current});

  final String category;
  final int current;

  @override
  State<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<_BudgetSheet> {
  late final _amount = TextEditingController(text: widget.current == 0 ? '' : (widget.current ~/ 100).toString());
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save(int amount) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).api.setBudget(widget.category, amount);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ApiException ? e.message : 'Something went wrong. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (name, icon, color) = categoryLook(widget.category);
    final amount = parseNaira(_amount.text);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text('$name budget', style: theme.textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "We'll let you know at 80% and when you reach it. It starts again on the 1st of each month.",
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('budget-amount'),
              controller: _amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: theme.textTheme.headlineSmall,
              decoration: InputDecoration(prefixText: '₦ ', hintText: '0', labelText: 'Per month', errorText: _error),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              key: const Key('budget-save'),
              label: 'Save budget',
              loading: _busy,
              onPressed: amount == null ? null : () => _save(amount),
            ),
            if (widget.current > 0)
              Center(
                child: TextButton(
                  key: const Key('budget-remove'),
                  onPressed: _busy ? null : () => _save(0),
                  child: const Text('Remove budget'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
