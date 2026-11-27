import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/transaction_tile.dart';
import '../ui/widgets.dart';
import 'security_screens.dart';

/// Me → Security → Freeze my account: one tap stops all money leaving, for
/// when a phone, PIN or card might be in the wrong hands.
class FreezeScreen extends StatefulWidget {
  const FreezeScreen({super.key});

  @override
  State<FreezeScreen> createState() => _FreezeScreenState();
}

class _FreezeScreenState extends State<FreezeScreen> {
  bool? _frozen;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_frozen == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final f = await AppScope.of(context).api.frozen();
      if (mounted) setState(() => _frozen = f);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _freeze() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Freeze your account?'),
        content: const Text(
          'No money will leave your account until you unfreeze it with your PIN: no transfers, bills, '
          'card payments or scheduled payments. Your other phones will be signed out. Money can still come in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-freeze'),
            style: TextButton.styleFrom(foregroundColor: Brand.danger),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Freeze now'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run((api) => api.freeze(), true, 'Account frozen. No money can leave it.');
  }

  Future<void> _unfreeze() async {
    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const PinCheckSheet(title: 'Enter your PIN', subtitle: 'to unfreeze your account'),
    );
    if (pin == null || !mounted) return;
    await _run((api) => api.unfreeze(pin), false, 'Account unfrozen');
  }

  Future<void> _run(Future<void> Function(AvoraApi api) f, bool frozen, String done) async {
    final api = AppScope.of(context).api;
    setState(() => _busy = true);
    try {
      await f(api);
      if (!mounted) return;
      setState(() => _frozen = frozen);
      showMessage(context, done);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frozen = _frozen;
    final color = frozen == true ? Brand.danger : theme.colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Freeze my account')),
      body: SafeArea(
        child: _error != null
            ? Center(child: Text(_error!))
            : frozen == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      children: [
                        Icon(frozen ? Icons.ac_unit_rounded : Icons.verified_user_rounded, size: 48, color: color),
                        const SizedBox(height: 12),
                        Text(
                          frozen ? 'Your account is frozen' : 'Your account is open',
                          key: const Key('freeze-status'),
                          style: theme.textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          frozen
                              ? 'No money can leave it. Money sent to you still arrives.'
                              : 'Lost your phone, or think someone knows your PIN or card details? '
                                    'Freeze your account and nothing can leave it.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('While it is frozen', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final (icon, text) in const [
                    (Icons.block_rounded, 'Transfers, bills and Avora payments are refused.'),
                    (Icons.credit_card_off_rounded, 'Card payments are declined.'),
                    (Icons.event_busy_rounded, "Scheduled payments don't go out."),
                    (Icons.phonelink_erase_rounded, 'Your other phones are signed out.'),
                    (Icons.south_west_rounded, 'Money sent to you still comes in.'),
                    (Icons.password_rounded, 'Only your PIN can unfreeze it.'),
                  ])
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
                      title: Text(text, style: theme.textTheme.bodyMedium),
                      dense: true,
                    ),
                  const SizedBox(height: 16),
                  if (frozen)
                    PrimaryButton(
                      key: const Key('unfreeze'),
                      label: 'Unfreeze with my PIN',
                      loading: _busy,
                      onPressed: _unfreeze,
                    )
                  else
                    FilledButton.icon(
                      key: const Key('freeze'),
                      style: FilledButton.styleFrom(backgroundColor: Brand.danger, foregroundColor: Colors.white),
                      onPressed: _busy ? null : _freeze,
                      icon: const Icon(Icons.ac_unit_rounded),
                      label: const Text('Freeze my account'),
                    ),
                ],
              ),
      ),
    );
  }
}

enum _Period { thisMonth, lastMonth, last3Months, custom }

/// Me → Statements: money in and out for a period, with opening and closing
/// balances, to read here or share as a spreadsheet (CSV) for a landlord,
/// visa or loan application.
class StatementScreen extends StatefulWidget {
  const StatementScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  State<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends State<StatementScreen> {
  _Period _period = _Period.thisMonth;
  late DateTimeRange _range;
  Future<PeriodStatement>? _statement;

  DateTime get _today {
    final n = (widget.now ?? DateTime.now)();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_statement == null) _pick(_Period.thisMonth);
  }

