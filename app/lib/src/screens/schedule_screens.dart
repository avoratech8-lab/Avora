import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'security_screens.dart';

String _short(int kobo) => formatNaira(kobo).replaceAll('.00', '');

IconData scheduleIcon(ScheduleKind k) => switch (k) {
  ScheduleKind.avora => Icons.bolt_rounded,
  ScheduleKind.transfer => Icons.account_balance_outlined,
  ScheduleKind.bill => Icons.receipt_long_rounded,
  ScheduleKind.savings => Icons.savings_outlined,
};

/// Who a schedule pays, in a few words.
String schedulePayee(Schedule s) {
  final t = s.target;
  return switch (s.kind) {
    ScheduleKind.avora => '${t.accountName} · ${t.to}',
    ScheduleKind.transfer =>
      '${t.accountName} · ${banks.where((b) => b.code == t.bankCode).firstOrNull?.name ?? t.bankCode} ${t.accountNumber}',
    ScheduleKind.bill => t.accountName.isEmpty ? t.customer : '${t.accountName} · ${t.customer}',
    ScheduleKind.savings => 'Into ${t.accountName}',
  };
}

String _billerName(Biller b) => switch (b.category) {
  BillCategory.airtime => '${b.name} airtime',
  BillCategory.data => '${b.name} data',
  _ => b.name,
};

