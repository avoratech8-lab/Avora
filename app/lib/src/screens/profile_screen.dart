import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api.dart';
import '../api/models.dart';
import '../app.dart';
import '../ui/widgets.dart';

/// Me → Personal details: the name people see and your @tag.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.initial});

  final Profile? initial;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController();
  final _tag = TextEditingController();
  Profile? _p;
  bool _saving = false;
  String? _tagError;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    if (p != null) _fill(p);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_p == null) {
      AppScope.of(context).api.profile().then((p) {
        if (mounted) setState(() => _fill(p));
      }, onError: (_) {});
    }
  }

  void _fill(Profile p) {
    _p = p;
    _name.text = p.name;
    _tag.text = p.tag;
  }

  @override
  void dispose() {
    _name.dispose();
    _tag.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _tagError = null;
      _nameError = null;
    });
    try {
      final p = await AppScope.of(context).api.updateProfile(name: _name.text, tag: _tag.text);
      if (!mounted) return;
      setState(() => _fill(p));
      showMessage(context, 'Saved');
      Navigator.of(context).pop(p);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.message.toLowerCase().contains('name')) {
          _nameError = e.message;
        } else {
          _tagError = e.message;
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _p;
    return Scaffold(
      appBar: AppBar(title: const Text('Personal details')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            Center(child: InitialsAvatar(text: _name.text.isEmpty ? '?' : _name.text, size: 80)),
            const SizedBox(height: 24),
            TextField(
              key: const Key('profile-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: InputDecoration(labelText: 'Your name', errorText: _nameError, counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('profile-tag'),
              controller: _tag,
              autocorrect: false,
              maxLength: 20,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toLowerCase())),
              ],
              decoration: InputDecoration(
                labelText: 'Avora tag',
                prefixText: '@',
                errorText: _tagError,
                helperText: 'Friends pay you free and instantly with your tag.',
                counterText: '',
              ),
            ),
            const SizedBox(height: 20),
            if (p != null) ...[
              DetailRow(label: 'Phone', value: p.phone),
              DetailRow(label: 'Account number', value: p.accountNumber),
              const DetailRow(label: 'Bank', value: 'TAJBank'),
            ],
            const SizedBox(height: 24),
            PrimaryButton(
              key: const Key('profile-save'),
              label: 'Save',
              loading: _saving,
              onPressed: _saving ? null : _save,
            ),
            const SizedBox(height: 12),
            Text(
              'Your full legal name comes from your BVN or NIN when you verify, and is what banks see.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
