import 'package:flutter/material.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'security_screens.dart';

String _short(int kobo) => formatNaira(kobo).replaceAll('.00', '');

/// Bills shared with other Avora customers: the ones you asked for, and the
/// ones waiting on you.
class SplitsScreen extends StatefulWidget {
  const SplitsScreen({super.key});

  @override
  State<SplitsScreen> createState() => _SplitsScreenState();
}

class _SplitsScreenState extends State<SplitsScreen> {
  List<SplitBill>? _splits;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_splits == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final list = await AppScope.of(context).api.splits();
      if (mounted) {
        setState(() {
          _splits = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _splits;
    final waiting = list?.where((s) => s.awaitingMe).toList() ?? const <SplitBill>[];
    final mine = list?.where((s) => s.mine).toList() ?? const <SplitBill>[];
    final answered = list?.where((s) => !s.mine && !s.awaitingMe).toList() ?? const <SplitBill>[];
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Split bills')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('split-new'),
        onPressed: () => _go(const NewSplitScreen()),
        icon: const Icon(Icons.call_split_rounded),
        label: const Text('Split a bill'),
      ),
      body: SafeArea(
        child: list == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : OutlinedButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _load();
                        },
                        child: const Text('Try again'),
                      ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                  children: [
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          children: [
                            Icon(Icons.groups_rounded, size: 52, color: theme.colorScheme.primary),
                            const SizedBox(height: 12),
                            Text('Paid for everyone?', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text(
                              'Split it with friends on Avora. They get a request, pay in one tap, and you see who '
                              'has paid. No awkward reminders.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    if (waiting.isNotEmpty) header('Waiting on you'),
                    for (final s in waiting)
                      _SplitTile(
                        split: s,
                        onTap: () => _go(SplitScreen(splitId: s.id)),
                      ),
                    if (mine.isNotEmpty) header('You asked'),
                    for (final s in mine)
                      _SplitTile(
                        split: s,
                        onTap: () => _go(SplitScreen(splitId: s.id)),
                      ),
                    if (answered.isNotEmpty) header('Answered'),
                    for (final s in answered)
                      _SplitTile(
                        split: s,
                        onTap: () => _go(SplitScreen(splitId: s.id)),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _SplitTile extends StatelessWidget {
  const _SplitTile({required this.split, required this.onTap});

  final SplitBill split;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = split;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final me = s.myShare;
    final String line;
    final Widget trailing;
    if (s.mine) {
      final paid = s.shares.where((x) => x.status == ShareStatus.paid).length;
      line = '$paid of ${s.shares.length} paid · ${_short(s.collected)} of ${_short(s.asked)}';
      trailing = Text(_short(s.total), style: theme.textTheme.titleSmall);
    } else {
      line = '${s.creator} · ${formatDate(s.createdAt)}';
      trailing = _StatusChip(status: me!.status, amount: me.amount);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: Key('split-${s.title}'),
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: Brand.green.withValues(alpha: 0.12),
                      child: const Icon(Icons.call_split_rounded, color: Brand.green, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                          Text(line, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    trailing,
                  ],
                ),
                if (s.mine) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: s.asked == 0 ? 0 : s.collected / s.asked,
                      minHeight: 6,
                      color: Brand.green,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.amount});

  final ShareStatus status;
  final int amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, color) = switch (status) {
      ShareStatus.paid => ('Paid', Brand.green),
      ShareStatus.declined => ('Declined', Brand.danger),
      ShareStatus.pending => (_short(amount), Brand.warning),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// One split: who owes what, and Pay or Decline when it's waiting on you.
class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key, required this.splitId});

  final String splitId;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  SplitBill? _split;
  Object? _error;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_split == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final s = await AppScope.of(context).api.split(widget.splitId);
      if (mounted) setState(() => _split = s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pay() async {
    final s = _split!;
    final amount = s.myShare!.amount;
    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PinCheckSheet(title: 'Enter your PIN', subtitle: 'to pay ${_short(amount)} for ${s.title}'),
    );
    if (pin == null || !mounted) return;
    await _answer((api) => api.paySplit(s.id, pin), 'Paid ${_short(amount)}. Free and instant.');
  }

  Future<void> _answer(Future<SplitBill> Function(AvoraApi api) f, String done) async {
    setState(() => _busy = true);
    try {
      final s = await f(AppScope.of(context).api);
      if (!mounted) return;
      setState(() => _split = s);
      showMessage(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _split;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error is ApiException ? (_error as ApiException).message : 'Something went wrong.',
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      );
    }
    final me = s.myShare;
    final yourPart = s.total - s.asked;
    return Scaffold(
      appBar: AppBar(title: const Text('Split bill')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.title, style: theme.textTheme.titleLarge?.copyWith(color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(
                          s.mine ? 'You paid ${_short(s.total)}' : '${s.creator} paid ${_short(s.total)}',
                          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                        ),
                        const SizedBox(height: 16),
                        if (s.mine) ...[
                          Text(
                            '${_short(s.collected)} of ${_short(s.asked)} back',
                            key: const Key('split-collected'),
                            style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white),
                          ),
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: s.asked == 0 ? 0 : s.collected / s.asked,
                              minHeight: 8,
                              color: Brand.lime,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          if (yourPart > 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Your part: ${_short(yourPart)}',
                              style: theme.textTheme.bodySmall?.copyWith(color: Brand.lime),
                            ),
                          ],
                        ] else
                          Text(
                            switch (me!.status) {
                              ShareStatus.pending => 'Your share: ${_short(me.amount)}',
                              ShareStatus.paid => 'You paid ${_short(me.amount)}',
                              ShareStatus.declined => 'You declined ${_short(me.amount)}',
                            },
                            key: const Key('split-my-share'),
                            style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Who\'s in', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  for (final x in s.shares)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: InitialsAvatar(text: x.label, size: 40),
                      title: Text(x.you ? 'You' : x.label),
                      subtitle: x.tag.isEmpty ? null : Text('@${x.tag}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_short(x.amount), style: theme.textTheme.titleSmall),
                          const SizedBox(width: 10),
                          Icon(
                            switch (x.status) {
                              ShareStatus.paid => Icons.check_circle_rounded,
                              ShareStatus.declined => Icons.cancel_rounded,
                              ShareStatus.pending => Icons.schedule_rounded,
                            },
                            size: 20,
                            color: switch (x.status) {
                              ShareStatus.paid => Brand.green,
                              ShareStatus.declined => Brand.danger,
                              ShareStatus.pending => Brand.warning,
                            },
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Asked ${formatWhen(s.createdAt)}. Shares are paid as free, instant Avora transfers.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (s.awaitingMe)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('split-decline'),
                        onPressed: _busy ? null : () => _answer((api) => api.declineSplit(s.id), 'Declined'),
                        child: const Text('Decline'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: PrimaryButton(
                        key: const Key('split-pay'),
                        label: 'Pay ${_short(me!.amount)}',
                        loading: _busy,
                        onPressed: _pay,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Friend {
  _Friend(this.person, this.to);

  final Person person;
  final String to; // what to send: @tag, or the number as typed
  final amount = TextEditingController();
}

/// Asks friends on Avora to chip in for a bill.
class NewSplitScreen extends StatefulWidget {
  const NewSplitScreen({super.key});

  @override
  State<NewSplitScreen> createState() => _NewSplitScreenState();
}

class _NewSplitScreenState extends State<NewSplitScreen> {
  final _title = TextEditingController();
  final _total = TextEditingController();
  final _who = TextEditingController();
  final _friends = <_Friend>[];
  bool _even = true;
  bool _finding = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_title, _total, _who, for (final f in _friends) f.amount]) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _totalKobo => parseNaira(_total.text);

  /// Each friend's share: an even split counts you in, and you cover any
  /// leftover kobo.
  List<int?> get _shares {
    final total = _totalKobo;
    if (_even) {
      final each = total == null || _friends.isEmpty ? null : total ~/ (_friends.length + 1);
      return [for (final _ in _friends) each];
    }
    return [for (final f in _friends) parseNaira(f.amount.text)];
  }

  Future<void> _add() async {
    final q = _who.text.trim();
    if (q.isEmpty) return;
    setState(() => _finding = true);
    try {
      final p = await AppScope.of(context).api.findPerson(q);
      if (!mounted) return;
      final to = p.tag.isNotEmpty ? '@${p.tag}' : q;
      if (_friends.any((f) => f.to == to || (p.tag.isNotEmpty && f.person.tag == p.tag))) {
        showMessage(context, '${p.name} is already in.');
      } else if (_friends.length >= 10) {
        showMessage(context, 'You can ask up to 10 people.');
      } else {
        setState(() => _friends.add(_Friend(p, to)));
        _who.clear();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  Future<void> _send() async {
    final total = _totalKobo;
    final shares = _shares;
    if (total == null || shares.any((s) => s == null)) return;
    setState(() => _busy = true);
    try {
      final sp = await AppScope.of(context).api.createSplit(
        title: _title.text.trim(),
        total: total,
        people: [for (var i = 0; i < _friends.length; i++) (_friends[i].to, shares[i]!)],
      );
      if (!mounted) return;
      showMessage(context, 'Asked ${_friends.length} ${_friends.length == 1 ? 'person' : 'people'}');
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => SplitScreen(splitId: sp.id)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _totalKobo;
    final shares = _shares;
    final asked = shares.fold<int>(0, (a, s) => a + (s ?? 0));
    final over = total != null && asked > total;
    final ready =
        _title.text.trim().isNotEmpty && total != null && _friends.isNotEmpty && !shares.contains(null) && !over;
    return Scaffold(
      appBar: AppBar(title: const Text('Split a bill')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  TextField(
                    key: const Key('split-title'),
                    controller: _title,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'What was it for?',
                      hintText: 'e.g. Dinner at Yellow Chilli',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    key: const Key('split-total'),
                    controller: _total,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: theme.textTheme.titleLarge,
                    decoration: const InputDecoration(labelText: 'Whole bill', prefixText: '₦ ', hintText: '0'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 20),
                  Text('Who\'s in', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('split-person'),
                          controller: _who,
                          autocorrect: false,
                          decoration: const InputDecoration(hintText: '@tag or phone number'),
                          onSubmitted: (_) => _add(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        key: const Key('split-add'),
                        tooltip: 'Add',
                        onPressed: _finding ? null : _add,
                        icon: _finding
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.person_add_alt_1_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('split-even'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Split evenly, me included'),
                    value: _even,
                    onChanged: (v) => setState(() => _even = v),
                  ),
                  for (var i = 0; i < _friends.length; i++)
                    ListTile(
                      key: Key('friend-$i'),
                      contentPadding: EdgeInsets.zero,
                      leading: InitialsAvatar(text: _friends[i].person.name, size: 40),
                      title: Text(_friends[i].person.name),
                      subtitle: Text(_friends[i].to),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_even)
                            Text(shares[i] == null ? '—' : formatNaira(shares[i]!), style: theme.textTheme.titleSmall)
                          else
                            SizedBox(
                              width: 96,
                              child: TextField(
                                key: Key('share-$i'),
                                controller: _friends[i].amount,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                textAlign: TextAlign.end,
                                decoration: const InputDecoration(prefixText: '₦', hintText: '0', isDense: true),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() => _friends.removeAt(i).amount.dispose()),
                          ),
                        ],
                      ),
                    ),
                  if (total != null && _friends.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: (over ? Brand.danger : Brand.lime).withValues(alpha: over ? 0.12 : 0.35),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        over
                            ? 'The shares come to ${formatNaira(asked)}, more than the bill.'
                            : 'You cover ${formatNaira(total - asked)}. Everyone gets a request they can pay in one tap.',
                        key: const Key('split-summary'),
                        style: theme.textTheme.bodyMedium?.copyWith(color: over ? Brand.danger : Brand.deepGreen),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: PrimaryButton(
                key: const Key('split-send'),
                label: _friends.isEmpty
                    ? 'Ask for the money'
                    : 'Ask ${_friends.length} ${_friends.length == 1 ? 'person' : 'people'}',
                loading: _busy,
                onPressed: ready ? _send : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
