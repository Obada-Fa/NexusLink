/// Shared phone-side path math for Unix hosts and Windows drive letters.

String toPosixPath(String path) => path.replaceAll('\\', '/');

bool isThisPcPath(String path) {
  final p = toPosixPath(path).replaceAll(RegExp(r'/+$'), '');
  final normalized = p.isEmpty ? '/' : p;
  return normalized == '/' || normalized.toLowerCase() == 'this pc';
}

bool isWindowsDriveRoot(String path) {
  final p = toPosixPath(path).replaceAll(RegExp(r'/+$'), '');
  return RegExp(r'^[A-Za-z]:$').hasMatch(p);
}

/// Parent of a host path. Drive roots (`C:` / `C:/`) go to This PC (`/`).
String parentHostPath(String path) {
  if (path.isEmpty || isThisPcPath(path)) return '/';
  var p = toPosixPath(path);
  if (p.endsWith('/') && p != '/') p = p.substring(0, p.length - 1);
  if (isWindowsDriveRoot(p)) return '/';
  final i = p.lastIndexOf('/');
  if (i <= 0) return '/';
  final parent = p.substring(0, i);
  if (isWindowsDriveRoot(parent)) return '$parent/';
  return parent;
}

/// Kept for existing imports; Windows-aware.
String parentUnixPath(String path) => parentHostPath(path);

String folderDisplayNameForHost(String path) {
  if (isThisPcPath(path)) return 'This PC';
  if (path.isEmpty) return path;
  final trimmed =
      path.endsWith('/') && path != '/' ? path.substring(0, path.length - 1) : path;
  if (RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return trimmed;
  final i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}
