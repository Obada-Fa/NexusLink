// Connect-screen update card: check GitHub Releases, download APK, open installer.
// Works without the LAN host — only needs internet to GitHub.

import 'package:flutter/material.dart';

import '../updates/app_update.dart';

class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, this.service});

  final AppUpdateService? service;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  late final AppUpdateService _service =
      widget.service ?? AppUpdateService();

  UpdateCheckResult? _result;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String? _status;

  @override
  void initState() {
    super.initState();
    // Quiet check on open — don't block the connect UI.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check(silent: true));
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking || _downloading) return;
    setState(() {
      _checking = true;
      if (!silent) _status = 'Checking GitHub for updates…';
    });
    final result = await _service.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
      switch (result.kind) {
        case UpdateCheckResultKind.available:
          _status =
              'Update ${result.update!.version} available (you have ${result.installed}).';
        case UpdateCheckResultKind.upToDate:
          _status = silent ? null : 'You are on the latest version (${result.installed}).';
        case UpdateCheckResultKind.noRelease:
          _status = silent
              ? null
              : (result.error ?? 'No APK release published yet.');
        case UpdateCheckResultKind.error:
          _status = silent ? null : (result.error ?? 'Update check failed.');
      }
    });
  }

  Future<void> _downloadAndInstall() async {
    final update = _result?.update;
    if (update == null || _downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _status = 'Downloading ${update.apkName}…';
    });
    try {
      final file = await _service.downloadApk(
        update,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Opening installer…');
      final ok = await _service.installApk(file);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = ok
            ? 'Installer opened — allow installs from NexusLink if prompted.'
            : 'Could not open the installer. Enable “Install unknown apps” for NexusLink in Android settings, then try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = 'Download failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = _result?.kind == UpdateCheckResultKind.available;
    return Card(
      color: available
          ? const Color(0xFF152238)
          : Colors.white.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  available ? Icons.system_update : Icons.system_update_alt,
                  size: 18,
                  color: available
                      ? const Color(0xFF2A6AFF)
                      : Colors.white54,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('App updates',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (_checking)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    onPressed: _downloading ? null : () => _check(silent: false),
                    child: const Text('Check'),
                  ),
              ],
            ),
            Text(
              'Downloads the latest APK from GitHub Releases — no PC host needed.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: const TextStyle(fontSize: 13)),
            ],
            if (_downloading) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 4),
              Text('${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.5))),
            ],
            if (available && !_downloading) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _downloadAndInstall,
                icon: const Icon(Icons.download),
                label: Text('Download & install ${_result!.update!.version}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
