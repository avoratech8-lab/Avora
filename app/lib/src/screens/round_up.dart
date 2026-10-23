import 'package:flutter/material.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

String _short(int kobo) => formatNaira(kobo).replaceAll('.00', '');

/// The Savings tab's round-up switch: save the change from every payment.
class RoundUpCard extends StatefulWidget {
  const RoundUpCard({super.key, required this.goals, required this.onChanged});

  final List<SavingsPot> goals; // open goal pots
  final VoidCallback onChanged;

  @override
  State<RoundUpCard> createState() => _RoundUpCardState();
}

class _RoundUpCardState extends State<RoundUpCard> {
  RoundUp? _r;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_r == null) _load();
  }

  Future<void> _load() async {
    try {
      final r = await AppScope.of(context).api.roundUp();
      if (mounted) setState(() => _r = r);
    } catch (_) {
      // The card just stays hidden.
    }
  }

  Future<void> _edit() async {
    final r = _r;
    if (r == null) return;
    final saved = await showModalBottomSheet<RoundUp>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RoundUpSheet(current: r, goals: widget.goals),
    );
    if (saved == null || !mounted) return;
    setState(() => _r = saved);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _r;
    if (r == null) return const SizedBox.shrink();
    final pot = widget.goals.where((p) => p.id == r.potId).firstOrNull;
    final on = r.on && pot != null;
    return Material(
      color: on ? Brand.lime.withValues(alpha: 0.35) : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: const Key('roundup'),
        borderRadius: BorderRadius.circular(20),
        onTap: _edit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.autorenew_rounded, color: on ? Brand.deepGreen : theme.colorScheme.primary, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(on ? 'Round-ups are on' : 'Save your change', style: theme.textTheme.titleSmall),
                    Text(
                      on
                          ? 'Every payment rounds up to the next ${_short(r.step)}, into ${pot.name}.'
                          : 'Round each payment up to the next ₦100 and save the difference.',
                      key: const Key('roundup-status'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundUpSheet extends StatefulWidget {
  const _RoundUpSheet({required this.current, required this.goals});

  final RoundUp current;
  final List<SavingsPot> goals;

  @override
  State<_RoundUpSheet> createState() => _RoundUpSheetState();
}

class _RoundUpSheetState extends State<_RoundUpSheet> {
  late String _pot = widget.goals.any((p) => p.id == widget.current.potId)
      ? widget.current.potId
      : (widget.goals.firstOrNull?.id ?? '');
  late int _step = widget.current.step;
  bool _busy = false;
  String? _error;

  Future<void> _save(String potId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await AppScope.of(context).api.setRoundUp(potId: potId, step: _step);
      if (mounted) Navigator.pop(context, r);
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
    final example = 245000; // ₦2,450
    final extra = RoundUp(potId: 'x', step: _step).extraFor(example);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Round-ups', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Pay ${_short(example)} and we save ${_short(extra)} so it comes to '
              '${_short(example + extra)}. It works on transfers, bills, Avora payments and card payments, '
              "and skips when your balance is too low.",
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (widget.goals.isEmpty)
              Text(
                'Open a goal pot first. Round-ups go into it.',
                style: theme.textTheme.bodyMedium?.copyWith(color: Brand.warning),
              )
            else ...[
              Text('Round up to the next', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1000, label: Text('₦10')),
                  ButtonSegment(value: 10000, label: Text('₦100')),
                  ButtonSegment(value: 100000, label: Text('₦1,000')),
                ],
                selected: {_step},
                onSelectionChanged: (s) => setState(() => _step = s.first),
              ),
              const SizedBox(height: 16),
              Text('Save into', style: theme.textTheme.labelMedium),
              RadioGroup<String>(
                groupValue: _pot,
                onChanged: (v) => setState(() => _pot = v ?? _pot),
                child: Column(
                  children: [
                    for (final p in widget.goals)
                      RadioListTile<String>(
                        key: Key('roundup-pot-${p.name}'),
                        contentPadding: EdgeInsets.zero,
                        value: p.id,
                        title: Text(p.name),
                        subtitle: Text(formatNaira(p.balance)),
                      ),
                  ],
                ),
              ),
            ],
            if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
            PrimaryButton(
              key: const Key('roundup-save'),
              label: widget.current.on ? 'Save' : 'Turn on round-ups',
              loading: _busy,
              onPressed: _pot.isEmpty ? null : () => _save(_pot),
            ),
            if (widget.current.on)
              TextButton(
                key: const Key('roundup-off'),
                onPressed: _busy ? null : () => _save(''),
                child: const Text('Turn off'),
              ),
          ],
        ),
      ),
    );
  }
}
