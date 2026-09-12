import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/host.dart';

/// Hosts = entries from ~/.ssh/config (desktop) + hosts the user added.
/// Recent folders are remembered per host id in hosts.json.
class HostStore {
  HostStore._();
  static final instance = HostStore._();

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/$name');
  }

  Future<Map<String, dynamic>> _readJson(String name) async {
    try {
      final f = await _file(name);
      if (!await f.exists()) return {};
      return (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeJson(String name, Map<String, dynamic> data) async {
    final f = await _file(name);
    await f.writeAsString(jsonEncode(data));
  }

  /// Test hook to point ~ somewhere else.
  static String? homeOverride;

  static String? get sshDir {
    final home = homeOverride ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;
    final d = Directory('$home/.ssh');
    return d.existsSync() ? d.path : null;
  }

  /// Hosts from ~/.ssh/config. Wildcard entries are skipped.
  List<HostConfig> loadSshConfigHosts() {
    final dir = sshDir;
    if (dir == null) return [];
    final f = File('$dir/config');
    if (!f.existsSync()) return [];
    final result = <HostConfig>[];
    HostConfig? cur;
    for (final raw in f.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^(\S+)\s*[= ]\s*(.+)$').firstMatch(line);
      if (m == null) continue;
      final key = m.group(1)!.toLowerCase();
      final value = m.group(2)!.trim();
      if (key == 'host') {
        cur = null;
        final names = value.split(RegExp(r'\s+'));
        if (names.length != 1 || names.first.contains('*') || names.first.contains('?')) {
          continue;
        }
        cur = HostConfig(
          id: 'cfg:${names.first}',
          alias: names.first,
          host: names.first,
          fromSshConfig: true,
        );
        result.add(cur);
      } else if (cur != null) {
        switch (key) {
          case 'hostname':
            cur.host = value;
          case 'user':
            cur.username = value;
          case 'port':
            cur.port = int.tryParse(value) ?? 22;
          case 'identityfile':
            cur.identityFile ??= value.replaceAll('"', '');
        }
      }
    }
    return result;
  }

  Future<List<HostConfig>> loadHosts() async {
    final data = await _readJson('hosts.json');
    final saved = ((data['hosts'] ?? []) as List)
        .map((e) => HostConfig.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final recent = ((data['recent'] ?? {}) as Map).cast<String, dynamic>();
    final config = loadSshConfigHosts();
    for (final h in config) {
      h.recentDirs = ((recent[h.id] ?? []) as List).cast<String>();
    }
    return [...config, ...saved];
  }

  Future<void> saveHosts(List<HostConfig> hosts) async {
    await _writeJson('hosts.json', {
      'hosts': hosts.where((h) => !h.fromSshConfig).map((h) => h.toJson()).toList(),
      'recent': {
        for (final h in hosts.where((h) => h.fromSshConfig && h.recentDirs.isNotEmpty))
          h.id: h.recentDirs,
      },
    });
  }

  // ---- known hosts ---------------------------------------------------------

  Future<Map<String, String>> loadKnownHosts() async =>
      (await _readJson('known_hosts.json')).cast<String, String>();

  Future<void> saveKnownHost(String hostPort, String fingerprint) async {
    final all = await loadKnownHosts();
    all[hostPort] = fingerprint;
    await _writeJson('known_hosts.json', all);
  }
}

class HostsNotifier extends AsyncNotifier<List<HostConfig>> {
  @override
  Future<List<HostConfig>> build() => HostStore.instance.loadHosts();

  Future<void> reload() async {
    state = AsyncData(await HostStore.instance.loadHosts());
  }

  Future<void> upsert(HostConfig host) async {
    final list = <HostConfig>[...?state.value];
    final i = list.indexWhere((h) => h.id == host.id);
    if (i >= 0) {
      list[i] = host;
    } else {
      list.add(host);
    }
    await HostStore.instance.saveHosts(list);
    state = AsyncData(list);
  }

  Future<void> remove(String id) async {
    final list = <HostConfig>[...?state.value]..removeWhere((h) => h.id == id);
    await HostStore.instance.saveHosts(list);
    state = AsyncData(list);
  }

  Future<void> addRecentDir(String hostId, String dir) async {
    final list = <HostConfig>[...?state.value];
    final h = list.firstWhere((h) => h.id == hostId);
    h.recentDirs
      ..remove(dir)
      ..insert(0, dir);
    if (h.recentDirs.length > 20) h.recentDirs = h.recentDirs.sublist(0, 20);
    await HostStore.instance.saveHosts(list);
    state = AsyncData(list);
  }

  Future<void> removeRecentDir(String hostId, String dir) async {
    final list = <HostConfig>[...?state.value];
    list.firstWhere((h) => h.id == hostId).recentDirs.remove(dir);
    await HostStore.instance.saveHosts(list);
    state = AsyncData(list);
  }
}

final hostsProvider =
    AsyncNotifierProvider<HostsNotifier, List<HostConfig>>(HostsNotifier.new);
