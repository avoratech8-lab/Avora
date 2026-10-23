import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'shell_screen.dart';

/// Account, security and help.
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key, required this.shell});

  final ShellScreenState shell;

  Future<void> _signOut(BuildContext context) async {
    final scope = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text("You'll need a new code and your PIN to sign in again."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-sign-out'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await scope.recipients.clear();
    try {
      await scope.api.logout();
    } catch (_) {
      // The token is cleared locally either way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = shell.wallet;
    void soon(String f, IconData i) => showComingSoon(context, f, i);
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Text('Me', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(22)),
            child: Row(
              children: [
                const LogoMark(size: 52, light: true),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('My Avora account', style: theme.textTheme.titleMedium?.copyWith(color: Colors.white)),
                      const SizedBox(height: 2),
                      Text(
                        w == null ? '—' : 'TAJBank · ${w.accountNumber}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                      ),
                    ],
                  ),
                ),
                if (w != null)
                  IconButton(
                    tooltip: 'Copy account number',
                    color: Colors.white,
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: w.accountNumber));
                      if (context.mounted) showMessage(context, 'Account number copied');
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Brand.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.workspace_premium_outlined, color: Brand.warning),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Tier 1 account. Verify your BVN or NIN to raise your limits.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => soon('Account upgrade', Icons.workspace_premium_outlined),
                  child: const Text('Upgrade'),
                ),
              ],
            ),
          ),
          _Section('Account', [
            _Item(Icons.badge_outlined, 'Personal details', () => soon('Personal details', Icons.badge_outlined)),
            _Item(Icons.speed_rounded, 'Limits', () => soon('Limits', Icons.speed_rounded)),
            _Item(Icons.description_outlined, 'Statements', () => soon('Statements', Icons.description_outlined)),
          ]),
          _Section('Security', [
            _Item(
              Icons.fingerprint_rounded,
              'Fingerprint and face unlock',
              () => soon('Biometric unlock', Icons.fingerprint_rounded),
            ),
            _Item(Icons.password_rounded, 'Change PIN', () => soon('Change PIN', Icons.password_rounded)),
            _Item(Icons.devices_rounded, 'Devices', () => soon('Device management', Icons.devices_rounded)),
          ]),
          _Section('Help', [
            _Item(Icons.support_agent_rounded, 'Chat with us', () => soon('Support chat', Icons.support_agent_rounded)),
            _Item(Icons.help_outline_rounded, 'Help centre', () => soon('Help centre', Icons.help_outline_rounded)),
            _Item(Icons.gavel_rounded, 'Terms and privacy', () => soon('Terms and privacy', Icons.gavel_rounded)),
          ]),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const Key('sign-out'),
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () => _signOut(context),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Avora is a technology company. Banking services are provided by our CBN-licensed partner bank.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Item {
  const _Item(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.items);

  final String title;
  final List<_Item> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
          child: Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const Divider(indent: 56),
                ListTile(
                  leading: Icon(items[i].icon, color: theme.colorScheme.primary),
                  title: Text(items[i].label, style: theme.textTheme.titleSmall),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: items[i].onTap,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
