// Optional extras a module can offer the shell beyond the §4 contract.
// Modules that don't implement them get sensible defaults.

import 'package:flutter/material.dart';

import '../theme/nexus_theme.dart';
import 'module.dart';

/// A one-line description under the tile title and a brand colour for its
/// icon badge.
abstract interface class DescribedModule {
  String get subtitle;
  Color get accent;
}

String moduleSubtitle(NexusModule module) =>
    module is DescribedModule ? (module as DescribedModule).subtitle : '';

Color moduleAccent(NexusModule module) =>
    module is DescribedModule ? (module as DescribedModule).accent : NX.accent;
