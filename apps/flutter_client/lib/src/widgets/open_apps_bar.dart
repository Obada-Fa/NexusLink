// Shared open-apps strip used on the launcher and mirror so the taskbar
// stays reachable while streaming an app (RustDesk-style session chrome).

import 'package:flutter/material.dart';

import '../rpc/models.dart';
import 'app_icon.dart';

typedef OpenAppsTap = void Function(WindowInfo window);

class OpenAppsBar extends StatelessWidget {
  const OpenAppsBar({
    super.key,
    required this.windows,
    required this.apps,
    required this.onTap,
    this.compact = false,
    this.activeWindowId,
  });

  final List<WindowInfo> windows;
  final List<AppInfo> apps;
  final OpenAppsTap onTap;
  final bool compact;
  final String? activeWindowId;

  @override
  Widget build(BuildContext context) {
    if (windows.isEmpty) return const SizedBox.shrink();
    final height = compact ? 52.0 : 66.0;
    final iconSize = compact ? 28.0 : 34.0;
    return Container(
      margin: EdgeInsets.fromLTRB(14, compact ? 4 : 0, 14, compact ? 4 : 0),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF151522),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF22223A)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: windows.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final w = windows[i];
          final name = bestWindowName(w, apps);
          final active = activeWindowId != null && w.windowId == activeWindowId;
          return Tooltip(
            message: '$name — ${w.title}',
            triggerMode: TooltipTriggerMode.longPress,
            child: InkWell(
              onTap: () => onTap(w),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIconTile(icon: w.icon, name: name, size: iconSize),
                    if (!compact) const SizedBox(height: 3),
                    if (!compact)
                      Container(
                        width: 14,
                        height: 3,
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0xFF2A6AFF)
                              : const Color(0xFF4ADE80),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