  DateTimeRange _rangeFor(_Period p) {
    final t = _today;
    return switch (p) {
      _Period.thisMonth => DateTimeRange(start: DateTime(t.year, t.month), end: t),
      _Period.lastMonth => DateTimeRange(start: DateTime(t.year, t.month - 1), end: DateTime(t.year, t.month, 0)),
      _Period.last3Months => DateTimeRange(start: DateTime(t.year, t.month - 2), end: t),
      _Period.custom => _range,
    };
  }

  Future<void> _pick(_Period p) async {
    var range = p == _Period.custom ? null : _rangeFor(p);
    if (p == _Period.custom) {
      range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(_today.year - 2),
        lastDate: _today,
        initialDateRange: _range,
        helpText: 'Choose up to a year',
      );
      if (range == null || !mounted) return;
      if (range.end.difference(range.start).inDays > 365) {
        showMessage(context, 'A statement can cover up to a year.');
        return;
      }
    }
    setState(() {
      _period = p;
      _range = range!;
      _statement = AppScope.of(context).api.periodStatement(from: range.start, to: range.end);
    });
  }

  Future<void> _share(PeriodStatement s) async {
    final name = 'avora-statement-${isoDate(s.from)}-to-${isoDate(s.to)}.csv';
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(utf8.encode(statementCsv(s)), mimeType: 'text/csv', name: name)],
        fileNameOverrides: [name],
        subject: 'Avora statement, ${formatDate(s.from)} to ${formatDate(s.to)}',
        text: statementSummary(s),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Statements')),
      body: SafeArea(
        child: FutureBuilder<PeriodStatement>(
          future: _statement,
          builder: (context, snap) {
            final s = snap.data;
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (p, label) in const [
                      (_Period.thisMonth, 'This month'),
                      (_Period.lastMonth, 'Last month'),
                      (_Period.last3Months, 'Last 3 months'),
                      (_Period.custom, 'Choose dates'),
                    ])
                      ChoiceChip(
                        key: Key('period-${p.name}'),
                        label: Text(label),
                        selected: _period == p,
                        onSelected: (_) => _pick(p),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (snap.hasError)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snap.error is ApiException
                          ? (snap.error! as ApiException).message
                          : 'Something went wrong. Please try again.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else if (s == null)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(22)),
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(color: Colors.white),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${formatDate(s.from)} to ${formatDate(s.to)}',
                            style: theme.textTheme.labelLarge?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                          ),
                          const SizedBox(height: 14),
                          _SummaryRow('Opening balance', formatNaira(s.openingBalance)),
                          _SummaryRow('Money in', '+${formatNaira(s.moneyIn)}'),
                          _SummaryRow('Money out', '−${formatNaira(s.moneyOut)}'),
                          const Divider(color: Colors.white24, height: 20),
                          _SummaryRow('Closing balance', formatNaira(s.closingBalance), bold: true),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('share-statement'),
                    onPressed: () => _share(s),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Share as a spreadsheet'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    s.lines.isEmpty ? 'Nothing moved in these dates.' : '${s.lines.length} transactions',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (s.truncated)
                    Text(
                      'Showing the first ${s.lines.length}. Choose fewer dates to see the rest.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  const SizedBox(height: 4),
                  for (final l in s.lines.reversed) TransactionTile(line: l),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (bold ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)?.copyWith(color: Colors.white);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

String _csvCell(String v) => RegExp(r'[",\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;

String _plain(int kobo) => (kobo / 100).toStringAsFixed(2);

/// The statement as CSV, which opens in Excel, Google Sheets or Numbers.
/// Amounts are naira with two decimals, so they add up as numbers.
String statementCsv(PeriodStatement s) {
  final rows = <List<String>>[
    ['Avora account statement'],
    ['Account name', s.accountName],
    ['Account number', s.accountNumber],
    ['Period', '${isoDate(s.from)} to ${isoDate(s.to)}'],
    ['Opening balance', _plain(s.openingBalance)],
    ['Money in', _plain(s.moneyIn)],
    ['Money out', _plain(s.moneyOut)],
    ['Closing balance', _plain(s.closingBalance)],
    [],
    ['Date', 'Time', 'Description', 'Money in', 'Money out', 'Balance', 'Reference'],
  ];
  var balance = s.openingBalance;
  for (final l in s.lines) {
    balance += l.amount;
    final at = l.at.toLocal();
    rows.add([
      isoDate(at),
      formatTime(at),
      l.description,
      l.amount > 0 ? _plain(l.amount) : '',
      l.amount < 0 ? _plain(-l.amount) : '',
      _plain(balance),
      l.ref,
    ]);
  }
  return '${rows.map((r) => r.map(_csvCell).join(',')).join('\r\n')}\r\n';
}

/// A few lines for the message that goes with a shared statement.
String statementSummary(PeriodStatement s) => [
  'Avora statement for ${s.accountNumber}',
  '${formatDate(s.from)} to ${formatDate(s.to)}',
  'Opening balance: ${formatNaira(s.openingBalance)}',
  'Money in: ${formatNaira(s.moneyIn)}',
  'Money out: ${formatNaira(s.moneyOut)}',
  'Closing balance: ${formatNaira(s.closingBalance)}',
].join('\n');

/// Opens the "Report a problem" sheet for the payment [ref]. Returns true
/// when a report was sent.
Future<bool> showReportProblem(BuildContext context, {required String ref, required String what}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ReportProblemSheet(paymentRef: ref, what: what),
  );
  return sent == true;
}

class ReportProblemSheet extends StatefulWidget {
  const ReportProblemSheet({super.key, required this.paymentRef, required this.what});

  final String paymentRef;
  final String what; // e.g. "₦5,000.00 to ADA OBI"

  @override
  State<ReportProblemSheet> createState() => _ReportProblemSheetState();
}

class _ReportProblemSheetState extends State<ReportProblemSheet> {
  ProblemReason? _reason;
  final _details = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).api
          .reportProblem(ref: widget.paymentRef, reason: reason, details: _details.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Report a problem', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(widget.what, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              RadioGroup<ProblemReason>(
                groupValue: _reason,
                onChanged: (r) => setState(() => _reason = r),
                child: Column(
                  children: [
                    for (final r in ProblemReason.values)
                      RadioListTile<ProblemReason>(
                        key: Key('reason-${r.code}'),
                        contentPadding: EdgeInsets.zero,
                        value: r,
                        title: Text(r.label),
                      ),
                  ],
                ),
              ),
              TextField(
                key: const Key('problem-details'),
                controller: _details,
                maxLength: 500,
                maxLines: 3,
                minLines: 2,
                decoration: InputDecoration(
                  hintText: _reason == ProblemReason.other
                      ? 'Tell us what went wrong'
                      : 'Anything else we should know?',
                ),
              ),
              if (_reason == ProblemReason.notMe)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'If someone else may be using your account, freeze it now under Me → Security.',
                    style: theme.textTheme.bodySmall?.copyWith(color: Brand.danger),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                ),
              PrimaryButton(
                key: const Key('send-report'),
                label: 'Send report',
                loading: _busy,
                onPressed: _reason == null ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Me → Help → My reports: problems I've reported and the answers.
class ProblemReportsScreen extends StatelessWidget {
  const ProblemReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('My reports')),
      body: SafeArea(
        child: FutureBuilder<List<ProblemReport>>(
          future: AppScope.of(context).api.problemReports(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Text(
                  snap.error is ApiException
                      ? (snap.error! as ApiException).message
                      : 'Something went wrong. Please try again.',
                ),
              );
            }
            final list = snap.data;
            if (list == null) return const Center(child: CircularProgressIndicator());
            if (list.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No reports yet. If something looks wrong with a payment, open its receipt and tap '
                    '"Report a problem".',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _ReportCard(list[i]),
            );
          },
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard(this.r);

  final ProblemReport r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (r.status) {
      ProblemStatus.open => ('Looking into it', Brand.warning),
      ProblemStatus.resolved => ('Resolved', theme.colorScheme.primary),
      ProblemStatus.rejected => ('Answered', theme.colorScheme.onSurfaceVariant),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(r.description, style: theme.textTheme.titleSmall)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${formatNaira(r.amount.abs())} · ${r.reason.label} · ${formatDate(r.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (r.details.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(r.details, style: theme.textTheme.bodyMedium),
            ],
            if (r.answer.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('Avora: ${r.answer}', style: theme.textTheme.bodyMedium),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
