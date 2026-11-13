// Shown in place of a widget that failed to build, instead of Flutter's red
// (debug) or blank grey (release) panel.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/nexus_theme.dart';

/// Bumped by Reload; the app root rebuilds its ProviderScope when it changes,
/// which re-creates every provider and screen.
final appReloadGeneration = ValueNotifier<int>(0);

class AppErrorView extends StatelessWidget {
  const AppErrorView({super.key, this.details});

  final String? details;

  factory AppErrorView.fromDetails(FlutterErrorDetails error) {
    if (!kDebugMode) return const AppErrorView();
    final text = error.exceptionAsString();
    return AppErrorView(
      details: text.length > 300 ? '${text.substring(0, 300)}…' : text,
    );
  }

  // This can appear above MaterialApp or inside a small tile, so it needs no
  // inherited widgets and scales down rather than overflowing.
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: NX.bg,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: NX.waiting,
                    size: 32,
                    textDirection: TextDirection.ltr,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This part of the app hit a problem',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NX.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Your PC and agents are not affected. Reload the app to try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NX.textDim,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  if (details != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      details!,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: NX.textDim,
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Semantics(
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => appReloadGeneration.value++,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        decoration: BoxDecoration(
                          color: NX.surface3,
                          borderRadius: BorderRadius.circular(NX.radiusSm),
                        ),
                        child: const Text(
                          'Reload',
                          style: TextStyle(
                            color: NX.accent,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
