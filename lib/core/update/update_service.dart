import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

enum UpdatePlatform { windows, macos, linux, android, ios, unknown }

class UpdateInfo {
  UpdateInfo({
    required this.currentVersion,
    required this.latestLabel,
    required this.notes,
    required this.releaseUrl,
    required this.assetUrl,
    required this.assetName,
    required this.commit,
    required this.isNewer,
    required this.canSelfUpdate,
    required this.platform,
  });

  final String currentVersion;
  final String latestLabel;
  final String notes;
  final String releaseUrl;
  final String? assetUrl;
  final String? assetName;
  final String commit;
  final bool isNewer;
  final bool canSelfUpdate;
  final UpdatePlatform platform;
}

/// Reads the GitHub `latest` pre-release as an update feed: no server of our
/// own. The rolling tag reuses one git sha embedded in the release name, so
/// builds are compared by that commit rather than the pubspec version.
class UpdateService {
  UpdateService({this.repo = 'shifuhou/codeapp'});
  final String repo;

  static const _assetForPlatform = {
    UpdatePlatform.windows: 'CodeApp-windows-x64.zip',
    UpdatePlatform.macos: 'CodeApp-macos.zip',
    UpdatePlatform.linux: 'CodeApp-linux-x64.tar.gz',
    UpdatePlatform.android: 'CodeApp-android.apk',
    UpdatePlatform.ios: 'CodeApp-ios-unsigned.ipa',
  };

  UpdatePlatform get platform {
    if (kIsWeb) return UpdatePlatform.unknown;
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isIOS) return UpdatePlatform.ios;
    return UpdatePlatform.unknown;
  }

  bool get canSelfUpdate =>
      platform == UpdatePlatform.windows || platform == UpdatePlatform.linux || platform == UpdatePlatform.macos;

  /// The build commit this app was compiled from, injected at build time with
  /// `--dart-define=BUILD_COMMIT=<sha>`. Empty in local/dev builds.
  static const buildCommit = String.fromEnvironment('BUILD_COMMIT');

  Future<UpdateInfo> check() async {
    final info = await PackageInfo.fromPlatform();
    final current = buildCommit.isNotEmpty
        ? 'build ${buildCommit.substring(0, buildCommit.length.clamp(0, 7))}'
        : '${info.version}+${info.buildNumber}';
    final res = await http
        .get(Uri.parse('https://api.github.com/repos/$repo/releases/tags/latest'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Update check failed (HTTP ${res.statusCode})');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final name = json['name'] as String? ?? '';
    final commit = RegExp(r'\(([0-9a-f]{7,40})\)').firstMatch(name)?.group(1) ?? '';
    final assets = (json['assets'] as List? ?? []).cast<Map<String, dynamic>>();
    final wanted = _assetForPlatform[platform];
    final asset = assets.where((a) => a['name'] == wanted).firstOrNull;
    // Newer when we know both commits and they differ. If we don't know our
    // own commit (dev build), treat any remote build as "available".
    final isNewer = commit.isNotEmpty && (buildCommit.isEmpty || !commit.startsWith(buildCommit) && !buildCommit.startsWith(commit));
    return UpdateInfo(
      currentVersion: current,
      latestLabel: commit.isEmpty ? name : 'build ${commit.substring(0, 7)}',
      notes: (json['body'] as String? ?? '').trim(),
      releaseUrl: json['html_url'] as String? ?? 'https://github.com/$repo/releases/tag/latest',
      assetUrl: asset?['browser_download_url'] as String?,
      assetName: wanted,
      commit: commit,
      isNewer: isNewer,
      canSelfUpdate: canSelfUpdate,
      platform: platform,
    );
  }
}