/// Payments that run on their own: rent, school fees, data or savings.
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key});

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  ScheduleList? _list;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_list == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final list = await AppScope.of(context).api.schedules();
      if (mounted) {
        setState(() {
          _list = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _new() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const NewScheduleScreen()));
    if (made == true) {
      await _load();
      if (mounted) showMessage(context, 'Scheduled. We\'ll tell you each time it pays.');
    }
  }

  Future<void> _act(Future<void> Function(AvoraApi api) f, [String? done]) async {
    try {
      await f(AppScope.of(context).api);
      await _load();
      if (mounted && done != null) showMessage(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _open(Schedule s) async {
    final sandbox = _list?.sandbox ?? false;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ScheduleSheet(schedule: s, sandbox: sandbox),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'run':
        await _act((api) async {
          final r = await api.runScheduleNow(s.id);
          if (mounted) showMessage(context, r.lastOk == true ? 'Paid ${_short(r.amount)}' : r.lastMessage);
        });
      case 'pause':
        await _act((api) => api.pauseSchedule(s.id, true), 'Paused');
      case 'resume':
        await _act((api) => api.pauseSchedule(s.id, false), 'Resumed');
      case 'delete':
        final sure = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('Delete ${s.name}?'),
            content: const Text('It won\'t pay again. Payments already made stay as they are.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
              TextButton(
                key: const Key('schedule-delete-yes'),
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (sure == true) await _act((api) => api.cancelSchedule(s.id), 'Deleted');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    final upcoming = list?.schedules.where((s) => s.active).toList() ?? const <Schedule>[];
    final now = DateTime.now();
    // What the active schedules will pay from now to the end of the month.
    var thisMonth = 0;
    for (final s in upcoming) {
      for (var i = 0; ; i++) {
        final d = s.frequency.at(s.nextRun, i);
        if (d.year != now.year || d.month != now.month) break;
        thisMonth += s.amount;
        if (s.frequency == Frequency.once) break;
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled payments')),
      floatingActionButton: list == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('schedule-new'),
              onPressed: _new,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New'),
            ),
      body: SafeArea(
        child: list == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error is ApiException ? (_error as ApiException).message : 'Something went wrong.'),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () {
                              setState(() => _error = null);
                              _load();
                            },
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Going out this month',
                                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  formatNaira(thisMonth),
                                  key: const Key('schedule-month-total'),
                                  style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${upcoming.length} active · free, and under your daily limit',
                                  style: theme.textTheme.bodySmall?.copyWith(color: Brand.lime),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.event_repeat_rounded, color: Brand.lime, size: 40),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (list.schedules.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          children: [
                            Icon(Icons.event_available_rounded, size: 48, color: theme.colorScheme.primary),
                            const SizedBox(height: 12),
                            Text('Set it once, never forget', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text(
                              'Rent, school fees, a monthly data plan or a weekly save. Avora pays on the day and '
                              'tells you it\'s done.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    for (final s in list.schedules) _ScheduleTile(schedule: s, onTap: () => _open(s)),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.schedule, required this.onTap});

  final Schedule schedule;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = schedule;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final (chip, chipColor) = switch (s.status) {
      ScheduleStatus.paused => ('Paused', Brand.warning),
      ScheduleStatus.done => ('Finished', theme.colorScheme.onSurfaceVariant),
      _ => (s.frequency.label, Brand.green),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: Key('schedule-${s.name}'),
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: Brand.green.withValues(alpha: s.done ? 0.06 : 0.12),
                      child: Icon(scheduleIcon(s.kind), color: Brand.green, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                          Text(schedulePayee(s), style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_short(s.amount), style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: chipColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            chip,
                            style: theme.textTheme.labelSmall?.copyWith(color: chipColor, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.active
                            ? 'Next: ${dayLabel(s.nextRun)}'
                            : (s.paused ? 'Paused · won\'t pay until you resume' : 'Done'),
                        style: muted,
                      ),
                    ),
                  ],
                ),
                if (s.lastOk != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        s.lastOk! ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                        size: 15,
                        color: s.lastOk! ? Brand.green : Brand.danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          s.lastOk!
                              ? 'Paid ${formatWhen(s.lastRunAt!)}'
                              : 'Didn\'t pay ${formatWhen(s.lastRunAt!)}: ${s.lastMessage}',
                          style: muted?.copyWith(color: s.lastOk! ? null : Brand.danger),
                        ),
                      ),
                    ],
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

class _ScheduleSheet extends StatelessWidget {
  const _ScheduleSheet({required this.schedule, required this.sandbox});

  final Schedule schedule;
  final bool sandbox;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = schedule;
    Widget action(String key, IconData icon, String label, {Color? color}) => ListTile(
      key: Key('schedule-$key'),
      leading: Icon(icon, color: color),
      title: Text(label, style: color == null ? null : TextStyle(color: color)),
      onTap: () => Navigator.pop(context, key),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            DetailRow(label: 'Amount', value: formatNaira(s.amount)),
            DetailRow(label: 'To', value: schedulePayee(s)),
            DetailRow(label: 'How often', value: s.frequency.label),
            DetailRow(label: 'Started', value: formatDate(s.startsAt)),
            if (s.active) DetailRow(label: 'Next', value: formatDate(s.nextRun)),
            DetailRow(label: 'Paid so far', value: '${s.runs} time${s.runs == 1 ? '' : 's'}'),
            const Divider(height: 20),
            if (sandbox && s.active) action('run', Icons.play_arrow_rounded, 'Run now (test)'),
            if (s.active) action('pause', Icons.pause_rounded, 'Pause'),
            if (s.paused) action('resume', Icons.play_circle_outline_rounded, 'Resume'),
            action('delete', Icons.delete_outline_rounded, 'Delete', color: Brand.danger),
          ],
        ),
      ),
    );
  }
}

/// Sets up a new scheduled payment. The payee is checked when it's saved.
class NewScheduleScreen extends StatefulWidget {
  const NewScheduleScreen({super.key, this.kind = ScheduleKind.avora});

  final ScheduleKind kind;

  @override
  State<NewScheduleScreen> createState() => _NewScheduleScreenState();
}

class _NewScheduleScreenState extends State<NewScheduleScreen> {
  late ScheduleKind _kind = widget.kind;
  Frequency _frequency = Frequency.monthly;
  DateTime? _start; // null is today
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _to = TextEditingController();
  final _account = TextEditingController();
  final _customer = TextEditingController();
  String _bank = banks.first.code;
  List<Biller>? _billers;
  Biller? _biller;
  BillPlan? _plan;
  List<SavingsPot>? _pots;
  SavingsPot? _pot;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _amount, _to, _account, _customer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _choose(ScheduleKind k) async {
    setState(() => _kind = k);
    final api = AppScope.of(context).api;
    try {
      if (k == ScheduleKind.bill && _billers == null) {
        final all = await api.billers();
        if (mounted) setState(() => _billers = all.where((b) => b.category != BillCategory.betting).toList());
      }
      if (k == ScheduleKind.savings && _pots == null) {
        final (pots, _) = await api.savings();
        if (!mounted) return;
        setState(() {
          _pots = pots.where((p) => p.open && p.kind == PotKind.goal).toList();
          _pot = _pots!.firstOrNull;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  int? get _amountKobo =>
      _kind == ScheduleKind.bill && (_biller?.hasPlans ?? false) ? _plan?.amount : parseNaira(_amount.text);

  bool get _ready {
    if (_amountKobo == null) return false;
    return switch (_kind) {
      ScheduleKind.avora => _to.text.trim().length >= 3,
      ScheduleKind.transfer => _account.text.length == 10,
      ScheduleKind.bill => _biller != null && _customer.text.trim().isNotEmpty && (!_biller!.hasPlans || _plan != null),
      ScheduleKind.savings => _pot != null,
    };
  }

  ScheduleTarget get _target => switch (_kind) {
    ScheduleKind.avora => ScheduleTarget(to: _to.text.trim()),
    ScheduleKind.transfer => ScheduleTarget(bankCode: _bank, accountNumber: _account.text),
    ScheduleKind.bill => ScheduleTarget(
      billerId: _biller!.id,
      planCode: _plan?.code ?? '',
      customer: _customer.text.trim(),
    ),
    ScheduleKind.savings => ScheduleTarget(potId: _pot!.id),
  };

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _start ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final today = d.year == now.year && d.month == now.month && d.day == now.day;
    // Later dates pay at 9am.
    setState(() => _start = today ? null : DateTime(d.year, d.month, d.day, 9));
  }

  Future<void> _save() async {
    final amount = _amountKobo;
    if (amount == null || !_ready) return;
    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PinCheckSheet(title: 'Enter your PIN', subtitle: 'to approve ${_short(amount)} ${_when()}'),
    );
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.of(context).api.createSchedule(
        kind: _kind,
        name: _name.text.trim().isNotEmpty
            ? _name.text.trim()
            : (_kind == ScheduleKind.bill
                  ? _billerName(_biller!)
                  : _kind == ScheduleKind.savings
                  ? _pot!.name
                  : ''),
        amount: amount,
        frequency: _frequency,
        startsAt: _start ?? DateTime.now(),
        target: _target,
        pin: pin,
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _when() {
    final from = _start == null ? 'today' : 'on ${formatDate(_start!)}';
    return switch (_frequency) {
      Frequency.once => from,
      Frequency.daily => 'every day from $from'.replaceFirst('from on', 'from'),
      Frequency.weekly => 'every week from $from'.replaceFirst('from on', 'from'),
      Frequency.monthly => 'every month from $from'.replaceFirst('from on', 'from'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final start = _start ?? DateTime.now();
    final amount = _amountKobo;
    return Scaffold(
      appBar: AppBar(title: const Text('New scheduled payment')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  Text('What to pay', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final k in ScheduleKind.values)
                        ChoiceChip(
                          key: Key('kind-${k.name}'),
                          avatar: Icon(scheduleIcon(k), size: 18),
                          label: Text(k.label),
                          selected: _kind == k,
                          onSelected: (_) => _choose(k),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(_kind.hint, style: muted),
                  const SizedBox(height: 16),
                  ..._payeeFields(theme),
                  if (!(_kind == ScheduleKind.bill && (_biller?.hasPlans ?? false))) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('schedule-amount'),
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: theme.textTheme.titleLarge,
                      decoration: const InputDecoration(labelText: 'Amount', prefixText: '₦ ', hintText: '0'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('schedule-name'),
                    controller: _name,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Name it (optional)',
                      hintText: 'e.g. Rent, Mum, Data',
                    ),
                  ),
                  Text('How often', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in Frequency.values)
                        ChoiceChip(
                          key: Key('freq-${f.name}'),
                          label: Text(f.label),
                          selected: _frequency == f,
                          onSelected: (_) => setState(() => _frequency = f),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    key: const Key('schedule-date'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_rounded),
                    title: Text(_frequency == Frequency.once ? 'Pay on' : 'Starts'),
                    trailing: Text(_start == null ? 'Today' : formatDate(_start!), style: theme.textTheme.titleSmall),
                    onTap: _pickDate,
                  ),
                  if (amount != null)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Brand.lime.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _frequency == Frequency.once
                            ? '${_short(amount)} on ${formatDate(start)}.'
                            : '${_short(amount)} ${_frequency.label.toLowerCase()}: '
                                  '${[for (var i = 0; i < 3; i++) formatDate(_frequency.at(start, i))].join(', ')} '
                                  'and on. Pause or delete it any time.',
                        key: const Key('schedule-preview'),
                        style: theme.textTheme.bodyMedium?.copyWith(color: Brand.deepGreen),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                key: const Key('schedule-save'),
                label: 'Schedule it',
                loading: _busy,
                onPressed: _ready && !_busy ? _save : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _payeeFields(ThemeData theme) {
    switch (_kind) {
      case ScheduleKind.avora:
        return [
          TextField(
            key: const Key('schedule-to'),
            controller: _to,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '@tag or phone number', prefixIcon: Icon(Icons.bolt_rounded)),
            onChanged: (_) => setState(() {}),
          ),
        ];
      case ScheduleKind.transfer:
        return [
          DropdownButtonFormField<String>(
            key: const Key('schedule-bank'),
            initialValue: _bank,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Bank'),
            items: [for (final b in banks) DropdownMenuItem(value: b.code, child: Text(b.name))],
            onChanged: (v) => setState(() => _bank = v ?? _bank),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('schedule-account'),
            controller: _account,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
            decoration: const InputDecoration(labelText: 'Account number'),
            onChanged: (_) => setState(() {}),
          ),
        ];
      case ScheduleKind.bill:
        final billers = _billers;
        if (billers == null) return [const Center(child: CircularProgressIndicator())];
        final b = _biller;
        return [
          DropdownButtonFormField<Biller>(
            key: const Key('schedule-biller'),
            initialValue: b,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Biller'),
            items: [for (final x in billers) DropdownMenuItem(value: x, child: Text(_billerName(x)))],
            onChanged: (v) => setState(() {
              _biller = v;
              _plan = null;
            }),
          ),
          if (b != null && b.hasPlans) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<BillPlan>(
              key: const Key('schedule-plan'),
              initialValue: _plan,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Plan'),
              items: [
                for (final p in b.plans) DropdownMenuItem(value: p, child: Text('${p.name} · ${_short(p.amount)}')),
              ],
              onChanged: (v) => setState(() => _plan = v),
            ),
          ],
          if (b != null) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('schedule-customer'),
              controller: _customer,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: b.customerLabel),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ];
      case ScheduleKind.savings:
        final pots = _pots;
        if (pots == null) return [const Center(child: CircularProgressIndicator())];
        if (pots.isEmpty) {
          return [
            Text(
              'Make a goal pot in the Savings tab first, then schedule savings into it.',
              style: theme.textTheme.bodyMedium,
            ),
          ];
        }
        return [
          DropdownButtonFormField<SavingsPot>(
            key: const Key('schedule-pot'),
            initialValue: _pot,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Goal pot'),
            items: [for (final p in pots) DropdownMenuItem(value: p, child: Text('${p.name} · ${_short(p.balance)}'))],
            onChanged: (v) => setState(() => _pot = v),
          ),
        ];
    }
  }
}
