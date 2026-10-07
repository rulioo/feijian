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
///
/// [problem] is the other half of that job. The three hints above are all
/// guesses about *the network*; if discovery never managed to start, none of
/// them is the reason and the list cannot fill however well the network is
/// behaving. Reported from a phone, the two situations look identical — an
/// empty screen — so the screen has to be the thing that tells them apart.
class EmptyState extends StatefulWidget {
  const EmptyState({
    required this.onAddByIp,
    required this.onRescan,
    this.problem,
    super.key,
  });

  final VoidCallback onAddByIp;
  final VoidCallback onRescan;

  /// Why discovery is not running, from `discoveryProblemProvider`. Null when it
  /// is running and the network is simply quiet.
  final Object? problem;

  @override
  State<EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<EmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  /// Whether the raw error is on screen. Collapsed by default: it names a port
  /// and an errno, which is noise to most people and the whole answer to
  /// whoever is trying to fix it.
  bool _showDetail = false;

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
    final Object? problem = widget.problem;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 96,
            height: 96,
            child: problem == null
                // Expanding, fading ring — reads as "actively looking" rather
                // than "finished and found nothing". Only while that is true: a
                // list that cannot fill must not animate as though it might.
                ? AnimatedBuilder(
                    animation: _controller,
                    builder: (BuildContext context, Widget? child) {
                      return Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
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
                  )
                : Icon(
                    Icons.wifi_tethering_off,
                    size: 44,
                    color: scheme.error,
                  ),
          ),
          const SizedBox(height: 24),
          Text(
            problem == null ? l10n.scanningTitle : l10n.discoveryFailedTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          // The three hints are all guesses about the network, and they are the
          // wrong guesses when discovery never started. Swapping the card rather
          // than appending to it keeps the screen from arguing with itself.
          if (problem == null)
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
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.4),
                borderRadius: const BorderRadius.all(Radius.circular(12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.discoveryFailedBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => setState(() => _showDetail = !_showDetail),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            _showDetail ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                            color: scheme.onErrorContainer,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            l10n.discoveryFailedDetail,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showDetail)
                    SelectableText(
                      problem.toString(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontFamily: 'monospace',
                      ),
                    ),
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
