import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../money.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Me → Limits: the account's KYC tier, what it allows, and BVN or NIN
/// verification to move up.
class LimitsScreen extends StatefulWidget {
  const LimitsScreen({super.key});

  @override
  State<LimitsScreen> createState() => _LimitsScreenState();
}

class _LimitsScreenState extends State<LimitsScreen> {
  KycStatus? _status;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_status == null && _error == null) {
      AppScope.of(context).api.kycStatus().then(
        (s) {
          if (mounted) setState(() => _status = s);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      );
    }
  }

  Future<void> _verify(String kind) async {
    final s = await showModalBottomSheet<KycStatus>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _VerifySheet(kind: kind),
    );
    if (s == null || !mounted) return;
    final raised = s.tier > (_status?.tier ?? 1);
    setState(() => _status = s);
    showMessage(context, raised ? "You're now on Tier ${s.tier}" : '${kind.toUpperCase()} verified');
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Limits')),
      body: s == null
          ? Center(
              child: _error == null ? const CircularProgressIndicator() : const Text("We couldn't load your limits."),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                _TierCard(status: s),
                const SizedBox(height: 20),
                if (s.tier < 3) ...[
                  Text('Raise your limits', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Card(
                    child: Column(
                      children: [
                        _IdTile(
                          kind: 'bvn',
                          label: 'Bank Verification Number',
                          hint: 'Dial *565*0# on the phone line linked to your bank to get it.',
                          verified: s.bvnVerified,
                          onTap: () => _verify('bvn'),
                        ),
                        const Divider(indent: 56),
                        _IdTile(
                          kind: 'nin',
                          label: 'National Identification Number',
                          hint: 'Dial *346# from the phone line linked to your NIN.',
                          verified: s.ninVerified,
                          onTap: () => _verify('nin'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                Text('All tiers', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                for (final t in s.tiers) _TierRow(tier: t, current: t.tier == s.tier),
                const SizedBox(height: 12),
                Text(
                  'Limits are set by the Central Bank of Nigeria for each KYC tier. Transfers and bill payments '
                  'count towards the daily limit, which resets at midnight.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
    );
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({required this.status});

  final KycStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = status.limits;
    final white = theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.8));
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium_rounded, color: Brand.lime),
              const SizedBox(width: 8),
              Text(
                'Tier ${status.tier}',
                key: const Key('tier'),
                style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Send per day', style: white),
                    const SizedBox(height: 2),
                    Text(formatNaira(l.dailySend), style: theme.textTheme.titleMedium?.copyWith(color: Colors.white)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Maximum balance', style: white),
                    const SizedBox(height: 2),
                    Text(
                      l.maxBalance == 0 ? 'No limit' : formatNaira(l.maxBalance),
                      style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IdTile extends StatelessWidget {
  const _IdTile({
    required this.kind,
    required this.label,
    required this.hint,
    required this.verified,
    required this.onTap,
  });

  final String kind;
  final String label;
  final String hint;
  final bool verified;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: Key('verify-$kind'),
      leading: Icon(
        verified ? Icons.verified_rounded : Icons.badge_outlined,
        color: verified ? Brand.green : theme.colorScheme.primary,
      ),
      title: Text(kind.toUpperCase(), style: theme.textTheme.titleSmall),
      subtitle: Text(verified ? 'Verified' : label),
      trailing: verified ? null : const Chip(label: Text('Verify'), visualDensity: VisualDensity.compact),
      onTap: verified ? null : onTap,
    );
  }
}

class _TierRow extends StatelessWidget {
  const _TierRow({required this.tier, required this.current});

  final KycTier tier;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: current ? Brand.green : theme.colorScheme.outlineVariant, width: current ? 2 : 1),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: current ? Brand.green : theme.colorScheme.surfaceContainerHighest,
            child: Text(
              '${tier.tier}',
              style: theme.textTheme.titleSmall?.copyWith(color: current ? Colors.white : null),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tier.needs, style: theme.textTheme.titleSmall),
                Text(
                  '${formatNaira(tier.dailySend)} a day · '
                  '${tier.maxBalance == 0 ? 'no balance limit' : 'hold up to ${formatNaira(tier.maxBalance)}'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (current) const Icon(Icons.check_circle_rounded, color: Brand.green),
        ],
      ),
    );
  }
}

class _VerifySheet extends StatefulWidget {
  const _VerifySheet({required this.kind});

  final String kind;

  @override
  State<_VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends State<_VerifySheet> {
  final _number = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await AppScope.of(context).api.verifyKyc(kind: widget.kind, number: _number.text);
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ApiException ? e.message : 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.kind.toUpperCase();
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Verify your $name', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              "We check it with ${widget.kind == 'bvn' ? 'NIBSS' : 'NIMC'} through our partner bank. "
              'We only keep the last 4 digits.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('id-number'),
              controller: _number,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 11,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: '11-digit $name', errorText: _error, counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              key: const Key('id-submit'),
              label: 'Verify',
              loading: _busy,
              onPressed: _number.text.length == 11 && !_busy ? _submit : null,
            ),
          ],
        ),
      ),
    );
  }
}
