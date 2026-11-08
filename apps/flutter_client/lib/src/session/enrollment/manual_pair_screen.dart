import 'package:flutter/material.dart';

import '../../auth/pair_bundle.dart';
import '../../state/last_host.dart';
import '../../theme/nexus_theme.dart';
import '../target.dart';
import 'pairing_progress_screen.dart' show utilityLabel;

const _remotePort = 45679;
const _audioPort = 8010;

/// "host", "host:port" or "[v6]:port" → (host, port?).
(String, int?) splitHostPort(String input) {
  final s = input.trim();
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end > 0) {
      final rest = s.substring(end + 1);
      return (
        s.substring(1, end),
        rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null,
      );
    }
  }
  final first = s.indexOf(':');
  if (first >= 0 && first == s.lastIndexOf(':')) {
    final port = int.tryParse(s.substring(first + 1));
    if (port != null) return (s.substring(0, first), port);
  }
  return (s, null);
}

/// Typed pairing for PCs without a camera. Pops with a one-utility
/// [PairBundle] that the progress screen then enrolls.
class ManualPairScreen extends StatefulWidget {
  const ManualPairScreen({super.key});

  @override
  State<ManualPairScreen> createState() => _ManualPairScreenState();
}

class _ManualPairScreenState extends State<ManualPairScreen> {
  String _utility = UtilityIds.nexuslink;
  final _address = TextEditingController();
  final _code = TextEditingController();
  final _fingerprint = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _fingerprint.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim();
    if (_address.text.trim().isEmpty || code.isEmpty) {
      setState(() => _error = 'Enter the address and the code from your PC.');
      return;
    }
    final String host;
    final int port;
    final String hubId;
    if (_utility == UtilityIds.nexuslink) {
      final ws = Uri.tryParse(normalizeHostWsUrl(_address.text));
      if (ws == null || ws.host.isEmpty) {
        setState(() => _error = 'That address doesn’t look right.');
        return;
      }
      host = ws.host;
      port = ws.port;
      hubId = 'legacy:${normalizeHostWsUrl(_address.text)}';
    } else {
      final (h, p) = splitHostPort(_address.text);
      if (h.isEmpty) {
        setState(() => _error = 'That address doesn’t look right.');
        return;
      }
      host = h;
      port = p ?? (_utility == UtilityIds.remote ? _remotePort : _audioPort);
      hubId = 'manual:$host';
    }
    final fp = _fingerprint.text.trim();
    Navigator.of(context).pop(
      PairBundle(
        hubId: hubId,
        pcName: host,
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        addresses: TargetAddresses(lan: [host]),
        utilities: {
          _utility: BundleEntry(
            utility: _utility,
            port: port,
            code: code,
            fingerprint: _utility == UtilityIds.remote && fp.isNotEmpty
                ? fp
                : null,
          ),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nl = _utility == UtilityIds.nexuslink;
    return Scaffold(
      backgroundColor: NX.bg,
      appBar: AppBar(title: const Text('Pair manually')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(NX.pad),
          children: [
            SegmentedButton<String>(
              segments: [
                for (final u in UtilityIds.all)
                  ButtonSegment(value: u, label: Text(utilityLabel(u))),
              ],
              selected: {_utility},
              onSelectionChanged: (s) => setState(() {
                _utility = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: nl ? 'Address (ws://host:45678/rpc)' : 'Address',
                hintText: nl ? '100.64.0.5:45678' : '100.64.0.5',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Pairing code'),
            ),
            if (_utility == UtilityIds.remote) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _fingerprint,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Fingerprint (optional)',
                  helperText:
                      'Leave empty to trust the certificate the PC presents.',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: NX.failed)),
            ],
            const SizedBox(height: 20),
            FilledButton(onPressed: _submit, child: const Text('Pair')),
          ],
        ),
      ),
    );
  }
}
