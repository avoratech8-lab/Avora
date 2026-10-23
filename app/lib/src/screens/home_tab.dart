import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../app.dart';
import '../banks.dart';
import '../dates.dart';
import '../money.dart';
import '../recipients.dart';
import '../ui/theme.dart';
import '../ui/transaction_tile.dart';
import '../ui/widgets.dart';
import 'avora_pay_screens.dart';
import 'bills_screens.dart';
import 'invite_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';
import 'open_line.dart';
import 'receive_sheet.dart';
import 'send_screen.dart';
import 'shell_screen.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.shell});

  final ShellScreenState shell;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  ShellScreenState get shell => widget.shell;

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await shell.refresh();
  }

  void _bills(BillCategory c) => _go(BillerScreen(category: c));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wallet = shell.wallet;
    final recipients = AppScope.of(context).recipients;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: shell.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Row(
              children: [
                const LogoMark(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        greeting(),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      Text('Welcome back', style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  key: const Key('scan'),
                  tooltip: 'Scan to pay',
                  onPressed: () => _go(const ScanScreen()),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const Key('bell'),
                  tooltip: 'Notifications',
                  onPressed: () => _go(const NotificationsScreen()),
                  icon: Badge(
                    isLabelVisible: shell.unread > 0,
                    label: Text('${shell.unread > 9 ? '9+' : shell.unread}'),
                    backgroundColor: Brand.danger,
                    child: const Icon(Icons.notifications_none_rounded),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (shell.loading)
              const _CardSkeleton()
            else if (wallet == null)
              _LoadError(onRetry: shell.refresh)
            else
              ListenableBuilder(
                listenable: AppScope.of(context).preferences,
                builder: (context, _) => _BalanceCard(
                  wallet: wallet,
                  hidden: AppScope.of(context).preferences.hideBalance,
                  onToggle: () {
                    final prefs = AppScope.of(context).preferences;
                    prefs.setHideBalance(!prefs.hideBalance);
                  },
                  onAdd: () => showReceiveSheet(context, wallet.accountNumber),
                  onSend: () => _go(const SendScreen()),
                ),
              ),
            const SizedBox(height: 24),
            _QuickActions(
              actions: [
                _Action('To Avora', Icons.bolt_rounded, () => _go(const AvoraPayScreen())),
                _Action('To bank', Icons.account_balance_outlined, () => _go(const SendScreen())),
                _Action('Airtime', Icons.phone_android_rounded, () => _bills(BillCategory.airtime)),
                _Action('Data', Icons.wifi_rounded, () => _bills(BillCategory.data)),
                _Action('Electricity', Icons.lightbulb_outline_rounded, () => _bills(BillCategory.electricity)),
                _Action('TV', Icons.tv_rounded, () => _bills(BillCategory.tv)),

                _Action('More', Icons.grid_view_rounded, () => _more(context)),
              ],
            ),
            ListenableBuilder(
              listenable: recipients,
              builder: (context, _) => recipients.items.isEmpty
                  ? const SizedBox.shrink()
                  : _SendAgain(
                      items: recipients.items,
                      onTap: (r) => _go(
                        r.bankCode == avoraBank
                            ? AmountScreen(
                                person: Person(
                                  tag: r.accountNumber.startsWith('@') ? r.accountNumber.substring(1) : '',
                                  name: r.accountName,
                                  phone: '',
                                ),
                                to: r.accountNumber,
                              )
                            : SendScreen(recipient: r),
                      ),
                    ),
            ),
            if (shell.profile != null && shell.profile!.tag.isEmpty) ...[
              const SizedBox(height: 16),
              _ClaimTag(onTap: () => _go(ProfileScreen(initial: shell.profile))),
            ],
            const SizedBox(height: 16),
            const _PromoCard(),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: Text('Recent activity', style: theme.textTheme.titleMedium)),
                TextButton(onPressed: () => shell.showTab(ShellScreenState.activityTab), child: const Text('See all')),
              ],
            ),
            if (!shell.loading && shell.lines.isEmpty)
              const _Empty()
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(
                    children: [
                      for (final line in shell.lines.take(5))
                        TransactionTile(line: line, onTap: opener(context, line, shell.refresh)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _more(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        Widget tile(String label, IconData icon, VoidCallback onTap) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            Navigator.pop(sheet);
            onTap();
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile('Receive money', Icons.south_west_rounded, () {
                final w = shell.wallet;
                if (w != null) showReceiveSheet(context, w.accountNumber);
              }),
              tile('Request money', Icons.request_page_outlined, () {
                final w = shell.wallet;
                if (w != null) _go(RequestMoneyScreen(accountNumber: w.accountNumber));
              }),
              tile('Scan to pay', Icons.qr_code_scanner_rounded, () => _go(const ScanScreen())),
              tile('Refer and earn', Icons.card_giftcard_rounded, () => _go(const InviteScreen())),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.wallet,
    required this.hidden,
    required this.onToggle,
    required this.onAdd,
    required this.onSend,
  });

  final Wallet wallet;
  final bool hidden;
  final VoidCallback onToggle;
  final VoidCallback onAdd;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final white70 = Colors.white.withValues(alpha: 0.75);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        gradient: Brand.cardGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Brand.green.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: white70),
              const SizedBox(width: 6),
              Text('Available balance', style: theme.textTheme.bodyMedium?.copyWith(color: white70)),
              const SizedBox(width: 4),
              InkWell(
                onTap: onToggle,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                    color: white70,
                    semanticLabel: hidden ? 'Show balance' : 'Hide balance',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              hidden ? '₦ • • • • •' : formatNaira(wallet.balance),
              key: const Key('balance'),
              style: theme.textTheme.displaySmall?.copyWith(color: Colors.white),
            ),
          ),
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: wallet.accountNumber));
              if (context.mounted) showMessage(context, 'Account number copied');
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'TAJBank · ${wallet.accountNumber}',
                    style: theme.textTheme.labelMedium?.copyWith(color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_rounded, size: 14, color: Colors.white),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _CardButton(icon: Icons.add_rounded, label: 'Add money', onTap: onAdd, filled: false),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CardButton(
                  key: const Key('send'),
                  icon: Icons.north_east_rounded,
                  label: 'Send',
                  onTap: onSend,
                  filled: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({super.key, required this.icon, required this.label, required this.onTap, required this.filled});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Brand.deepGreen : Colors.white;
    return Material(
      color: filled ? Brand.lime : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          height: 46,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Action {
  const _Action(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.actions});

  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          childAspectRatio: 0.95,
          children: [
            for (final a in actions)
              InkWell(
                key: Key('action-${a.label.toLowerCase()}'),
                borderRadius: BorderRadius.circular(16),
                onTap: a.onTap,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(a.icon, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 8),
                    Text(a.label, style: theme.textTheme.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ClaimTag extends StatelessWidget {
  const _ClaimTag({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Brand.lime.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: const Key('claim-tag'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.alternate_email_rounded, color: Brand.deepGreen, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Claim your @tag', style: theme.textTheme.titleSmall?.copyWith(color: Brand.deepGreen)),
                    Text(
                      'Get paid free and instantly by anyone on Avora, no account number needed.',
                      style: theme.textTheme.bodySmall?.copyWith(color: Brand.deepGreen),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Brand.deepGreen),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendAgain extends StatelessWidget {
  const _SendAgain({required this.items, required this.onTap});

  final List<Recipient> items;
  final ValueChanged<Recipient> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Send again', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, i) {
                final r = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onTap(r),
                  child: SizedBox(
                    width: 68,
                    child: Column(
                      children: [
                        InitialsAvatar(text: r.accountName, size: 52),
                        const SizedBox(height: 6),
                        Text(
                          r.accountName.split(' ').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium,
                        ),
                        Text(
                          bankName(r.bankCode),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PromoCard extends StatelessWidget {
  const _PromoCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Brand.lime.withValues(alpha: theme.brightness == Brightness.dark ? 0.15 : 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your money never gets lost', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  "If a transfer or bill fails, we refund you automatically, fee included. No calls, no forms.",
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.verified_user_rounded, size: 40, color: theme.colorScheme.primary),
        ],
      ),
    );
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) => Container(
    height: 210,
    decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(24)),
    child: const Center(child: CircularProgressIndicator(color: Colors.white)),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 36),
          const SizedBox(height: 8),
          const Text("We couldn't load your account."),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(Icons.receipt_long_outlined, size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text('No activity yet', style: theme.textTheme.titleSmall),
            Text('Add money to get started.', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
