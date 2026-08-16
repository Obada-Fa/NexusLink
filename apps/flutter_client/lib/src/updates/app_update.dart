// In-app APK updates via GitHub Releases — no NexusLink server required.
//
// Flow:
//   1. GET https://api.github.com/repos/<owner>/<repo>/releases/latest
//   2. Find a .apk asset; parse version from the release tag (e.g. v1.2.3+4)
//   3. If remote versionCode > installed versionCode, download the APK
//   4. Hand the file to the system package installer (open_filex + FileProvider)
//
// GitHub hosts the bits; you only push a tagged release. The LAN host does not
// need to be running for updates to work (phone only needs internet).

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Public GitHub repo that publishes Android APK release assets.
const String kUpdateGithubRepo = 'Obada-Fa/NexusLink';

/// Browser page for the latest APK release (fallback when html_url is missing).
const String kReleasesLatestUrl =
    'https://github.com/Obada-Fa/NexusLink/releases/latest';

/// User-Agent required by the GitHub API.
const String _kUserAgent = 'NexusLink-Android-Updater';

class AppVersion {
  final String name; // e.g. "1.0.0"
  final int code; // e.g. 1  (Android versionCode / pubspec +build)

  const AppVersion(this.name, this.code);

  /// Parses tags like `v1.2.3+4`, `android-v1.2.3+4`, `1.2.3+4`, `v1.2.3`.
  /// Missing build number defaults to 0.
  factory AppVersion.parse(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('android-')) {
      s = s.substring('android-'.length);
    }
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    final plus = s.indexOf('+');
    final name = plus >= 0 ? s.substring(0, plus) : s;
    final code = plus >= 0 ? int.tryParse(s.substring(plus + 1)) ?? 0 : 0;
    return AppVersion(name.isEmpty ? '0.0.0' : name, code);
  }

  bool isNewerThan(AppVersion other) {
    if (code != other.code) return code > other.code;
    return _compareSemver(name, other.name) > 0;
  }

  @override
  String toString() => code > 0 ? '$name+$code' : name;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && other.name == name && other.code == code;

  @override
  int get hashCode => Object.hash(name, code);
}

int _compareSemver(String a, String b) {
  List<int> parts(String s) => s
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9].*'), '')) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

class ReleaseUpdate {
  final AppVersion version;
  final String tag;
  final String apkName;
  final String apkUrl;
  final int? apkBytes;
  final String? notes;
  final String htmlUrl;

  const ReleaseUpdate({
    required this.version,
    required this.tag,
    required this.apkName,
    required this.apkUrl,
    required this.htmlUrl,
    this.apkBytes,
    this.notes,
  });

  /// GitHub release page in the browser (or latest releases if html_url empty).
  String get releasePageUrl =>
      htmlUrl.isNotEmpty ? htmlUrl : kReleasesLatestUrl;
}

enum UpdateCheckResultKind { upToDate, available, noRelease, error }

class UpdateCheckResult {
  final UpdateCheckResultKind kind;
  final AppVersion installed;
  final ReleaseUpdate? update;
  final String? error;

  const UpdateCheckResult({
    required this.kind,
    required this.installed,
    this.update,
    this.error,
  });
}

typedef JsonMap = Map<String, dynamic>;

/// Injectable HTTP GET for tests.
typedef HttpGet = Future<http.Response> Function(Uri url,
    {Map<String, String>? headers});

class AppUpdateService {
  AppUpdateService({
    this.repo = kUpdateGithubRepo,
    HttpGet? httpGet,
  }) : _httpGet = httpGet ?? _defaultGet;

  final String repo;
  final HttpGet _httpGet;

  static Future<http.Response> _defaultGet(Uri url,
      {Map<String, String>? headers}) {
    return http.get(url, headers: headers);
  }

  Future<AppVersion> installedVersion() async {
    final info = await PackageInfo.fromPlatform();
    final code = int.tryParse(info.buildNumber) ?? 0;
    return AppVersion(info.version, code);
  }

