import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProjectContext {
  final String host, path;
  const ProjectContext(this.host, this.path);
  String get name =>
      path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
}

class ProjectNotifier extends Notifier<ProjectContext?> {
  final Map<String, ProjectContext> _projects = {};
  int _generation = 0;
  @override
  ProjectContext? build() {
    // The RpcClient instance stays the same while authentication assigns hostId.
    // Listen to connection state, which changes when that identity becomes known.
    ref.listen(connectionProvider, (_, connection) {
      final host = _hostFor(connection);
      final generation = ++_generation;
      state = host == null ? null : _projects[host];
      if (host == null || state != null) return;
      SharedPreferences.getInstance().then((prefs) {
        if (!ref.mounted || generation != _generation || state != null) return;
        final path = prefs.getString('project:$host');
        if (path != null) state = _projects[host] = ProjectContext(host, path);
      });
    });
    final host = _hostFor(ref.read(connectionProvider));
    if (host != null) {
      final generation = _generation;
      SharedPreferences.getInstance().then((prefs) {
        if (!ref.mounted || generation != _generation || state != null) return;
        final path = prefs.getString('project:$host');
        if (path != null) state = _projects[host] = ProjectContext(host, path);
      });
    }
    return host == null ? null : _projects[host];
  }

  String? _hostFor(ConnectionState connection) {
    final client = connection.client;
    // Do not persist a project under a network address before authentication.
    return client?.hostId;
  }

  void select(String path) {
    final client = ref.read(activeClientProvider);
    if (client == null) return;
    ++_generation;
    final host = client.hostId;
    if (host == null) return;
    state = _projects[host] = ProjectContext(host, path);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('project:$host', path),
    );
  }
}

final projectProvider = NotifierProvider<ProjectNotifier, ProjectContext?>(
  ProjectNotifier.new,
);

class WorkspaceTab extends Notifier<int> {
  @override
  int build() => 0;
  void select(int tab) => state = tab;
}

final workspaceTabProvider = NotifierProvider<WorkspaceTab, int>(
  WorkspaceTab.new,
);

class PendingTask extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final pendingTaskProvider = NotifierProvider<PendingTask, String?>(
  PendingTask.new,
);
