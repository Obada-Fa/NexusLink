import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/arena/arena_world.dart';
import 'package:nexuslink/src/arena/pixel_art.dart';
import 'package:nexuslink/src/monitor/approvals.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

import 'arena_world_test.dart' show agent, now, NoApprovals;

// Optional review captures, using the same fixtures before and after an art pass:
// flutter test test/arena_graphics_test.dart --dart-define=ARENA_CAPTURE=after
//   --dart-define=ARENA_FONT=/absolute/path/to/Roboto-Regular.ttf
void main() {
  const capture = String.fromEnvironment('ARENA_CAPTURE');
  const fontPath = String.fromEnvironment('ARENA_FONT');
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    if (fontPath.isNotEmpty) {
      final font = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(fontPath).readAsBytes()),
          ),
        );
      await font.load();
    }
  });

  test('character frames keep a consistent silhouette and known palette', () {
    final palette = lookFor(agent('artist')).palette;
    for (final sprite in [front, back, walkA, walkB, typeA, typeB, sit, bot]) {
      for (final row in sprite.rows) {
        expect(row.length, sprite.width, reason: sprite.name);
        expect(
          row
              .split('')
              .every((pixel) => pixel == '.' || palette.containsKey(pixel)),
          isTrue,
        );
      }
    }
    expect(typeA.width, typeB.width);
    expect(typeA.height, typeB.height);
  });

  for (final scene in ['quiet', 'busy', 'night', 'large-text', 'long-titles']) {
    testWidgets('$scene office renders on a narrow phone', (tester) async {
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      final chats = scene == 'quiet'
          ? [agent('a', state: 'done'), agent('b', state: 'idle')]
          : [
              agent('a'),
              agent('b', activity: 'thinking'),
              agent('c', activity: 'reading'),
              agent('d', activity: 'running-command'),
              agent('e', state: 'waiting'),
              agent('f', state: 'failed'),
            ];
      if (scene == 'long-titles') {
        chats.first.json['title'] =
            'Investigate reconnect failures in the mobile client';
        chats.last.json['title'] =
            'Review the workspace synchronization changes';
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [approvalsProvider.overrideWith(NoApprovals.new)],
          child: MaterialApp(
            theme: nexusTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(scene == 'large-text' ? 1.5 : 1),
              ),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: ArenaWorld(
                  chats: chats,
                  offline: false,
                  onOpen: (_) {},
                  now: scene == 'night' ? DateTime(2026, 10, 29, 23) : now,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final arena = tester.state<ArenaWorldState>(find.byType(ArenaWorld));
      expect(arena.world!.agents.length, chats.length);
      expect(tester.takeException(), isNull);
      Future<void> snapshot(String suffix) async {
        if (capture.isEmpty) return;
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await tester.runAsync(
          () => render.toImage(pixelRatio: 2),
        );
        final bytes = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.png),
        );
        await tester.runAsync(() async {
          final file = File('build/arena-review/$capture-$scene$suffix.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
        image!.dispose();
      }

      await snapshot('');
      arena.focusAgent('a');
      await tester.pump();
      await snapshot('-detail');
      // With reduced motion, advancing time must not change the rendered scene.
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final first = await tester.runAsync(() => render.toImage());
      final firstBytes = await tester.runAsync(() => first!.toByteData());
      await tester.pump(const Duration(seconds: 2));
      final second = await tester.runAsync(() => render.toImage());
      final secondBytes = await tester.runAsync(() => second!.toByteData());
      expect(
        secondBytes!.buffer.asUint8List(),
        firstBytes!.buffer.asUint8List(),
      );
      first!.dispose();
      second!.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
