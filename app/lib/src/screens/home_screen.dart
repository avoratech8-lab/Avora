import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../money.dart';
import 'send_screen.dart';
import 'transfer_screen.dart';

/// Balance, account number and recent activity.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Wallet? _wallet;
  List<StatementLine> _lines = const [];
  bool _loading = true;
  bool _hideBalance = false;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wallet == null && _error == null) _refresh();
  }

  Future<void> _refresh() async {
    final api = AppScope.of(context).api;
    try {
      final results = await Future.wait([api.wallet(), api.statement()]);
      if (!mounted) return;
      setState(() {
        _wallet = results[0] as Wallet;
        _lines = results[1] as List<StatementLine>;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _send() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SendScreen()));
    if (mounted) _refresh();
  }

  Future<void> _open(StatementLine line) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TransferScreen(transferId: line.ref)));
    if (mounted) _refresh();
  }

  void _receive() {
    final w = _wallet;
    if (w == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _ReceiveSheet(accountNumber: w.accountNumber),
    );
  }

  Future<void> _logout() async {
    try {
      await AppScope.of(context).api.logout();
    } catch (_) {
      // The token is cleared locally either way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Avora'),
        actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: _logout)],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_wallet == null)
              _ErrorCard(error: _error, onRetry: _refresh)
            else ...[
              _BalanceCard(
                wallet: _wallet!,
                hidden: _hideBalance,
                onToggle: () => setState(() => _hideBalance = !_hideBalance),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('send'),
                      onPressed: _send,
                      icon: const Icon(Icons.north_east),
                      label: const Text('Send'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _receive,
                      icon: const Icon(Icons.south_west),
                      label: const Text('Receive'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text('Recent activity', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_lines.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No activity yet.')),
                )
              else
                for (final line in _lines) _ActivityTile(line: line, onTap: line.isTransfer ? () => _open(line) : null),
            ],
          ],
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.wallet, required this.hidden, required this.onToggle});

  final Wallet wallet;
  final bool hidden;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = theme.colorScheme.onPrimary;
    return Card(
      color: theme.colorScheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Available balance', style: TextStyle(color: on)),
                IconButton(
                  tooltip: hidden ? 'Show balance' : 'Hide balance',
                  onPressed: onToggle,
                  icon: Icon(hidden ? Icons.visibility_off : Icons.visibility, color: on, size: 20),
                ),
              ],
            ),
            Text(
              hidden ? '₦ ••••••' : formatNaira(wallet.balance),
              key: const Key('balance'),
              style: theme.textTheme.headlineMedium?.copyWith(color: on, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text('Account number ${wallet.accountNumber}', style: TextStyle(color: on)),
          ],
        ),
      ),
    );
  }
}

class _ReceiveSheet extends StatelessWidget {
  const _ReceiveSheet({required this.accountNumber});

  final String accountNumber;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Receive money', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Anyone can send to this account number from any Nigerian bank app.'),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: SelectableText(accountNumber, style: theme.textTheme.headlineSmall)),
              FilledButton.tonalIcon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: accountNumber));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account number copied')));
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Bank: TAJBank (partner bank)'),
        ],
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.line, this.onTap});

  final StatementLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incoming = line.amount > 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: incoming ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
        child: Icon(incoming ? Icons.south_west : Icons.north_east, size: 20),
      ),
      title: Text(line.description, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(formatWhen(line.at)),
      trailing: Text(
        '${incoming ? '+' : ''}${formatNaira(line.amount)}',
        style: TextStyle(fontWeight: FontWeight.w600, color: incoming ? theme.colorScheme.primary : null),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Text("We couldn't load your account."),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
