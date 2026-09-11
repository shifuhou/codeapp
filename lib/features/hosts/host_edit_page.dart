import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app.dart';
import '../../core/models/host.dart';
import '../../core/storage/host_store.dart';

class HostEditPage extends ConsumerStatefulWidget {
  const HostEditPage({super.key, this.host});
  final HostConfig? host;

  @override
  ConsumerState<HostEditPage> createState() => _HostEditPageState();
}

class _HostEditPageState extends ConsumerState<HostEditPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.host?.name ?? '');
  late final _host = TextEditingController(text: widget.host?.host ?? '');
  late final _port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final _user = TextEditingController(text: widget.host?.username ?? '');
  late final _dir = TextEditingController(text: widget.host?.remoteDir ?? '');
  late final _claude = TextEditingController(text: widget.host?.claudeCommand ?? 'claude');
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  late AuthType _auth = widget.host?.authType ?? AuthType.key;
  late bool _autoForward = widget.host?.autoForwardPorts ?? true;
  bool _loadedSecrets = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    if (h != null) {
      HostStore.instance.loadSecrets(h.id).then((s) {
        if (!mounted) return;
        setState(() {
          _password.text = s.password ?? '';
          _key.text = s.privateKey ?? '';
          _passphrase.text = s.passphrase ?? '';
          _loadedSecrets = true;
        });
      });
    } else {
      _loadedSecrets = true;
    }
  }

  Future<void> _pickKeyFile() async {
    final res = await FilePicker.platform.pickFiles(withData: true);
    final f = res?.files.single;
    if (f == null) return;
    String? text;
    if (f.bytes != null) {
      text = String.fromCharCodes(f.bytes!);
    } else if (f.path != null) {
      text = await File(f.path!).readAsString();
    }
    if (text != null) setState(() => _key.text = text!);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final h = widget.host?.copy() ??
        HostConfig(
          id: const Uuid().v4(),
          name: '',
          host: '',
          username: '',
        );
    h
      ..name = _name.text.trim()
      ..host = _host.text.trim()
      ..port = int.tryParse(_port.text.trim()) ?? 22
      ..username = _user.text.trim()
      ..authType = _auth
      ..remoteDir = _dir.text.trim()
      ..claudeCommand = _claude.text.trim().isEmpty ? 'claude' : _claude.text.trim()
      ..autoForwardPorts = _autoForward;
    await ref.read(hostsProvider.notifier).upsert(
          h,
          secrets: HostSecrets(
            password: _password.text,
            privateKey: _key.text,
            passphrase: _passphrase.text,
          ),
        );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.host == null ? 'Add host' : 'Edit host'),
        actions: [
          TextButton(
            onPressed: _saving || !_loadedSecrets ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: 'Host / IP'),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                    autocorrect: false,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                    validator: (v) => int.tryParse((v ?? '').trim()) == null ? 'Number' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            SegmentedButton<AuthType>(
              segments: const [
                ButtonSegment(value: AuthType.key, label: Text('Private key'), icon: Icon(Icons.key)),
                ButtonSegment(value: AuthType.password, label: Text('Password'), icon: Icon(Icons.password)),
              ],
              selected: {_auth},
              onSelectionChanged: (s) => setState(() => _auth = s.first),
            ),
            const SizedBox(height: 12),
            if (_auth == AuthType.password)
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              )
            else ...[
              TextFormField(
                controller: _key,
                decoration: InputDecoration(
                  labelText: 'Private key (PEM / OpenSSH)',
                  helperText: 'Paste the contents of id_ed25519 / id_rsa',
                  suffixIcon: IconButton(
                    tooltip: 'Pick file',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickKeyFile,
                  ),
                ),
                maxLines: 4,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                autocorrect: false,
                validator: (v) => _auth == AuthType.key && (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                decoration: const InputDecoration(labelText: 'Key passphrase (optional)'),
                obscureText: true,
              ),
            ],
            const SizedBox(height: 20),
            const Text('Workspace', style: TextStyle(color: AppColors.textDim)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _dir,
              decoration: const InputDecoration(
                labelText: 'Remote directory',
                helperText: 'Project folder for files, terminal and Claude. Empty = home.',
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _claude,
              decoration: const InputDecoration(
                labelText: 'Claude command',
                helperText: 'Usually "claude". Use a full path if it is not on PATH.',
              ),
              autocorrect: false,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-forward new ports'),
              subtitle: const Text('Forward ports that start listening on the remote, like VS Code'),
              value: _autoForward,
              onChanged: (v) => setState(() => _autoForward = v),
            ),
          ],
        ),
      ),
    );
  }
}
