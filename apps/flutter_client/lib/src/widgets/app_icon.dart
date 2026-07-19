// Renders an app/window icon from a host-provided data: URI (png/svg base64),
// falling back to a colored monogram tile. SVG data URIs are not decoded by
// Image.memory, so those also fall back to the monogram (acceptable — most
// Linux app icons resolve to PNG host-side).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class AppIconTile extends StatelessWidget {
  const AppIconTile({super.key, this.icon, required this.name, this.size = 52});

  final String? icon;
  final String name;
  final double size;

  Uint8List? _decodePng(String uri) {
    // data:image/png;base64,XXXX — only raster is decodable by Image.memory.
    final match = RegExp(r'^data:image/(png|jpeg);base64,(.*)$').firstMatch(uri);
    if (match == null) return null;
    try {
      return base64Decode(match.group(2)!);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = icon == null ? null : _decodePng(icon!);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(bytes,
            width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true),
      );
    }
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final hue = (name.isEmpty ? 0 : name.codeUnitAt(0) * 47) % 360;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.38).toColor(),
            HSLColor.fromAHSL(1, ((hue + 40) % 360).toDouble(), 0.5, 0.26)
                .toColor(),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(letter,
          style: TextStyle(
              fontSize: size * 0.45,
              fontWeight: FontWeight.w700,
              color: Colors.white)),
    );
  }
}
