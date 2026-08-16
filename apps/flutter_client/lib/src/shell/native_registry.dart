// Native-vs-stream app registry.
//
// Rule: registered native tool ids open RPC-backed Flutter screens and must
// never start screen capture. Everything else (installed .desktop apps and
// open windows) goes through adopt + pixel stream on MirrorScreen.
//
// Add new remappers here as they ship — do not special-case in the launcher.

import 'package:flutter/material.dart';

import '../screens/files_screen.dart';
import '../screens/mirror_screen.dart';
import '../screens/system_screen.dart';

enum NativeRouteKind {
  /// Pixel-stream the primary monitor (still a stream, but a dock affordance).
  desktopMirror,

  /// Native RPC UI — no capture.
  nativeRpc,
}

class NativeToolEntry {
  final String id;
  final String label;
  final IconData icon;
  final NativeRouteKind kind;

  const NativeToolEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.kind,
  });

  bool get isNativeRpc => kind == NativeRouteKind.nativeRpc;
}

/// Dock tools. Only `nativeRpc` entries skip streaming.
const kNativeTools = <NativeToolEntry>[
  NativeToolEntry(
    id: 'desktop',
    label: 'Desktop',
    icon: Icons.desktop_windows,
    kind: NativeRouteKind.desktopMirror,
  ),
  NativeToolEntry(
    id: 'files',
    label: 'Files',
    icon: Icons.folder,
    kind: NativeRouteKind.nativeRpc,
  ),
  NativeToolEntry(
    id: 'system',
    label: 'System',
    icon: Icons.memory,
    kind: NativeRouteKind.nativeRpc,
  ),
];

bool isRegisteredNativeTool(String id) =>
    kNativeTools.any((t) => t.id == id && t.isNativeRpc);

/// Build the screen for a registered dock tool. Returns null for unknown ids
/// (caller should fall through to MirrorScreen / stream).
Widget? screenForNativeTool(String id) {
  switch (id) {
    case 'files':
      return const FilesScreen();
    case 'system':
      return const SystemScreen();
    case 'desktop':
      return const MirrorScreen(target: MirrorTarget());
    default:
      return null;
  }
}
