import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/nexus_theme.dart';
import '../../theme/nx_widgets.dart';
import '../target.dart';
import 'pairing_flow.dart';

String utilityLabel(String id) => switch (id) {
  UtilityIds.nexuslink => 'NexusLink',
  UtilityIds.remote => 'Nexus Remote',
  UtilityIds.audio => 'Nexus Audio',
  _ => id,
};

IconData _utilityIcon(String id) => switch (id) {
  UtilityIds.nexuslink => Icons.hub_outlined,
  UtilityIds.remote => Icons.mouse_outlined,
  UtilityIds.audio => Icons.headphones_outlined,
  _ => Icons.extension_outlined,
};

/// One row per utility: working / done / failed (with reason and Retry).
/// Pops with the saved target.
class PairingProgressScreen extends StatefulWidget {
  const PairingProgressScreen({
    super.key,
    required this.run,
    this.autoStart = true,
  });
  final PairingRun run;
  final bool autoStart;

  @override
  State<PairingProgressScreen> createState() => _PairingProgressScreenState();
}

class _PairingProgressScreenState extends State<PairingProgressScreen> {
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    widget.run.addListener(_changed);
    if (widget.autoStart) unawaited(widget.run.start());
  }

  @override
  void dispose() {
    widget.run.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (widget.run.allDone && !_popped) {
      _popped = true;
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.of(context).pop(widget.run.target);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final done = run.target != null;
    return Scaffold(
      backgroundColor: NX.bg,
      appBar: AppBar(title: Text('Pairing ${run.bundle.pcName}')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(NX.pad),
                children: [
                  for (final row in run.rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: NX.gap),
                      child: _Row(
                        row: row,
                        onRetry: () => run.retry(row.utility),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(NX.pad),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: run.busy
                      ? null
                      : () => Navigator.of(context).pop(run.target),
                  child: Text(done ? 'Continue' : 'Close'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.onRetry});
  final EnrollProgress row;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (color, status) = switch (row.state) {
      EnrollState.pending => (NX.textFaint, 'Waiting'),
      EnrollState.working => (NX.accent, 'Pairing…'),
      EnrollState.done => (NX.working, 'Paired'),
      EnrollState.failed => (NX.failed, row.message ?? 'Failed'),
      EnrollState.skipped => (NX.textFaint, 'Skipped'),
    };
    return NxCard(
      accent: row.state == EnrollState.failed ? NX.failed : null,
      child: Row(
        children: [
          Icon(_utilityIcon(row.utility), color: NX.textDim),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  utilityLabel(row.utility),
                  style: const TextStyle(
                    color: NX.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(color: color, fontSize: 13.5, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          switch (row.state) {
            EnrollState.working => const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            EnrollState.done => const Icon(
              Icons.check_circle,
              color: NX.working,
            ),
            EnrollState.failed => TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}
