import 'dart:io';

import 'package:codeapp/core/storage/host_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses ~/.ssh/config hosts, skipping wildcards', () async {
    final tmp = await Directory.systemTemp.createTemp('codeapp_ssh');
    final sshDir = Directory('${tmp.path}/.ssh')..createSync();
    File('${sshDir.path}/config').writeAsStringSync('''
# comment
Host *
  ServerAliveInterval 60

Host lab
  HostName 10.0.0.5
  User shifu
  Port 2222
  IdentityFile ~/.ssh/id_lab

Host yeserver
    HostName ye.example.com
    User root
''');
    final hosts = await _withHome(tmp.path, () async => HostStore.instance.loadSshConfigHosts());
    expect(hosts.map((h) => h.alias), ['lab', 'yeserver']);
    final lab = hosts[0];
    expect((lab.host, lab.username, lab.port, lab.identityFile), ('10.0.0.5', 'shifu', 2222, '~/.ssh/id_lab'));
    expect(lab.label, 'lab');
    expect(lab.fromSshConfig, isTrue);
    expect(hosts[1].port, 22);
    await tmp.delete(recursive: true);
  });
}

Future<T> _withHome<T>(String home, Future<T> Function() f) async {
  // HostStore reads HOME from the environment; run in a child zone-less way
  // by temporarily pointing HOME at the temp dir via a symlinked process env
  // is not possible in Dart, so we test through an override hook instead.
  HostStore.homeOverride = home;
  try {
    return await f();
  } finally {
    HostStore.homeOverride = null;
  }
}
