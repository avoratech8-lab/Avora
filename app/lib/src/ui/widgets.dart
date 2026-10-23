import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A full-width primary button that shows a spinner while [loading].
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.loading = false});

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Theme.of(context).colorScheme.primary),
            )
          : Text(label),
    );
  }
}

/// The Avora mark: a rounded square with an "a".
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 56, this.light = false});

  final double size;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: light ? Colors.white : null,
        gradient: light ? null : Brand.cardGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      alignment: Alignment.center,
      child: Text(
        'a',
        style: TextStyle(
          fontFamily: 'Manrope',
          fontSize: size * 0.62,
          height: 1,
          fontWeight: FontWeight.w800,
          fontVariations: const [FontVariation.weight(800)],
          color: light ? Brand.green : Colors.white,
        ),
      ),
    );
  }
}

/// Initials in a soft circle, for banks and people.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({super.key, required this.text, this.size = 44, this.color});

  final String text;
  final double size;
  final Color? color;

  static const _palette = [
    Color(0xFF0B6E4F),
    Color(0xFF2563EB),
    Color(0xFF9333EA),
    Color(0xFFDB2777),
    Color(0xFFEA580C),
    Color(0xFF0891B2),
    Color(0xFF65A30D),
  ];

  static String initials(String s) {
    final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.substring(0, words.first.length.clamp(1, 2)).toUpperCase();
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = color ?? _palette[text.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initials(text),
        style: TextStyle(
          fontFamily: 'Manrope',
          color: c,
          fontSize: size * 0.34,
          fontWeight: FontWeight.w800,
          fontVariations: const [FontVariation.weight(800)],
        ),
      ),
    );
  }
}

/// A 3x4 number pad. [extra] fills the bottom-left key (e.g. "." for
/// amounts), or [extraIcon] does (e.g. a fingerprint).
class NumberPad extends StatelessWidget {
  const NumberPad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.extra,
    this.extraIcon,
    this.onExtra,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final String? extra;
  final IconData? extraIcon;
  final VoidCallback? onExtra;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows) Row(children: [for (final d in row) _key(context, d, () => onDigit(d))]),
        Row(
          children: [
            if (extraIcon != null)
              Expanded(
                child: _Tap(
                  key: const Key('key-extra'),
                  onTap: onExtra,
                  child: Icon(extraIcon, size: 30, color: Theme.of(context).colorScheme.primary),
                ),
              )
            else if (extra != null)
              _key(context, extra!, onExtra)
            else
              const Expanded(child: SizedBox(height: 64)),
            _key(context, '0', () => onDigit('0')),
            Expanded(
              child: _Tap(
                key: const Key('key-back'),
                onTap: onBackspace,
                onLongPress: onBackspace,
                child: Icon(Icons.backspace_outlined, color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _key(BuildContext context, String label, VoidCallback? onTap) => Expanded(
    child: _Tap(
      key: Key('key-$label'),
      onTap: onTap,
      child: Text(label, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
  );
}

class _Tap extends StatelessWidget {
  const _Tap({super.key, required this.onTap, required this.child, this.onLongPress});

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        onLongPress: onLongPress,
        child: SizedBox(height: 60, child: Center(child: child)),
      ),
    );
  }
}

/// Six dots for a PIN. Shakes when [errorTick] changes.
class PinDots extends StatefulWidget {
  const PinDots({super.key, required this.filled, this.length = 6, this.errorTick = 0});

  final int filled;
  final int length;
  final int errorTick;

  @override
  State<PinDots> createState() => _PinDotsState();
}

class _PinDotsState extends State<PinDots> with SingleTickerProviderStateMixin {
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  @override
  void didUpdateWidget(PinDots old) {
    super.didUpdateWidget(old);
    if (widget.errorTick != old.errorTick) _shake.forward(from: 0);
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final t = _shake.value;
        final dx = t == 0 || t == 1 ? 0.0 : 10 * (1 - t) * (((t * 8).floor().isEven) ? 1 : -1);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < widget.length; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 9),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < widget.filled ? scheme.primary : Colors.transparent,
                border: Border.all(color: i < widget.filled ? scheme.primary : scheme.outline, width: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// Six boxes showing a code typed on the [NumberPad].
class CodeBoxes extends StatelessWidget {
  const CodeBoxes({super.key, required this.code, this.length = 6, this.error = false});

  final String code;
  final int length;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        for (var i = 0; i < length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 60,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.inputDecorationTheme.fillColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  width: 1.5,
                  color: error
                      ? Brand.danger
                      : i == code.length
                      ? scheme.primary
                      : Colors.transparent,
                ),
              ),
              child: Text(i < code.length ? code[i] : '', style: theme.textTheme.headlineSmall),
            ),
          ),
        ],
      ],
    );
  }
}

/// Label-value row used on review sheets and receipts.
class DetailRow extends StatelessWidget {
  const DetailRow({super.key, required this.label, required this.value, this.bold = false, this.trailing});

  final String label;
  final String value;
  final bool bold;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: (bold ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)?.copyWith(
                fontWeight: bold ? null : FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
  }
}

/// Explains that a feature is on the way.
void showComingSoon(BuildContext context, String feature, IconData icon) {
  showModalBottomSheet<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: theme.colorScheme.primary, size: 30),
            ),
            const SizedBox(height: 16),
            Text('$feature is coming soon', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              "We're building it now. You'll see it here as soon as it's ready.",
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            PrimaryButton(label: 'Got it', onPressed: () => Navigator.pop(context)),
          ],
        ),
      );
    },
  );
}
