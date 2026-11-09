// Phone-sized PNG captures of the Desktop update with real fonts, for visual
// review. Skipped unless CAPTURE_DIR is set:
//   CAPTURE_DIR=/tmp/caps flutter test test/capture/desktop_capture_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/monitor/monitor_provider.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pc_tab_test.dart'
    show FakeMonitor, pumpPcTab, settle, historyFixture, openMenu;

final _dir = Platform.environment['CAPTURE_DIR'];

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final flutter = File(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.parent.path;
  final material = '$flutter/bin/cache/artifacts/material_fonts';
  await _font('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold', 'Black'])
      '$material/Roboto-$w.ttf',
  ]);
  await _font('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await _font('monospace', [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
  ]);
}

/// A brief CPU spike 2 minutes ago with the temperature rise that follows,
/// at irregular push intervals, plus simultaneous upload and download.
MonitorHistory spikeHistory() {
  final end = DateTime.now().millisecondsSinceEpoch;
  final base = historyFixture();
  final series = Map<String, List<Sample>>.from(base.series);
  final cpu = <Sample>[], temp = <Sample>[], rx = <Sample>[], tx = <Sample>[];
  var t = end - 300000;
  var i = 0;
  while (t <= end) {
    final ago = end - t;
    final spike = ago > 118000 && ago < 126000;
    final warm = ago <= 118000 && ago > 70000
        ? 61 + 20 * (1 - (118000 - ago) / 48000)
        : ago > 70000 && ago < 126000
        ? 64.0
        : 57.0 + (i % 3);
    cpu.add(Sample(t, spike ? 97 : 8 + (i % 5).toDouble()));
    temp.add(Sample(t, warm));
    rx.add(Sample(t, ago < 90000 ? 4.2e6 + (i % 4) * 2e5 : 3e4));
    tx.add(Sample(t, ago < 90000 ? 1.1e6 + (i % 3) * 1e5 : 1e4));
    t += i.isEven ? 1700 : 2600; // irregular pushes
    i++;
  }
  cpu.add(Sample(end, 42.4));
  rx.add(Sample(end, 11040));
  tx.add(Sample(end, 46504));
  temp.add(Sample(end, 61.2));
  series['cpu'] = cpu;
  series['cpuTemp'] = temp;
  series['netRx'] = rx;
  series['netTx'] = tx;
  return MonitorHistory(series);
}

final _apps = [
  AppInfo(appId: 'firefox', name: 'Firefox', wmClass: 'firefox'),
  AppInfo(appId: 'code', name: 'Visual Studio Code', wmClass: 'code'),
  AppInfo(appId: 'org.gnome.Nautilus', name: 'Files'),
  AppInfo(appId: 'claude-desktop', name: 'Claude'),
  AppInfo(appId: 'nexus.chrome', name: 'Chrome'),
];

final _windows = [
  WindowInfo(
    windowId: 'w1',
    title: 'Inbox — Mozilla Firefox',
    wmClass: 'Navigator.firefox',
    desktop: 0,
  ),
  WindowInfo(
    windowId: 'w2',
    title: 'Docs — Mozilla Firefox',
    wmClass: 'Navigator.firefox',
    desktop: 0,
  ),
  WindowInfo(
    windowId: 'w3',
    title: 'launcher_screen.dart — NexusLink',
    wmClass: 'code',
    desktop: 0,
    appId: 'code',
  ),
  WindowInfo(
    windowId: '0x00e00004',
    title: 'Claude',
    wmClass: 'Claude',
    desktop: 0,
    appId: 'claude-desktop',
  ),
  WindowInfo(windowId: 'w9', title: 'scratch.txt', wmClass: '', desktop: 0),
];

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await settle(tester, 4);
}

void main() {
  final key = GlobalKey();

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester, 6);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  setUpAll(() async {
    if (_dir != null) await _loadFonts();
  });

  for (final scale in [1.0, 2.0]) {
    final tag = scale == 1 ? '1x' : '2x';
    testWidgets('capture $tag', (tester) async {
      SharedPreferences.setMockInitialValues({
        'nexuslink-launcher:ws://192.168.2.30:45678':
            '{"favourites":["firefox","code","org.gnome.Nautilus","claude-desktop"],"usage":{},"recent":[],"removedDefaults":[]}',
      });
      await pumpPcTab(
        tester,
        FakeMonitor(history: spikeHistory()),
        textScale: scale,
        apps: _apps,
        windows: _windows,
        boundary: key,
      );
      await shot(tester, '$tag-01-desktop');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await shot(tester, '$tag-02-desktop-scrolled');
      await openTab(tester, 'Running');
      await shot(tester, '$tag-03-running');
      await openTab(tester, 'Apps');
      await shot(tester, '$tag-04-apps');
      await openTab(tester, 'Desktop');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
      await settle(tester, 4);
      await tester.tap(find.bySemanticsLabel(RegExp('^CPU 42 percent')));
      await shot(tester, '$tag-05-monitor-cpu');
      for (final (tab, name) in [
        ('GPU', 'gpu'),
        ('Memory', 'memory'),
        ('Network & disk', 'io'),
      ]) {
        final tabLabel = find.text(tab).last;
        await tester.ensureVisible(tabLabel);
        await settle(tester);
        await tester.tap(tabLabel);
        await settle(tester, 6);
        expect(
          find.byKey(PageStorageKey('monitor-$name')).hitTestable(),
          findsOneWidget,
        );
        await shot(tester, '$tag-06-monitor-$name');
      }
      await tester.pageBack();
      await settle(tester);
      await openTab(tester, 'Running');
      await tester.tap(find.byKey(const ValueKey('running-firefox')));
      await shot(tester, '$tag-07-choose-window');
      await tester.tapAt(const Offset(200, 100));
      await settle(tester);
      await openMenu(tester, 'Claude');
      await shot(tester, '$tag-08-app-menu');
      await tester.tap(find.text('App info'));
      await shot(tester, '$tag-09-app-info');
    }, skip: _dir == null);
  }
}
