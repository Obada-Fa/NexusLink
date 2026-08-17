// Full-screen "not connected" state with a one-tap reconnect to the last PC.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/connection.dart';
import '../state/last_host.dart';

bool looksLikeConnectionError(String? message) {
  if (message == null || message.isEmpty) return false;
  final m = message.toLowerCase();
  return m.contains('not connected') ||
      m.contains('connection closed') ||
      m.contains('disconnected');
}

class NotConnectedView extends ConsumerStatefulWidget {
  final String message;
  final VoidCallback? onReconnected;

  const NotConnectedView({
    super.key,
    this.message = 'Not connected to the PC.',
    this.onReconnected,
  });

  @override
  ConsumerState<NotConnectedView> createState() => _NotConnectedViewState();
}

class _NotConnectedViewState extends ConsumerState<NotConnectedView> {
  bool _busy = false;
  String? _error;

  Future<void> _reconnect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(connectionProvider.notifier).reconnect();
      if (!mounted) return;
      widget.onReconnected?.call();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(connectionProvider).hostUrl;
    final hostLabel = host != null && host.isNotEmpty ? lastHostLabel(host) : null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off, size: 40, color: Colors.white.withValues(alpha: 0.45)),
            const SizedBox(height: 16),
            Text(
              widget.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            if (hostLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                hostLabel,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _reconnect,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_busy ? 'Reconnecting…' : 'Reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
