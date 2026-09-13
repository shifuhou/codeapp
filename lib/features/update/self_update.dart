import 'dart:io';

import 'package:http/http.dart' as http;

/// Streams a download to [file], reporting progress.
Future<void> downloadFile(String url, File file, {required void Function(int received, int total) onProgress}) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url));
    final res = await client.send(req);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress(received, total);
    }
    await sink.close();
  } finally {
    client.close();
  }
}

/// Android: hand the APK to the system package installer.
Future<void> openAndroidInstaller(File apk) async {
  final r = await Process.run('am', [
    'start',
    '-a', 'android.intent.action.VIEW',
    '-t', 'application/vnd.android.package-archive',
    '-d', 'file://${apk.path}',
    '--grant-read-uri-permission',
  ]);
  if (r.exitCode != 0) {
    throw Exception('Could not open installer: ${r.stderr}');
  }
}

/// Desktop: replace the running install with the downloaded archive and
/// relaunch. A small detached helper does the swap so it can overwrite the
/// executable that is currently running, keeping a .bak for rollback.
Future<void> applyDesktopUpdate(File archive) async {
  final exe = File(Platform.resolvedExecutable);
  final Directory installDir;
  if (Platform.isMacOS) {
    installDir = exe.parent.parent.parent; // …/CodeApp.app/Contents/MacOS/exe -> the .app
  } else {
    installDir = exe.parent;
  }

  final tmp = await Directory.systemTemp.createTemp('codeapp-update');
  final script = File('${tmp.path}/apply${Platform.isWindows ? '.ps1' : '.sh'}');

  if (Platform.isWindows) {
    await script.writeAsString(_windowsScript(archive.path, installDir.path, exe.path, tmp.path));
    await Process.start('powershell', ['-ExecutionPolicy', 'Bypass', '-File', script.path],
        mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    await script.writeAsString(_macScript(archive.path, installDir.path, tmp.path));
    await Process.start('bash', [script.path], mode: ProcessStartMode.detached);
  } else {
    await script.writeAsString(_linuxScript(archive.path, installDir.path, exe.path, tmp.path));
    await Process.start('bash', [script.path], mode: ProcessStartMode.detached);
  }
  await Future.delayed(const Duration(milliseconds: 300));
  exit(0);
}

String _linuxScript(String archive, String install, String exe, String tmp) => '''
#!/usr/bin/env bash
set -e
sleep 1
stage="$tmp/stage"; mkdir -p "\$stage"
tar -xzf "$archive" -C "\$stage"
rm -rf "$install.bak"; cp -a "$install" "$install.bak"
cp -a "\$stage/." "$install/"
chmod +x "$exe" || true
nohup "$exe" >/dev/null 2>&1 &
rm -rf "$tmp"
''';

String _macScript(String archive, String appDir, String tmp) => '''
#!/usr/bin/env bash
set -e
sleep 1
stage="$tmp/stage"; mkdir -p "\$stage"
unzip -oq "$archive" -d "\$stage"
app=\$(find "\$stage" -maxdepth 2 -name "*.app" | head -1)
if [ -n "\$app" ]; then
  rm -rf "$appDir.bak"; mv "$appDir" "$appDir.bak"
  cp -a "\$app" "$appDir"
  xattr -dr com.apple.quarantine "$appDir" || true
fi
open "$appDir"
rm -rf "$tmp"
''';

String _windowsScript(String archive, String install, String exe, String tmp) => '''
Start-Sleep -Seconds 1
\$stage = "$tmp\\stage"
New-Item -ItemType Directory -Force -Path \$stage | Out-Null
Expand-Archive -Path "$archive" -DestinationPath \$stage -Force
if (Test-Path "$install.bak") { Remove-Item -Recurse -Force "$install.bak" }
Copy-Item -Recurse -Force "$install" "$install.bak"
Copy-Item -Recurse -Force "\$stage\\*" "$install"
Start-Process -FilePath "$exe"
Remove-Item -Recurse -Force "$tmp"
''';
