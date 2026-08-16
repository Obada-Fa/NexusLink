import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/updates/app_update.dart';

void main() {
  group('AppVersion.parse', () {
    test('parses v-prefixed tag with build number', () {
      expect(AppVersion.parse('v1.2.3+4'), const AppVersion('1.2.3', 4));
    });

    test('parses android- prefix', () {
      expect(AppVersion.parse('android-v1.0.0+2'), const AppVersion('1.0.0', 2));
    });

    test('defaults build to 0 when omitted', () {
      expect(AppVersion.parse('v1.0.0'), const AppVersion('1.0.0', 0));
    });
  });

  group('AppVersion.isNewerThan', () {
    test('prefers higher versionCode', () {
      expect(
        const AppVersion('1.0.0', 2).isNewerThan(const AppVersion('9.0.0', 1)),
        isTrue,
      );
      expect(
        const AppVersion('1.0.0', 1).isNewerThan(const AppVersion('1.0.0', 2)),
        isFalse,
      );
    });

    test('falls back to semver when codes match', () {
      expect(
        const AppVersion('1.1.0', 1).isNewerThan(const AppVersion('1.0.9', 1)),
        isTrue,
      );
      expect(
        const AppVersion('1.0.0', 1).isNewerThan(const AppVersion('1.0.0', 1)),
        isFalse,
      );
    });
  });

  group('releaseUpdateFromJson', () {
    test('picks the first apk asset and parses the tag', () {
      final update = releaseUpdateFromJson({
        'tag_name': 'v1.0.1+3',
        'html_url': 'https://github.com/Obada-Fa/NexusLink/releases/tag/v1.0.1+3',
        'body': 'fixes',
        'assets': [
          {
            'name': 'checksums.txt',
            'browser_download_url': 'https://example.com/checksums.txt',
            'size': 12,
          },
          {
            'name': 'nexuslink-release.apk',
            'browser_download_url':
                'https://github.com/Obada-Fa/NexusLink/releases/download/v1.0.1+3/nexuslink-release.apk',
            'size': 42,
          },
        ],
      });

      expect(update, isNotNull);
      expect(update!.version, const AppVersion('1.0.1', 3));
      expect(update.apkName, 'nexuslink-release.apk');
      expect(update.apkBytes, 42);
      expect(update.apkUrl, contains('nexuslink-release.apk'));
      expect(update.htmlUrl,
          'https://github.com/Obada-Fa/NexusLink/releases/tag/v1.0.1+3');
      expect(update.releasePageUrl,
          'https://github.com/Obada-Fa/NexusLink/releases/tag/v1.0.1+3');
    });

    test('releasePageUrl falls back to latest when html_url empty', () {
      final update = releaseUpdateFromJson({
        'tag_name': 'v1.0.0+1',
        'html_url': '',
        'assets': [
          {
            'name': 'app.apk',
            'browser_download_url': 'https://example.com/app.apk',
            'size': 1,
          },
        ],
      });
      expect(update, isNotNull);
      expect(update!.releasePageUrl, kReleasesLatestUrl);
    });

    test('returns null when no apk asset exists', () {
      expect(
        releaseUpdateFromJson({
          'tag_name': 'v1.0.0+1',
          'html_url': 'https://example.com',
          'assets': [
            {'name': 'notes.md', 'browser_download_url': 'https://example.com/n'},
          ],
        }),
        isNull,
      );
    });
  });
}
