import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import 'base_shared_preferences_service.dart';

enum UpdateChannel { official, labs }

class PlezyRelease {
  const PlezyRelease({
    required this.version,
    required this.releaseUrl,
    required this.releaseName,
    required this.releaseNotes,
    required this.publishedAt,
    required this.tag,
    this.revision,
  });

  final String version;
  final int? revision;
  final String releaseUrl;
  final String releaseName;
  final String releaseNotes;
  final String publishedAt;
  final String tag;

  String get displayVersion => revision == null ? version : '$version r$revision';
}

class UpdateReleaseSources {
  const UpdateReleaseSources({required this.official, required this.labs});

  final PlezyRelease? official;
  final PlezyRelease? labs;

  bool get labsIsBehindOfficial {
    final officialRelease = official;
    final labsRelease = labs;
    if (officialRelease == null) return false;
    if (labsRelease == null) return true;
    return UpdateService.isNewerVersion(officialRelease.version, labsRelease.version);
  }
}

/// Plezy Labs release discovery and update orchestration.
///
/// GitHub Releases is the single source of truth for release names, notes,
/// dates, and download pages. Sparkle/WinSparkle uses the separate Labs
/// appcast only for authenticated Labs-to-Labs native updates.
class UpdateService {
  static final Logger _logger = Logger();

  static const String officialGithubRepo = 'edde746/plezy';
  static const String labsGithubRepo = 'RyanTheTechMan/plezy';
  static const String labsFeedUrl = 'https://raw.githubusercontent.com/RyanTheTechMan/plezy/labs-feed/appcast.xml';
  static const String officialReleasesUrl = 'https://github.com/edde746/plezy/releases/latest';
  static const int labsRevision = int.fromEnvironment('LABS_REVISION', defaultValue: 1);

  static const String _keySkippedVersion = 'update_skipped_version';
  static const String _keyLastCheckTime = 'update_last_check_time';
  static const String _keyUpdateChannel = 'update_channel';
  static const String _keyChannelChoiceComplete = 'update_channel_choice_complete';
  static const Duration _checkCooldown = Duration(hours: 6);
  static final RegExp _labsTagPattern = RegExp(r'^labs-v(\d+\.\d+\.\d+)-r(\d+)$');

  static bool _nativeUpdaterInitialized = false;

  static bool get isLabsBuild => const bool.fromEnvironment('PLEZY_LABS', defaultValue: false);

  static bool get isUpdateCheckEnabled => const bool.fromEnvironment('ENABLE_UPDATE_CHECK', defaultValue: false);

  /// Whether this installation type supports Sparkle/WinSparkle.
  static bool get useNativeUpdater {
    if (!isUpdateCheckEnabled) return false;
    if (Platform.isMacOS) return !_isHomebrewInstall();
    if (Platform.isWindows) return _isInstalledApp() && !_isWingetInstall();
    return false;
  }

