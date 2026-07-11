import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/update_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
  });

  group('Plezy Labs channel preference', () {
    test('defaults to Labs and stores the first-launch choice using canonical keys', () async {
      expect(await UpdateService.getUpdateChannel(), UpdateChannel.labs);

      await UpdateService.completeUpdateChannelChoice(UpdateChannel.official);

      expect(await UpdateService.getUpdateChannel(), UpdateChannel.official);
      expect(await UpdateService.shouldPromptForUpdateChannel(), isFalse);
    });
  });

  group('Plezy Labs release parsing', () {
    test('selects the newest published Labs prerelease and keeps its notes', () {
      final release = UpdateService.latestLabsReleaseFromJson([
        {
          'tag_name': 'labs-v2.8.0-r2',
          'html_url': 'https://example.test/r2',
          'name': 'Plezy Labs 2.8.0 r2',
          'body': 'GitHub release notes',
          'published_at': '2026-07-12T12:00:00Z',
          'draft': false,
          'prerelease': true,
        },
        {'tag_name': 'labs-v2.8.0-r1', 'html_url': 'https://example.test/r1', 'draft': false, 'prerelease': true},
      ]);

      expect(release, isNotNull);
      expect(release!.version, '2.8.0');
      expect(release.revision, 2);
      expect(release.displayVersion, '2.8.0 r2');
      expect(release.releaseNotes, 'GitHub release notes');
    });

    test('ignores drafts, stable fork releases, and unrelated prereleases', () {
      final release = UpdateService.latestLabsReleaseFromJson([
        {'tag_name': 'labs-v2.8.0-r3', 'html_url': 'https://example.test/draft', 'draft': true, 'prerelease': true},
        {'tag_name': 'labs-v2.8.0-r2', 'html_url': 'https://example.test/stable', 'draft': false, 'prerelease': false},
        {'tag_name': 'beta-v2.8.0', 'html_url': 'https://example.test/beta', 'draft': false, 'prerelease': true},
      ]);

      expect(release, isNull);
    });

    test('rejects prerelease data from the official latest source', () {
      final release = UpdateService.officialReleaseFromJson({
        'tag_name': '2.9.0-beta.1',
        'html_url': 'https://example.test/official',
        'draft': false,
        'prerelease': true,
      });

      expect(release, isNull);
    });
  });

  group('Plezy Labs source comparison', () {
    test('reports when Labs has not caught up to official Plezy', () {
      const sources = UpdateReleaseSources(
        official: PlezyRelease(
          version: '2.9.0',
          releaseUrl: 'https://example.test/official',
          releaseName: 'Plezy 2.9.0',
          releaseNotes: '',
          publishedAt: '',
          tag: '2.9.0',
        ),
        labs: PlezyRelease(
          version: '2.8.0',
          revision: 4,
          releaseUrl: 'https://example.test/labs',
          releaseName: 'Plezy Labs 2.8.0 r4',
          releaseNotes: '',
          publishedAt: '',
          tag: 'labs-v2.8.0-r4',
        ),
      );

      expect(sources.labsIsBehindOfficial, isTrue);
    });

    test('compares semantic version components numerically', () {
      expect(UpdateService.isNewerVersion('2.10.0', '2.9.9'), isTrue);
      expect(UpdateService.isNewerVersion('2.8.0', '2.8.0'), isFalse);
      expect(UpdateService.isNewerVersion('2.7.9', '2.8.0'), isFalse);
    });
  });
}
