import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';

/// Shown when discovery finds nothing — design.md §6.2.
///
/// This is the single most likely first-run experience, so it does real work:
/// it names the three causes in the order they actually occur (peer not
/// running → wrong network → firewall) instead of just saying "no devices".
/// AP isolation silently breaks discovery too, which is why the manual
/// add-by-IP escape hatch sits right here.
class EmptyState extends StatefulWidget {
  const EmptyState({
    required this.onAddByIp,
    required this.onRescan,
    super.key,
  });

  final VoidCallback onAddByIp;
  final VoidCallback onRescan;

  @override
  State<EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<EmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 96,
            height: 96,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                return Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    // Expanding, fading ring — reads as "actively looking"
                    // rather than "finished and found nothing".
                    Transform.scale(
                      scale: 0.6 + (_controller.value * 0.6),
                      child: Opacity(
                        opacity: (1 - _controller.value) * 0.35,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.wifi_tethering,
                      size: 44,
                      color: scheme.primary,
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l10n.scanningTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: const BorderRadius.all(Radius.circular(12)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  l10n.scanningHintIntro,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                _Hint(text: l10n.scanningHintRunning),
                _Hint(text: l10n.scanningHintSameNetwork),
                _Hint(text: l10n.scanningHintFirewall(kDiscoveryPort)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: widget.onAddByIp,
                icon: const Icon(Icons.add),
                label: Text(l10n.addDeviceByIp),
              ),
              OutlinedButton.icon(
                onPressed: widget.onRescan,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.rescan),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