  static Future<UpdateChannel> getUpdateChannel() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final stored = prefs.getString(_keyUpdateChannel);
    return UpdateChannel.values.where((channel) => channel.name == stored).firstOrNull ?? UpdateChannel.labs;
  }

  static Future<void> setUpdateChannel(UpdateChannel channel) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keyUpdateChannel, channel.name);
  }

  static Future<bool> shouldPromptForUpdateChannel() async {
    if (!isUpdateCheckEnabled) return false;
    final prefs = await BaseSharedPreferencesService.sharedCache();
    return prefs.getBool(_keyChannelChoiceComplete) != true;
  }

  static Future<void> completeUpdateChannelChoice(UpdateChannel channel) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keyUpdateChannel, channel.name);
    await prefs.setBool(_keyChannelChoiceComplete, true);
  }

  static Future<void> initNativeUpdater() async {
    if (_nativeUpdaterInitialized || await getUpdateChannel() != UpdateChannel.labs) return;

    try {
      await autoUpdater.setFeedURL(labsFeedUrl);
      _nativeUpdaterInitialized = true;
    } catch (e) {
      _logger.e('Failed to initialize Plezy Labs native updater: $e');
    }
  }

  static Future<void> checkForUpdatesNative({bool inBackground = true}) async {
    if (await getUpdateChannel() != UpdateChannel.labs) return;
    if (!_nativeUpdaterInitialized) {
      await initNativeUpdater();
      if (!_nativeUpdaterInitialized) return;
    }
    try {
      await autoUpdater.checkForUpdates(inBackground: inBackground);
    } catch (e) {
      _logger.e('Plezy Labs native update check failed: $e');
    }
  }

  static Future<UpdateReleaseSources> fetchReleaseSources() async {
    PlezyRelease? official;
    PlezyRelease? labs;

    try {
      final responses = await Future.wait([
        httpClient.get(
          'https://api.github.com/repos/$officialGithubRepo/releases/latest',
          headers: {'Accept': 'application/vnd.github+json'},
        ),
        httpClient.get(
          'https://api.github.com/repos/$labsGithubRepo/releases?per_page=30',
          headers: {'Accept': 'application/vnd.github+json'},
        ),
      ]);

      if (responses[0].statusCode == 200 && responses[0].data is Map) {
        official = officialReleaseFromJson(Map<String, dynamic>.from(responses[0].data as Map));
      }
      if (responses[1].statusCode == 200 && responses[1].data is List) {
        labs = latestLabsReleaseFromJson(responses[1].data as List<dynamic>);
      }
    } catch (e) {
      _logger.e('Failed to load Plezy release sources: $e');
    }

    return UpdateReleaseSources(official: official, labs: labs);
  }

  static PlezyRelease? officialReleaseFromJson(Map<String, dynamic> data) {
    final tag = data['tag_name'] as String?;
    final url = data['html_url'] as String?;
    if (tag == null || url == null || data['draft'] == true || data['prerelease'] == true) return null;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    return _releaseFromJson(data, version: version, tag: tag);
  }

  static PlezyRelease? latestLabsReleaseFromJson(List<dynamic> releases) {
    for (final raw in releases) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final tag = data['tag_name'] as String? ?? '';
      final match = _labsTagPattern.firstMatch(tag);
      if (match == null || data['draft'] == true || data['prerelease'] != false) continue;
      return _releaseFromJson(data, version: match.group(1)!, revision: int.parse(match.group(2)!), tag: tag);
    }
    return null;
  }

  static PlezyRelease? _releaseFromJson(
    Map<String, dynamic> data, {
    required String version,
    required String tag,
    int? revision,
  }) {
    final url = data['html_url'] as String?;
    if (url == null) return null;
    return PlezyRelease(
      version: version,
      revision: revision,
      releaseUrl: url,
      releaseName: data['name'] as String? ?? (revision == null ? 'Plezy $version' : 'Plezy Labs $version r$revision'),
      releaseNotes: data['body'] as String? ?? '',
      publishedAt: data['published_at'] as String? ?? '',
      tag: tag,
    );
  }

  static bool _isHomebrewInstall() {
    try {
      final execPath = Platform.resolvedExecutable;
      return execPath.contains('/Caskroom/') || execPath.contains('/homebrew/');
    } catch (_) {
      return false;
    }
  }

  static bool _isWingetInstall() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return File('$exeDir\\.winget').existsSync();
    } catch (_) {
      return false;
    }
  }

  static bool _isInstalledApp() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return File('$exeDir\\unins000.exe').existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<void> skipVersion(String version) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keySkippedVersion, version);
  }

  static Future<String?> getSkippedVersion() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    return prefs.getString(_keySkippedVersion);
  }

  static Future<void> clearSkippedVersion() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(_keySkippedVersion);
  }

  /// Check if cooldown period has passed since last check
  static Future<bool> shouldCheckForUpdates() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final lastCheckString = prefs.getString(_keyLastCheckTime);
    if (lastCheckString == null) return true;
    return DateTime.now().difference(DateTime.parse(lastCheckString)) >= _checkCooldown;
  }

  static Future<void> _updateLastCheckTime() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keyLastCheckTime, DateTime.now().toIso8601String());
  }

  static Future<Map<String, dynamic>?> _performUpdateCheck({required bool respectCooldown}) async {
    if (!isUpdateCheckEnabled) return null;
    if (respectCooldown && !await shouldCheckForUpdates()) return null;

    final sources = await fetchReleaseSources();
    final channel = await getUpdateChannel();
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;
    final release = channel == UpdateChannel.labs ? sources.labs : sources.official;

    if (respectCooldown) await _updateLastCheckTime();
    if (release == null) return null;

    final hasUpdate = channel == UpdateChannel.labs
        ? isNewerVersion(release.version, currentVersion) ||
              (release.version == currentVersion && (release.revision ?? 0) > labsRevision)
        : isNewerVersion(release.version, currentVersion);
    if (!hasUpdate || await getSkippedVersion() == release.tag) return null;

    return {
      'hasUpdate': true,
      'currentVersion': channel == UpdateChannel.labs ? '$currentVersion r$labsRevision' : currentVersion,
      'latestVersion': release.displayVersion,
      'releaseUrl': release.releaseUrl,
      'releaseName': release.releaseName,
      'releaseNotes': release.releaseNotes,
      'publishedAt': release.publishedAt,
      'tag': release.tag,
    };
  }

  static Future<Map<String, dynamic>?> checkForUpdates() => _performUpdateCheck(respectCooldown: false);

  static Future<Map<String, dynamic>?> checkForUpdatesOnStartup() => _performUpdateCheck(respectCooldown: true);

  static List<int> _parseVersionParts(String version) {
    return version.split('.').map((part) {
      final numeric = part.split('+').first.split('-').first;
      return int.tryParse(numeric) ?? 0;
    }).toList();
  }

  static bool isNewerVersion(String newVersion, String currentVersion) {
    final newParts = _parseVersionParts(newVersion);
    final currentParts = _parseVersionParts(currentVersion);
    final maxLength = newParts.length > currentParts.length ? newParts.length : currentParts.length;
    for (var i = 0; i < maxLength; i++) {
      final next = i < newParts.length ? newParts[i] : 0;
      final current = i < currentParts.length ? currentParts[i] : 0;
      if (next > current) return true;
      if (next < current) return false;
    }
    return false;
  }
}
