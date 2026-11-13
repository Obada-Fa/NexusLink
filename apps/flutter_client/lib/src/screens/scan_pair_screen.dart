import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../auth/pair_bundle.dart';
import '../theme/nexus_theme.dart';

/// What [ScanPairScreen] pops (with `returnBundle`) when the user chooses to
/// type the code instead; backing out pops null.
enum ScanChoice { manual }

/// Scans the pairing QR code shown by Nexus Utilities → Add phone.
///
/// Legacy mode (default): pops a [NexusLinkPairing], or null when the user
/// backs out or chooses to type the code instead.
/// With [returnBundle]: pops the whole [PairBundle], [ScanChoice.manual] for
/// "type it instead", or null when the user backs out.
class ScanPairScreen extends StatefulWidget {
  const ScanPairScreen({super.key, this.returnBundle = false});
  final bool returnBundle;

  @override
  State<ScanPairScreen> createState() => _ScanPairScreenState();
}

enum _Camera { asking, granted, denied, blocked }

class _ScanPairScreenState extends State<ScanPairScreen>
    with WidgetsBindingObserver {
  _Camera _camera = _Camera.asking;
  MobileScannerController? _controller;
  String? _problem;
  String? _lastRejected;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _askCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // Coming back from system Settings: re-check without prompting again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (_camera == _Camera.denied || _camera == _Camera.blocked)) {
      Permission.camera.status.then((s) {
        if (mounted && s.isGranted) _grant();
      });
    }
  }

  Future<void> _askCamera() async {
    setState(() => _camera = _Camera.asking);
    var status = await Permission.camera.status;
    if (!status.isGranted) status = await Permission.camera.request();
    if (!mounted) return;
    if (status.isGranted || status.isLimited) {
      _grant();
    } else {
      setState(
        () => _camera = status.isPermanentlyDenied || status.isRestricted
            ? _Camera.blocked
            : _Camera.denied,
      );
    }
  }

  void _grant() {
    _controller ??= MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
    );
    setState(() => _camera = _Camera.granted);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null || text.isEmpty) continue;
      if (text == _lastRejected) return; // same bad code still in view
      if (!isPairBundle(text)) {
        _reject(
          text,
          'That QR code isn’t from Nexus Utilities. Scan the one under '
          'Add phone on your PC.',
        );
        return;
      }
      try {
        final bundle = parsePairBundle(text);
        final Object pairing = widget.returnBundle ? bundle : bundle.nexusLink;
        _done = true;
        HapticFeedback.mediumImpact();
        _controller?.stop();
        Navigator.of(context).pop(pairing);
      } on PairBundleException catch (e) {
        _reject(text, e.message);
      }
      return;
    }
  }

  void _typeInstead() =>
      Navigator.of(context).pop(widget.returnBundle ? ScanChoice.manual : null);

  void _reject(String text, String message) {
    HapticFeedback.lightImpact();
    setState(() {
      _lastRejected = text;
      _problem = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan pairing code'),
        actions: [
          if (_camera == _Camera.granted && _controller != null)
            ValueListenableBuilder(
              valueListenable: _controller!,
              builder: (context, state, _) {
                if (state.torchState == TorchState.unavailable) {
                  return const SizedBox.shrink();
                }
                final on = state.torchState == TorchState.on;
                return IconButton(
                  tooltip: on ? 'Turn light off' : 'Turn light on',
                  icon: Icon(on ? Icons.flash_on : Icons.flash_off),
                  onPressed: _controller!.toggleTorch,
                );
              },
            ),
        ],
      ),
      body: switch (_camera) {
        _Camera.asking => const Center(
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        _Camera.granted => _scanner(),
        _Camera.denied || _Camera.blocked => _permissionHelp(),
      },
    );
  }

  Widget _scanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => _cameraError(error),
        ),
        const _Viewfinder(),
        Positioned(
          left: 20,
          right: 20,
          bottom: 24,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_problem != null)
                  _Banner(text: _problem!, color: NX.failed)
                else
                  const _Banner(
                    text:
                        'On your PC open Nexus Utilities → Add phone, '
                        'then point the camera at the QR code.',
                    color: NX.accent,
                  ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _typeInstead,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Type the address and code instead'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _cameraError(MobileScannerException error) {
    if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _camera = _Camera.denied);
      });
      return const SizedBox.shrink();
    }
    return _Message(
      icon: Icons.no_photography_outlined,
      title: 'The camera didn’t start',
      body:
          error.errorDetails?.message ??
          'Another app may be using it. Close it and try again.',
      primary: (
        'Try again',
        () {
          _controller?.dispose();
          _controller = null;
          _grant();
        },
      ),
      secondary: ('Type it instead', _typeInstead),
    );
  }

  Widget _permissionHelp() {
    final blocked = _camera == _Camera.blocked;
    return _Message(
      icon: Icons.photo_camera_outlined,
      title: 'Allow the camera to scan',
      body: blocked
          ? 'Camera access is turned off for Nexus. Open Settings → '
                'Permissions → Camera and choose Allow. Nexus only uses '
                'it to read the pairing code.'
          : 'Nexus uses the camera only to read the pairing code on '
                'your PC. Nothing is recorded.',
      primary: blocked
          ? ('Open Settings', () => openAppSettings())
          : ('Allow camera', _askCamera),
      secondary: ('Type it instead', _typeInstead),
    );
  }
}

class _Viewfinder extends StatelessWidget {
  const _Viewfinder();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final side = (c.biggest.shortestSide * .72).clamp(200.0, 340.0);
          return Center(
            child: Container(
              width: side,
              height: side,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  // Dims everything outside the frame.
                  BoxShadow(color: Color(0x99000000), spreadRadius: 2000),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: NX.surface.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(NX.radiusSm),
          border: Border.all(color: color.withValues(alpha: .6)),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NX.text, fontSize: 14.5, height: 1.35),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.primary,
    required this.secondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback) primary;
  final (String, VoidCallback) secondary;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: NX.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, size: 56, color: NX.accent),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: NX.text,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NX.textDim, height: 1.4),
              ),
              const SizedBox(height: 26),
              FilledButton(onPressed: primary.$2, child: Text(primary.$1)),
              const SizedBox(height: 8),
              TextButton(onPressed: secondary.$2, child: Text(secondary.$1)),
            ],
          ),
        ),
      ),
    );
  }
}
