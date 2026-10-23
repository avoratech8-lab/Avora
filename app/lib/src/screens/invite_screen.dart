import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../money.dart';
import '../ui/theme.dart';

/// Me → Invite friends: your code, what you've earned, and a place to add
/// the code of whoever invited you.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  ReferralSummary? _s;
  Object? _error;
  final _code = TextEditingController();
  bool _joining = false;
  String? _joinError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_s == null && _error == null) {
      AppScope.of(context).api.referrals().then(
        (s) {
          if (mounted) setState(() => _s = s);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      );
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      final s = await AppScope.of(context).api.joinReferral(_code.text);
      if (!mounted) return;
      setState(() => _s = s);
      showMessage(context, 'Invite code added');
    } catch (e) {
      if (mounted) setState(() => _joinError = e is ApiException ? e.message : 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('Invite friends')),
      body: s == null
          ? Center(
              child: _error == null ? const CircularProgressIndicator() : const Text("We couldn't load your invites."),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.card_giftcard_rounded, color: Brand.lime, size: 36),
                      const SizedBox(height: 12),
                      Text(
                        'Get ${formatNaira(s.reward)} for every friend',
                        style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'When a friend joins with your code and verifies their BVN or NIN, we pay you straight into '
                        'your wallet.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.code,
                                key: const Key('invite-code'),
                                style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, letterSpacing: 2),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Copy code',
                              color: Colors.white,
                              icon: const Icon(Icons.copy_rounded),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: s.code));
                                if (context.mounted) showMessage(context, 'Code copied');
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('invite-share'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Brand.lime,
                            foregroundColor: Brand.deepGreen,
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: () => SharePlus.instance.share(
                            ShareParams(
                              text:
                                  'I use Avora to send money, pay bills and save interest-free. Join with my code '
                                  '${s.code} when you sign up.',
                            ),
                          ),
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Share invite'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _Stat(label: 'Joined', value: '${s.invited}'),
                    const SizedBox(width: 10),
                    _Stat(label: 'Verified', value: '${s.rewarded}'),
                    const SizedBox(width: 10),
                    _Stat(label: 'Earned', value: formatNaira(s.earned), key: const Key('invite-earned')),
                  ],
                ),
                const SizedBox(height: 24),
                if (s.joinedWith.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.how_to_reg_rounded, color: Brand.green),
                    title: Text('You joined with ${s.joinedWith}', style: theme.textTheme.titleSmall),
                  )
                else if (s.canAddCode) ...[
                  Text('Were you invited?', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    "Add your friend's code within 30 days of joining so they get their reward.",
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('join-code'),
                          controller: _code,
                          textCapitalization: TextCapitalization.characters,
                          decoration: InputDecoration(hintText: 'Invite code', errorText: _joinError),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 96,
                        height: 56,
                        child: FilledButton(
                          key: const Key('join-submit'),
                          onPressed: _code.text.trim().isEmpty || _joining ? null : _join,
                          child: const Text('Add'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(child: Text(value, style: theme.textTheme.titleMedium)),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
