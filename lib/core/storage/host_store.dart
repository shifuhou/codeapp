import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/host.dart';

/// Persists host configs as JSON in the app support directory and secrets in
/// the platform keychain / credential store.
class HostStore {
  HostStore._();
  static final instance = HostStore._();

  final _secure = const FlutterSecureStorage();

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/$name');
  }

  Future<List<HostConfig>> loadHosts() async {
    try {
      final f = await _file('hosts.json');
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return list
          .map((e) => HostConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHosts(List<HostConfig> hosts) async {
    final f = await _file('hosts.json');
    await f.writeAsString(jsonEncode(hosts.map((h) => h.toJson()).toList()));
  }

  // ---- secrets -------------------------------------------------------------

  String _k(String hostId, String field) => 'host.$hostId.$field';

  Future<HostSecrets> loadSecrets(String hostId) async {
    return HostSecrets(
      password: await _secure.read(key: _k(hostId, 'password')),
      privateKey: await _secure.read(key: _k(hostId, 'privateKey')),
      passphrase: await _secure.read(key: _k(hostId, 'passphrase')),
    );
  }

  Future<void> saveSecrets(String hostId, HostSecrets s) async {
    Future<void> put(String field, String? value) async {
      if (value == null || value.isEmpty) {
        await _secure.delete(key: _k(hostId, field));
      } else {
        await _secure.write(key: _k(hostId, field), value: value);
      }
    }

    await put('password', s.password);
    await put('privateKey', s.privateKey);
    await put('passphrase', s.passphrase);
  }

  Future<void> deleteSecrets(String hostId) async {
    for (final f in ['password', 'privateKey', 'passphrase']) {
      await _secure.delete(key: _k(hostId, f));
    }
  }

  // ---- known hosts ---------------------------------------------------------

  Future<Map<String, String>> loadKnownHosts() async {
    try {
      final f = await _file('known_hosts.json');
      if (!await f.exists()) return {};
      return (jsonDecode(await f.readAsString()) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> saveKnownHost(String hostPort, String fingerprint) async {
    final all = await loadKnownHosts();
    all[hostPort] = fingerprint;
    final f = await _file('known_hosts.json');
    await f.writeAsString(jsonEncode(all));
  }

  Future<void> forgetKnownHost(String hostPort) async {
    final all = await loadKnownHosts();
    all.remove(hostPort);
    final f = await _file('known_hosts.json');
    await f.writeAsString(jsonEncode(all));
  }
}

class HostsNotifier extends AsyncNotifier<List<HostConfig>> {
  @override
  Future<List<HostConfig>> build() => HostStore.instance.loadHosts();

  Future<void> upsert(HostConfig host, {HostSecrets? secrets}) async {
    final list = <HostConfig>[...?state.value];
    final i = list.indexWhere((h) => h.id == host.id);
    if (i >= 0) {
      list[i] = host;
    } else {
      list.add(host);
    }
    await HostStore.instance.saveHosts(list);
    if (secrets != null) await HostStore.instance.saveSecrets(host.id, secrets);
    state = AsyncData(list);
  }

  Future<void> remove(String id) async {
    final list = <HostConfig>[...?state.value]..removeWhere((h) => h.id == id);
    await HostStore.instance.saveHosts(list);
    await HostStore.instance.deleteSecrets(id);
    state = AsyncData(list);
  }
}

final hostsProvider =
    AsyncNotifierProvider<HostsNotifier, List<HostConfig>>(HostsNotifier.new);
