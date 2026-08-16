// Home launcher — the "mobile OS" face of NexusLink. Port of the PWA home
// (apps/mobile-client/src/app/page.tsx): running-windows row + searchable app
// grid with real icons + a tools dock. Tapping an app opens the mirror route.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/models.dart';
import '../state/connection.dart';
import '../state/launcher.dart';
import '../shell/native_registry.dart';
import '../widgets/app_icon.dart';
import '../widgets/open_apps_bar.dart';
import 'mirror_screen.dart';

class LauncherScreen extends ConsumerStatefulWidget {
  const LauncherScreen({super.key});

  @override
  ConsumerState<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends ConsumerState<LauncherScreen> {
  String _search = '';

  Future<void> _openWindow(WindowInfo w, List<AppInfo> apps) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MirrorScreen(
        target: MirrorTarget(windowId: w.windowId, title: bestWindowName(w, apps)),
      ),
    ));
    if (mounted) ref.read(windowsProvider.notifier).refresh();
  }

  Future<void> _launchApp(AppInfo a, List<WindowInfo> windows) async {
    // Already running → jump into its window instead of launching a second copy.
    for (final w in windows) {
      if (windowMatchesApp(w, a)) {
        await _openWindow(w, ref.read(appsProvider).value ?? []);
        return;
      }
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MirrorScreen(
        target: MirrorTarget(appId: a.appId, wmClass: a.wmClass, title: a.name),
      ),
    ));
    if (mounted) ref.read(windowsProvider.notifier).refresh();
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
            if (windows.isNotEmpty)
              OpenAppsBar(
                windows: windows,
                apps: apps,
                onTap: (w) => _openWindow(w, apps),
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
    final windowsAsync = ref.watch(windowsProvider);
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
          if (windowsAsync.hasError)
            IconButton(
              tooltip: 'Retry window list',
              icon: const Icon(Icons.refresh, size: 18, color: Colors.orangeAccent),
              onPressed: () => ref.read(windowsProvider.notifier).refresh(),
            ),
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
        children: kNativeTools.map((tool) {
          return InkWell(
            onTap: () async {
              final screen = screenForNativeTool(tool.id);
              if (screen == null) return;
              // Native RPC tools never start capture; desktopMirror streams.
              assert(
                tool.isNativeRpc || tool.kind == NativeRouteKind.desktopMirror,
              );
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => screen),
              );
              if (context.mounted) {
                ref.read(windowsProvider.notifier).refresh();
              }
            },
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tool.icon,
                      size: 20, color: Colors.white.withValues(alpha: 0.75)),
                  const SizedBox(height: 3),
                  Text(tool.label,
                      style: TextStyle(
                          fontSize: 9.5,
                          color: Colors.white.withValues(alpha: 0.4))),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
