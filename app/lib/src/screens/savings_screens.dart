import 'package:flutter/material.dart';

import '../api/api.dart';
import '../api/demo_api.dart';
import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../ids.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'shell_screen.dart';

String percent(int bps) => '${(bps / 100).toStringAsFixed(bps % 100 == 0 ? 0 : 1)}%';

String termLabel(int days) => switch (days) {
  30 => '1 month',
  90 => '3 months',
  180 => '6 months',
  365 => '1 year',
  _ => '$days days',
};

const _disclosure =
    'Avora savings follow non-interest banking. Your money is invested by our partner bank and you get a share of '
    'the actual profit each month. Expected rates are a guide, not a promise.';

/// Savings tab: totals, the two products, and every pot.
class SavingsTab extends StatefulWidget {
  const SavingsTab({super.key, required this.shell});

  final ShellScreenState shell;

  @override
  State<SavingsTab> createState() => SavingsTabState();
}

class SavingsTabState extends State<SavingsTab> {
  List<SavingsPot>? _pots;
  SavingsRates? _rates;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pots == null && _error == null) refresh();
  }

  Future<void> refresh() async {
    try {
      final (pots, rates) = await AppScope.of(context).api.savings();
      if (!mounted) return;
      setState(() {
        _pots = pots;
        _rates = rates;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await Future.wait([refresh(), widget.shell.refresh()]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pots = _pots;
    final rates = _rates;
    final open = pots?.where((p) => p.open).toList() ?? const [];
    final closed = pots?.where((p) => !p.open).toList() ?? const [];
    final total = open.fold<int>(0, (a, p) => a + p.balance);
    final profit = (pots ?? const []).fold<int>(0, (a, p) => a + p.profitEarned);
    final api = AppScope.of(context).api;
    final topRate = rates == null ? 0 : rates.terms.map((t) => t.rateBps).fold(0, (a, b) => a > b ? a : b);

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text('Savings', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Total saved',
                          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Brand.lime, borderRadius: BorderRadius.circular(20)),
                        child: Text(
                          'Interest-free',
                          style: theme.textTheme.labelSmall?.copyWith(color: Brand.deepGreen),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatNaira(total),
                    key: const Key('savings-total'),
                    style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Profit share earned: ${formatNaira(profit)}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: Brand.lime),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (pots == null)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : TextButton(onPressed: refresh, child: const Text("Couldn't load savings. Try again")),
                ),
              )
            else ...[
              Text('Start saving', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _ProductCard(
                      key: const Key('new-goal'),
                      icon: Icons.flag_rounded,
                      title: 'Goal',
                      body: 'Save toward something. Add or take out any time.',
                      rate: 'About ${percent(rates!.goalBps)} a year',
                      onTap: () => _open(NewPotScreen(kind: PotKind.goal, rates: rates)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ProductCard(
                      key: const Key('new-locked'),
                      icon: Icons.lock_rounded,
                      title: 'Locked',
                      body: 'Lock money away for 1 to 12 months and earn more.',
                      rate: 'Up to ${percent(topRate)} a year',
                      onTap: () => _open(NewPotScreen(kind: PotKind.locked, rates: rates)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (open.isNotEmpty) ...[
                Text('Your pots', style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                for (final p in open)
                  _PotTile(
                    pot: p,
                    onTap: () => _open(PotScreen(pot: p)),
                  ),
              ],
              if (closed.isNotEmpty) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Closed (${closed.length})', style: theme.textTheme.titleSmall),
                  children: [
                    for (final p in closed)
                      _PotTile(
                        pot: p,
                        onTap: () => _open(PotScreen(pot: p)),
                      ),
                  ],
                ),
              ],
              if (api is DemoAvoraApi && open.isNotEmpty)
                TextButton.icon(
                  key: const Key('demo-profit'),
                  onPressed: () async {
                    api.shareDemoProfit();
                    await refresh();
                    if (context.mounted) showMessage(context, "Demo: this month's profit share was added");
                  },
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Demo: share a month of profit'),
                ),
              const SizedBox(height: 16),
              Text(_disclosure, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.rate,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final String rate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 22),
              ),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(body, style: theme.textTheme.bodySmall, maxLines: 3),
              const SizedBox(height: 10),
              Text(rate, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PotTile extends StatelessWidget {
  const _PotTile({required this.pot, required this.onTap});

  final SavingsPot pot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = pot;
    final sub = !p.open
        ? 'Closed'
        : p.kind == PotKind.locked
        ? (p.isMatured(DateTime.now()) ? 'Ready to withdraw' : 'Locked until ${formatDate(p.maturesAt!)}')
        : p.target > 0
        ? '${(p.progress * 100).round()}% of ${formatNaira(p.target)}'
        : 'Flexible';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: (p.kind == PotKind.locked ? Brand.warning : theme.colorScheme.primary).withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        p.kind == PotKind.locked ? Icons.lock_rounded : Icons.flag_rounded,
                        color: p.kind == PotKind.locked ? Brand.warning : theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name, style: theme.textTheme.titleSmall),
                          Text(sub, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    Text(formatNaira(p.balance), style: theme.textTheme.titleSmall),
                  ],
                ),
                if (p.open && p.kind == PotKind.goal && p.target > 0) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(value: p.progress, minHeight: 8),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Open a goal or a locked plan.
class NewPotScreen extends StatefulWidget {
  const NewPotScreen({super.key, required this.kind, required this.rates});

  final PotKind kind;
  final SavingsRates rates;

  @override
  State<NewPotScreen> createState() => _NewPotScreenState();
}

class _NewPotScreenState extends State<NewPotScreen> {
  final _name = TextEditingController();
  final _target = TextEditingController();
  final _amount = TextEditingController();
  final _key = randomId();
  late int _days = widget.rates.terms.length > 1 ? widget.rates.terms[1].days : widget.rates.terms.first.days;
  bool _busy = false;

  bool get _locked => widget.kind == PotKind.locked;

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _amount.dispose();
    super.dispose();
  }

  int get _rate => _locked ? widget.rates.terms.firstWhere((t) => t.days == _days).rateBps : widget.rates.goalBps;

  int get _amountKobo => parseNaira(_amount.text) ?? 0;

  bool get _ready => _name.text.trim().isNotEmpty && (!_locked || _amountKobo >= 100000);

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      await AppScope.of(context).api.createPot(
        kind: widget.kind,
        name: _name.text.trim(),
        target: _locked ? 0 : (parseNaira(_target.text) ?? 0),
        lockDays: _locked ? _days : 0,
        amount: _amountKobo,
        idempotencyKey: _key,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showMessage(context, _locked ? 'Your plan is locked in' : 'Your goal is ready');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = _locked ? _days : 365;
    final est = expectedProfit(_amountKobo, _rate, days);
    const ideas = ['Rent', 'School fees', 'Emergency fund', 'New phone', 'Travel', 'Business'];
    return Scaffold(
      appBar: AppBar(title: Text(_locked ? 'New locked plan' : 'New goal')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  Text('Name', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('pot-name'),
                    controller: _name,
                    maxLength: 40,
                    decoration: const InputDecoration(hintText: 'What are you saving for?', counterText: ''),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final i in ideas)
                        ActionChip(label: Text(i), onPressed: () => setState(() => _name.text = i)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (_locked) ...[
                    Text('Lock for', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in widget.rates.terms)
                          ChoiceChip(
                            key: Key('term-${t.days}'),
                            label: Text('${termLabel(t.days)} · ${percent(t.rateBps)}'),
                            selected: _days == t.days,
                            onSelected: (_) => setState(() => _days = t.days),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ] else ...[
                    Text('Target (optional)', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('pot-target'),
                      controller: _target,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(prefixText: '₦ ', hintText: '0'),
                    ),
                    const SizedBox(height: 20),
                  ],
                  Text(_locked ? 'Amount to lock' : 'Start with (optional)', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('pot-amount'),
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      prefixText: '₦ ',
                      hintText: '0',
                      helperText: _locked ? 'Minimum ₦1,000. It moves from your wallet now.' : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        DetailRow(label: 'Expected profit rate', value: '${percent(_rate)} a year'),
                        if (_locked) ...[
                          DetailRow(
                            label: 'Unlocks on',
                            value: formatDate(DateTime.now().add(Duration(days: _days))),
                          ),
                          DetailRow(label: 'Expected profit share', value: formatNaira(est), bold: true),
                        ] else
                          DetailRow(label: 'Expected over a year', value: formatNaira(est), bold: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _locked
                        ? 'You can break the plan early and get your money back, but you give back its profit share. '
                              '$_disclosure'
                        : _disclosure,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                key: const Key('pot-create'),
                label: _locked ? 'Lock ${formatNaira(_amountKobo)}' : 'Create goal',
                loading: _busy,
                onPressed: _ready ? _create : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One pot: balance, progress, profit, and moving money in and out.
class PotScreen extends StatefulWidget {
  const PotScreen({super.key, required this.pot});

  final SavingsPot pot;

  @override
  State<PotScreen> createState() => _PotScreenState();
}

class _PotScreenState extends State<PotScreen> {
  late SavingsPot _p = widget.pot;

  AvoraApi get _api => AppScope.of(context).api;

  Future<void> _move({required bool into}) async {
    final amount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _AmountSheet(title: into ? 'Add to ${_p.name}' : 'Take out of ${_p.name}', max: into ? null : _p.balance),
    );
    if (amount == null || !mounted) return;
    try {
      final key = randomId();
      final p = into
          ? await _api.depositToPot(_p.id, amount, idempotencyKey: key)
          : await _api.withdrawFromPot(_p.id, amount: amount, idempotencyKey: key);
      if (!mounted) return;
      setState(() => _p = p);
      showMessage(context, into ? '${formatNaira(amount)} saved' : '${formatNaira(amount)} moved to your wallet');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _withdrawLocked() async {
    final early = !_p.isMatured(DateTime.now());
    if (early) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Break this plan?'),
          content: Text(
            'You get ${formatNaira(_p.balance - _p.profitEarned)} back now. '
            'The profit share of ${formatNaira(_p.profitEarned)} goes back to the pool. '
            'If you wait until ${formatDate(_p.maturesAt!)}, you keep it all.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep saving')),
            TextButton(
              key: const Key('confirm-break'),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Break plan'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      final p = await _api.withdrawFromPot(_p.id, breakEarly: early, idempotencyKey: randomId());
      if (!mounted) return;
      setState(() => _p = p);
      showMessage(context, 'Moved to your wallet');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _p;
    final locked = p.kind == PotKind.locked;
    final matured = p.isMatured(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(locked ? Icons.lock_rounded : Icons.flag_rounded, color: Brand.lime, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        locked ? 'Locked plan · ${termLabel(p.lockDays)}' : 'Goal',
                        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatNaira(p.balance),
                    key: const Key('pot-balance'),
                    style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white),
                  ),
                  if (!locked && p.target > 0) ...[
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: p.progress,
                        minHeight: 10,
                        color: Brand.lime,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(p.progress * 100).round()}% of ${formatNaira(p.target)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Column(
                  children: [
                    DetailRow(label: 'Profit share earned', value: formatNaira(p.profitEarned)),
                    DetailRow(label: 'Expected rate', value: '${percent(p.expectedRateBps)} a year'),
                    if (locked) DetailRow(label: 'Unlocks on', value: formatDate(p.maturesAt!)),
                    DetailRow(label: 'Started', value: formatDate(p.createdAt)),
                    DetailRow(label: 'Status', value: p.open ? 'Open' : 'Closed'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (p.open && !locked)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('pot-withdraw'),
                      onPressed: p.balance > 0 ? () => _move(into: false) : null,
                      child: const Text('Take out'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('pot-add'),
                      onPressed: () => _move(into: true),
                      child: const Text('Add money'),
                    ),
                  ),
                ],
              ),
            if (p.open && locked)
              matured
                  ? PrimaryButton(
                      key: const Key('pot-collect'),
                      label: 'Move ${formatNaira(p.balance)} to wallet',
                      onPressed: _withdrawLocked,
                    )
                  : OutlinedButton(
                      key: const Key('pot-break'),
                      style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: _withdrawLocked,
                      child: const Text('Break plan early'),
                    ),
            const SizedBox(height: 16),
            Text(_disclosure, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _AmountSheet extends StatefulWidget {
  const _AmountSheet({required this.title, this.max});

  final String title;
  final int? max;

  @override
  State<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<_AmountSheet> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = parseNaira(_c.text);
    final over = widget.max != null && amount != null && amount > widget.max!;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            key: const Key('move-amount'),
            controller: _c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: theme.textTheme.titleLarge,
            decoration: InputDecoration(
              prefixText: '₦ ',
              hintText: '0',
              errorText: over ? 'This pot holds ${formatNaira(widget.max!)}' : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (widget.max != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _c.text = (widget.max! / 100).toStringAsFixed(2)),
                child: Text('All of it (${formatNaira(widget.max!)})'),
              ),
            ),
          const SizedBox(height: 12),
          PrimaryButton(
            key: const Key('move-confirm'),
            label: 'Continue',
            onPressed: amount == null || over ? null : () => Navigator.pop(context, amount),
          ),
        ],
      ),
    );
  }
}
