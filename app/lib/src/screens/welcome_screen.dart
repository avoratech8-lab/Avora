import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'auth_screens.dart';

/// First thing a signed-out customer sees.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void start() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneScreen()));
    return Scaffold(
      backgroundColor: Brand.deepGreen,
      body: Container(
        decoration: const BoxDecoration(gradient: Brand.cardGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const LogoMark(size: 40, light: true),
                    const SizedBox(width: 10),
                    Text('avora', style: theme.textTheme.titleLarge?.copyWith(color: Colors.white)),
                  ],
                ),
                const Spacer(),
                Text(
                  'Money that\nnever gets lost.',
                  style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, height: 1.1),
                ),
                const SizedBox(height: 16),
                Text(
                  'Send to any bank in seconds. If a transfer fails, you get every kobo back automatically.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                ),
                const SizedBox(height: 32),
                const _Perk(icon: Icons.bolt_rounded, text: '5 free transfers every month'),
                const _Perk(icon: Icons.replay_rounded, text: 'Automatic refunds, fee included'),
                const _Perk(icon: Icons.visibility_rounded, text: 'Every fee shown before you pay'),
                const _Perk(icon: Icons.mosque_outlined, text: 'Non-interest banking with TAJBank'),
                const Spacer(),
                FilledButton(
                  key: const Key('get-started'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.lime, foregroundColor: Brand.deepGreen),
                  onPressed: start,
                  child: const Text('Open a free account'),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size.fromHeight(52)),
                    onPressed: start,
                    child: const Text('I already have an account'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  const _Perk({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: Brand.lime, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
