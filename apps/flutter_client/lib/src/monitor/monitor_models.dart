// Mission-control data from the host (`monitor.snapshot` / `monitor-update`).
// Thin typed views over the JSON maps, matching packages/rpc-types/src/monitor.ts.

double _d(Object? v) => v is num ? v.toDouble() : 0;
double? _dn(Object? v) => v is num ? v.toDouble() : null;
int _i(Object? v) => v is num ? v.toInt() : 0;
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};
List<Map<String, dynamic>> _l(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class GpuVitals {
  GpuVitals(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String? ?? '';
  String get name => json['name'] as String? ?? 'GPU';
  bool get integrated => json['integrated'] == true;
  double? get busy => _dn(json['busyPercent']);
  double? get vramUsed => _dn(json['vramUsedBytes']);
  double? get vramTotal => _dn(json['vramTotalBytes']);
  double? get vramPercent =>
      vramUsed != null && (vramTotal ?? 0) > 0 ? vramUsed! / vramTotal! * 100 : null;
  double? get tempC => _dn(json['tempC']);
  double? get hotspotC => _dn(json['hotspotC']);
  double? get memTempC => _dn(json['memTempC']);
  double? get powerW => _dn(json['powerW']);
  double? get powerCapW => _dn(json['powerCapW']);
  double? get fanRpm => _dn(json['fanRpm']);
  double? get coreMHz => _dn(json['coreMHz']);
}

class Vitals {
  Vitals(this.json);
  final Map<String, dynamic> json;
  Map<String, dynamic> get _cpu => _m(json['cpu']);
  Map<String, dynamic> get _mem => _m(json['memory']);
  Map<String, dynamic> get _disk => _m(json['disk']);
  Map<String, dynamic> get _net => _m(json['net']);
  int get timestamp => _i(json['timestamp']);
  String get hostname => json['hostname'] as String? ?? 'PC';
  int get uptimeSeconds => _i(json['uptimeSeconds']);
  List<double> get load =>
      (json['load'] as List? ?? const []).map(_d).toList();
  String get cpuModel => _cpu['model'] as String? ?? 'CPU';
  int get cores => _i(_cpu['cores']);
  double get cpu => _d(_cpu['percent']);
  List<double> get perCore =>
      (_cpu['perCore'] as List? ?? const []).map(_d).toList();
  double? get cpuTempC => _dn(_cpu['tempC']);
  int get cpuMHz => _i(_cpu['mhz']);
  double get ramUsed => _d(_mem['usedBytes']);
  double get ramTotal => _d(_mem['totalBytes']);
  double get ramPercent => _d(_mem['percent']);
  double get swapUsed => _d(_mem['swapUsedBytes']);
  double get swapTotal => _d(_mem['swapTotalBytes']);
  List<GpuVitals> get gpus => _l(json['gpus']).map(GpuVitals.new).toList();
  GpuVitals? get mainGpu => gpus.isEmpty ? null : gpus.first;
  double get diskRead => _d(_disk['readBps']);
  double get diskWrite => _d(_disk['writeBps']);
  double? get nvmeTempC => _dn(_disk['nvmeTempC']);
  double? get rootFree => _dn(_m(_disk['root'])['freeBytes']);
  double? get rootTotal => _dn(_m(_disk['root'])['totalBytes']);
  double get netRx => _d(_net['rxBps']);
  double get netTx => _d(_net['txBps']);
  List<Map<String, dynamic>> get interfaces => _l(_net['interfaces']);
  List<Map<String, dynamic>> get top => _l(json['top']);
  int get processCount => _i(json['processCount']);
  List<Map<String, dynamic>> get batteries => _l(json['batteries']);
}

class AgentApp {
  AgentApp(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String? ?? '';
  String get appId => json['appId'] as String? ?? '';
  String get name => json['name'] as String? ?? 'App';
  String get provider => json['provider'] as String? ?? '';
  bool get isDesktop => json['kind'] == 'desktop';
  int get pid => _i(json['pid']);
  int get processCount => _i(json['processCount']);
  double get cpu => _d(json['cpuPercent']);
  double get memory => _d(json['rssBytes']);
  DateTime get startedAt =>
      DateTime.fromMillisecondsSinceEpoch(_i(json['startedAt']));
  String? get cwd => json['cwd'] as String?;
  String? get tty => json['tty'] as String?;

  /// busy | active | idle | stuck
  String get state => json['state'] as String? ?? 'idle';
  List<Map<String, dynamic>> get windows => _l(json['windows']);
  List<String> get actions =>
      (json['actions'] as List? ?? const []).whereType<String>().toList();
  List<double> get cpuHistory =>
      (json['cpuHistory'] as List? ?? const []).map(_d).toList();
}

class AgentLauncher {
  AgentLauncher(this.json);
  final Map<String, dynamic> json;
  String get appId => json['appId'] as String? ?? '';
  String get name => json['name'] as String? ?? '';
  String get provider => json['provider'] as String? ?? '';
  bool get running => json['running'] == true;
}

class RemoteService {
  RemoteService(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String? ?? '';
  String get name => json['name'] as String? ?? '';
  bool get installed => json['installed'] == true;

  /// healthy | degraded | down | unknown
  String get state => json['state'] as String? ?? 'unknown';
  String get summary => json['summary'] as String? ?? '';
  List<String> get issues =>
      (json['issues'] as List? ?? const []).whereType<String>().toList();
  Map<String, dynamic> get details => _m(json['details']);
  List<String> get actions =>
      (json['actions'] as List? ?? const []).whereType<String>().toList();
  DateTime? get lastRepairAt => json['lastRepairAt'] is num
      ? DateTime.fromMillisecondsSinceEpoch(_i(json['lastRepairAt']))
      : null;
  String? get lastRepairReason => json['lastRepairReason'] as String?;
}

class MonitorSnapshot {
  MonitorSnapshot(this.json);
  final Map<String, dynamic> json;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(_i(json['at']));
  Vitals get vitals => Vitals(_m(json['vitals']));
  List<AgentApp> get apps => _l(json['apps']).map(AgentApp.new).toList();
  List<AgentLauncher> get launchers =>
      _l(json['launchers']).map(AgentLauncher.new).toList();
  List<RemoteService> get remote =>
      _l(json['remote']).map(RemoteService.new).toList();
  RemoteService? service(String id) =>
      remote.where((s) => s.id == id).firstOrNull;
}

String formatBytes(double bytes, {int digits = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i < 2 ? 0 : digits)} ${units[i]}';
}

String formatRate(double bytesPerSecond) =>
    '${formatBytes(bytesPerSecond)}/s';

String formatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