  /// Fetches the latest GitHub release that has an `.apk` asset.
  Future<UpdateCheckResult> checkForUpdate() async {
    final installed = await installedVersion();
    try {
      final uri =
          Uri.parse('https://api.github.com/repos/$repo/releases/latest');
      final res = await _httpGet(uri, headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': _kUserAgent,
        'X-GitHub-Api-Version': '2022-11-28',
      });
      if (res.statusCode == 404) {
        return UpdateCheckResult(
          kind: UpdateCheckResultKind.noRelease,
          installed: installed,
          error: 'No GitHub releases yet for $repo.',
        );
      }
      if (res.statusCode != 200) {
        return UpdateCheckResult(
          kind: UpdateCheckResultKind.error,
          installed: installed,
          error: 'GitHub returned HTTP ${res.statusCode}.',
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return UpdateCheckResult(
          kind: UpdateCheckResultKind.error,
          installed: installed,
          error: 'Could not parse GitHub release JSON.',
        );
      }
      final update = releaseUpdateFromJson(Map<String, dynamic>.from(decoded));
      if (update == null) {
        return UpdateCheckResult(
          kind: UpdateCheckResultKind.noRelease,
          installed: installed,
          error: 'Latest release has no .apk asset.',
        );
      }
      if (!update.version.isNewerThan(installed)) {
        return UpdateCheckResult(
          kind: UpdateCheckResultKind.upToDate,
          installed: installed,
          update: update,
        );
      }
      return UpdateCheckResult(
        kind: UpdateCheckResultKind.available,
        installed: installed,
        update: update,
      );
    } catch (e) {
      return UpdateCheckResult(
        kind: UpdateCheckResultKind.error,
        installed: installed,
        error: e.toString(),
      );
    }
  }

  /// Downloads [update.apkUrl] to a temp file. [onProgress] gets 0..1.
  Future<File> downloadApk(
    ReleaseUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final safeName = update.apkName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final out = File('${dir.path}/$safeName');
    if (await out.exists()) {
      await out.delete();
    }

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(update.apkUrl));
      req.headers['User-Agent'] = _kUserAgent;
      req.headers['Accept'] = 'application/octet-stream';
      final res = await client.send(req);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('Download failed: HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? update.apkBytes ?? 0;
      final sink = out.openWrite();
      var received = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      onProgress?.call(1);
      return out;
    } finally {
      client.close();
    }
  }

  /// Opens the system APK installer for [apk]. Returns false if open failed.
  Future<bool> installApk(File apk) async {
    if (!Platform.isAndroid) return false;
    final result = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    // `done` = installer launched; some devices report noAppToOpen even when
    // the package installer activity started — treat both as success paths
    // unless it's an explicit error/permission denial.
    return result.type == ResultType.done ||
        result.type == ResultType.noAppToOpen;
  }
}

/// Pure parser — unit-tested without HTTP.
ReleaseUpdate? releaseUpdateFromJson(JsonMap json) {
  final tag = (json['tag_name'] as String?)?.trim() ?? '';
  if (tag.isEmpty) return null;
  final assets = json['assets'];
  if (assets is! List) return null;

  JsonMap? apk;
  for (final raw in assets) {
    if (raw is! Map) continue;
    final name = (raw['name'] as String?) ?? '';
    if (name.toLowerCase().endsWith('.apk')) {
      apk = Map<String, dynamic>.from(raw);
      break;
    }
  }
  if (apk == null) return null;

  final url = (apk['browser_download_url'] as String?) ?? '';
  if (url.isEmpty) return null;

  return ReleaseUpdate(
    version: AppVersion.parse(tag),
    tag: tag,
    apkName: (apk['name'] as String?) ?? 'nexuslink.apk',
    apkUrl: url,
    apkBytes: (apk['size'] as num?)?.toInt(),
    notes: json['body'] as String?,
    htmlUrl: (json['html_url'] as String?) ?? '',
  );
}
