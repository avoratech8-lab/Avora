import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import '../dates.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Me → Help centre: searchable answers, and a way to chat.
class HelpCentreScreen extends StatefulWidget {
  const HelpCentreScreen({super.key});

  @override
  State<HelpCentreScreen> createState() => _HelpCentreScreenState();
}

class _HelpCentreScreenState extends State<HelpCentreScreen> {
  List<HelpArticle>? _articles;
  Object? _error;
  String _q = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_articles == null && _error == null) {
      AppScope.of(context).api.helpArticles().then(
        (a) {
          if (mounted) setState(() => _articles = a);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _q.toLowerCase();
    final list = (_articles ?? const <HelpArticle>[])
        .where((a) => q.isEmpty || a.title.toLowerCase().contains(q) || a.body.toLowerCase().contains(q))
        .toList();
    final topics = <String, List<HelpArticle>>{};
    for (final a in list) {
      topics.putIfAbsent(a.topic, () => []).add(a);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Help centre')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          TextField(
            key: const Key('help-search'),
            decoration: const InputDecoration(
              hintText: 'Search, e.g. "transfer" or "PIN"',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
          const SizedBox(height: 16),
          if (_articles == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            const Text("We couldn't load the help centre. You can still chat with us.")
          else if (list.isEmpty)
            Text('No answers match "$_q". Chat with us and we\'ll help.', style: theme.textTheme.bodyMedium),
          for (final e in topics.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Text(
                e.key,
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (i, a) in e.value.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    ExpansionTile(
                      key: Key('article-${a.id}'),
                      shape: const Border(),
                      title: Text(a.title, style: theme.textTheme.titleSmall),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [Text(a.body, style: theme.textTheme.bodyMedium)],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(gradient: Brand.cardGradient, borderRadius: BorderRadius.circular(22)),
            child: Row(
              children: [
                const Icon(Icons.support_agent_rounded, color: Brand.lime, size: 32),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Still stuck? Chat with us any time.',
                    style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
                  ),
                ),
                FilledButton(
                  key: const Key('open-chat'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Brand.lime,
                    foregroundColor: Brand.deepGreen,
                    minimumSize: const Size(88, 48),
                  ),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SupportChatScreen())),
                  child: const Text('Chat'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Chat with support. The assistant answers common questions straight
/// away; anything else goes to a person.
class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key});

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<SupportMessage>? _messages;
  bool _sending = false;

  static const _suggestions = ["My transfer hasn't arrived", 'How do I raise my limit?', 'I forgot my PIN'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_messages == null) {
      AppScope.of(context).api.supportMessages().then(
        (m) => _show(m),
        onError: (Object e) {
          if (mounted) setState(() => _messages = const []);
        },
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _show(List<SupportMessage> m) {
    if (!mounted) return;
    setState(() => _messages = m);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send([String? preset]) async {
    final body = (preset ?? _text.text).trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await AppScope.of(context).api.sendSupportMessage(body);
      _text.clear();
      _show(m);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoMark(size: 30),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Avora support', style: theme.textTheme.titleSmall),
                Text('Replies in minutes', style: theme.textTheme.bodySmall?.copyWith(color: Brand.green)),
              ],
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: messages == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      children: [
                        const _Bubble(
                          sender: 'bot',
                          body:
                              "Hi! I'm Avora's assistant. Ask me anything about your account, or type \"agent\" to "
                              'talk to a person. We will never ask for your PIN.',
                        ),
                        for (final m in messages) _Bubble(sender: m.sender, body: m.body, at: m.createdAt),
                        if (messages.isEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final s in _suggestions) ActionChip(label: Text(s), onPressed: () => _send(s)),
                            ],
                          ),
                        ],
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('chat-input'),
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Type a message'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('chat-send'),
                    tooltip: 'Send',
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.sender, required this.body, this.at});

  final String sender;
  final String body;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = sender == 'customer';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: mine ? Brand.green : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sender == 'agent')
              Text('Support team', style: theme.textTheme.labelSmall?.copyWith(color: Brand.green)),
            Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: mine ? Colors.white : null)),
            if (at != null)
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  formatTime(at!),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: mine ? Colors.white70 : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
