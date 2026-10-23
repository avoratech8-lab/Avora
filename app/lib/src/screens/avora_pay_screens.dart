import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/receipt.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'send_screen.dart';

/// Send to another Avora customer by @tag or phone: free and instant.
class AvoraPayScreen extends StatefulWidget {
  const AvoraPayScreen({super.key});

  @override
  State<AvoraPayScreen> createState() => _AvoraPayScreenState();
}

class _AvoraPayScreenState extends State<AvoraPayScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  Person? _person;
  String? _error;
  bool _looking = false;
  int _lookup = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  bool _ready(String q) {
    if (q.startsWith('@')) return q.length >= 4;
    final digits = q.replaceAll(RegExp(r'\D'), '');
    return RegExp(r'^[+\d\s-]+$').hasMatch(q)
        ? digits.length >= 11 || (digits.startsWith('234') && digits.length == 13)
        : q.length >= 3;
  }

  void _changed(String v) {
    final q = v.trim();
    final id = ++_lookup;
    _debounce?.cancel();
    setState(() {
      _person = null;
      _error = null;
      _looking = false;
    });
    if (!_ready(q)) return;
    // Wait for a pause in typing so we don't look up every letter.
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      setState(() => _looking = true);
      try {
        final p = await AppScope.of(context).api.findPerson(q);
        if (mounted && id == _lookup) setState(() => _person = p);
      } on ApiException catch (e) {
        if (mounted && id == _lookup) setState(() => _error = e.message);
      } catch (_) {
        if (mounted && id == _lookup) setState(() => _error = "We couldn't check that. Try again.");
      } finally {
        if (mounted && id == _lookup) setState(() => _looking = false);
      }
    });
  }

  // Pay by tag when they have one; otherwise by the number that was typed.
  void _continue(Person p, [String? to]) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AmountScreen(person: p, to: to ?? (p.tag.isNotEmpty ? '@${p.tag}' : _q.text.trim())),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final person = _person;
    final recents = AppScope.of(context).recipients.items.where((r) => r.bankCode == avoraBank).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Send to Avora')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Brand.lime.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.bolt_rounded, color: Brand.deepGreen),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Free and instant, every time. It never leaves Avora, so it never gets stuck.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: Brand.deepGreen),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const Key('avora-to'),
                    controller: _q,
                    autofocus: true,
                    autocorrect: false,
                    style: theme.textTheme.titleMedium,
                    decoration: InputDecoration(
                      hintText: '@tag or phone number',
                      prefixIcon: const Icon(Icons.alternate_email_rounded),
                      errorText: _error,
                      suffixIcon: _looking
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : null,
                    ),
                    onChanged: _changed,
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: person == null
                        ? const SizedBox(height: 8)
                        : Padding(
                            key: ValueKey(person.handle),
                            padding: const EdgeInsets.only(top: 12),
                            child: _PersonCard(person: person),
                          ),
                  ),
                  if (recents.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    Text('Recent on Avora', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final r in recents.take(8))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: InitialsAvatar(text: r.accountName),
                        title: Text(r.accountName, style: theme.textTheme.titleSmall),
                        subtitle: Text(r.accountNumber),
                        onTap: () => _continue(
                          Person(
                            tag: r.accountNumber.startsWith('@') ? r.accountNumber.substring(1) : '',
                            name: r.accountName,
                            phone: '',
                          ),
                          r.accountNumber,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                key: const Key('avora-next'),
                label: 'Continue',
                onPressed: person == null ? null : () => _continue(person),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person});

  final Person person;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          InitialsAvatar(text: person.name, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(person.name, style: theme.textTheme.titleSmall),
                Text(
                  [if (person.tag.isNotEmpty) '@${person.tag}', person.phone].where((s) => s.isNotEmpty).join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.verified_rounded, color: theme.colorScheme.primary),
        ],
      ),
    );
  }
}

/// Receipt for an Avora-to-Avora transfer. These are final the moment
/// they're made, so there's nothing to wait for.
class P2PReceiptScreen extends StatefulWidget {
  const P2PReceiptScreen({super.key, required this.id, this.initial});

  final String id;
  final P2PTransfer? initial;

  @override
  State<P2PReceiptScreen> createState() => _P2PReceiptScreenState();
}

class _P2PReceiptScreenState extends State<P2PReceiptScreen> {
  P2PTransfer? _t;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _t = widget.initial;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_t == null && _error == null) {
      AppScope.of(context).api
          .p2pTransfer(widget.id)
          .then(
            (t) {
              if (mounted) setState(() => _t = t);
            },
            onError: (Object e) {
              if (mounted) setState(() => _error = e);
            },
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Avora transfer')),
        body: Center(
          child: _error == null ? const CircularProgressIndicator() : const Text("We couldn't load this transfer."),
        ),
      );
    }
    final o = t.other;
    final rows = <(String, String)>[
      (t.outgoing ? 'To' : 'From', o.name),
      if (o.tag.isNotEmpty) ('Tag', '@${o.tag}'),
      if (t.note.isNotEmpty) ('Note', t.note),
      ('Fee', 'Free'),
      ('Date', formatWhen(t.createdAt)),
      ('Reference', t.id.substring(0, 18).toUpperCase()),
    ];
    final title = t.outgoing ? 'Sent' : 'Received';
    return Scaffold(
      appBar: AppBar(title: const Text('Avora transfer')),
      body: ReceiptView(
        tone: ReceiptTone.good,
        title: title,
        explanation: t.outgoing
            ? '${o.name} has it already. Avora transfers are instant and free.'
            : 'It\'s in your wallet.',
        amount: formatNaira(t.amount),
        rows: rows,
        shareText: receiptText(
          'Avora transfer ${t.outgoing ? 'to' : 'from'} ${o.name}',
          formatNaira(t.amount),
          title,
          rows,
        ),
      ),
    );
  }
}
