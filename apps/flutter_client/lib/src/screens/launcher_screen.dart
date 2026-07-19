// Home launcher — the "mobile OS" face of NexusLink. Port of the PWA home
// (apps/mobile-client/src/app/page.tsx): running-windows row + searchable app
// grid with real icons + a tools dock. Tapping an app opens the mirror route.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../widgets/app_icon.dart';
import 'files_screen.dart';
import 'mirror_screen.dart';
import 'system_screen.dart';

class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  String _search = '';

  void _openWindow(WindowInfo w, List<AppInfo> apps) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MirrorScreen(
        target: MirrorTarget(windowId: w.windowId, title: bestWindowName(w, apps)),
      ),
    ));
  }

  void _launchApp(AppInfo a, List<WindowInfo> windows) {
    // Already running → jump into its window instead of launching a second copy.
    for (final w in windows) {
      if (windowMatchesApp(w, a)) {
        _openWindow(w, ref.read(appsProvider).value ?? []);
        return;
      }
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MirrorScreen(
        target: MirrorTarget(appId: a.appId, wmClass: a.wmClass, title: a.name),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final windowsAsync = ref.watch(windowsProvider);
    final appsAsync = ref.watch(appsProvider);
    final windows = windowsAsync.value ?? [];
    final apps = appsAsync.value ?? [];
    final q = _search.trim().toLowerCase();
    final filteredApps = q.isEmpty
        ? apps
        : apps.where((a) => a.name.toLowerCase().contains(q)).toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _header(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  if (windows.isNotEmpty && q.isEmpty) ...[
                    _sectionTitle('Open on your PC'),
                    _runningRow(windows, apps),
                    const SizedBox(height: 12),
                  ],
                  _appsHeader(),
                  if (appsAsync.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else
                    _appGrid(filteredApps, windows),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _dock(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final host = ref.watch(connectionProvider).hostUrl ?? '';
    final label = Uri.tryParse(host)?.host ?? 'PC';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.circle, size: 8, color: Color(0xFF4ADE80)),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500))),
          IconButton(
            icon: const Icon(Icons.power_settings_new, size: 18),
            onPressed: () {
              ref.read(connectionProvider.notifier).disconnect();
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 0, 8),
        child: Text(s.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.4))),
      );

  Widget _runningRow(List<WindowInfo> windows, List<AppInfo> apps) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: windows.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final w = windows[i];
          final name = bestWindowName(w, apps);
          return InkWell(
            onTap: () => _openWindow(w, apps),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 140,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF151522),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF22223A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIconTile(icon: w.icon, name: name, size: 40),
                  const SizedBox(height: 6),
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  Text(w.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withValues(alpha: 0.35))),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _appsHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _sectionTitle('Apps'),
          const Spacer(),
          SizedBox(
            width: 180,
            height: 38,
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search apps…',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appGrid(List<AppInfo> apps, List<WindowInfo> windows) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 88,
        mainAxisSpacing: 14,
        crossAxisSpacing: 8,
        childAspectRatio: 0.78,
      ),
      itemCount: apps.length,
      itemBuilder: (_, i) {
        final a = apps[i];
        final running = windows.any((w) => windowMatchesApp(w, a));
        return InkWell(
          onTap: () => _launchApp(a, windows),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AppIconTile(icon: a.icon, name: a.name),
                  if (running)
                    const Positioned(
                      bottom: -3,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Icon(Icons.circle,
                            size: 5, color: Color(0xFF4ADE80)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.75))),
            ],
          ),
        );
      },
    );
  }

  Widget _dock(BuildContext context) {
    void push(Widget screen) => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
    final items = <(IconData, String, VoidCallback?)>[
      (Icons.desktop_windows, 'Desktop', () => _openDesktop(context)),
      (Icons.folder, 'Files', () => push(const FilesScreen())),
      (Icons.memory, 'System', () => push(const SystemScreen())),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF12121C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF1E1E30)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: items
            .map((it) => InkWell(
                  onTap: it.$3,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(it.$1,
                            size: 20,
                            color: it.$3 == null
                                ? Colors.white.withValues(alpha: 0.25)
                                : Colors.white.withValues(alpha: 0.75)),
                        const SizedBox(height: 3),
                        Text(it.$2,
                            style: TextStyle(
                                fontSize: 9.5,
                                color: Colors.white.withValues(alpha: 0.4))),
                      ],
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  void _openDesktop(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const MirrorScreen(target: MirrorTarget()),
    ));
  }
}
