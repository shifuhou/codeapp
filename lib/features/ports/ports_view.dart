import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app.dart';
import '../../core/ssh/port_forwarder.dart';
import '../../core/workspace_session.dart';

/// Opens a forwarded port: in-app web view on iOS / macOS, system browser
/// elsewhere (webview_flutter has no Windows/Linux implementation).
Future<void> openForwardedPort(BuildContext context, ForwardedPort fp) async {
  if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PreviewPage(url: fp.localUrl, title: 'Port ${fp.remotePort}'),
    ));
  } else {
    await launchUrl(Uri.parse(fp.localUrl), mode: LaunchMode.externalApplication);
  }
}

class PortsView extends ConsumerWidget {
  const PortsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = ref.watch(workspaceProvider).ports;
    return ListenableBuilder(
      listenable: ports,
      builder: (context, _) {
        final forwarded = ports.forwards.values.toList()..sort((a, b) => a.remotePort - b.remotePort);
        final detected = ports.detected.values.where((d) => !ports.forwards.containsKey(d.port)).toList()
          ..sort((a, b) => a.port - b.port);
        return ListView(
          children: [
            SwitchListTile(
              title: const Text('Auto-forward new ports'),
              value: ports.autoForward,
              onChanged: ports.setAutoForward,
            ),
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('Forward a port…'),
              onTap: () => _manual(context, ports),
            ),
            const Divider(),
            const _Header('Forwarded'),
            if (forwarded.isEmpty) const _Empty('No forwarded ports'),
            for (final fp in forwarded)
              ListTile(
                leading: const Icon(Icons.cable, color: AppColors.ok),
                title: Text('${fp.remotePort} → localhost:${fp.localPort}'),
                subtitle: Text(
                  '${ports.detected[fp.remotePort]?.process ?? ''}'
                  '${fp.connections > 0 ? '  •  ${fp.connections} active' : ''}',
                  style: const TextStyle(color: AppColors.textDim),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Open',
                      icon: const Icon(Icons.open_in_new, size: 18),
                      onPressed: () => openForwardedPort(context, fp),
                    ),
                    IconButton(
                      tooltip: 'Stop forwarding',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        ports.ignored.add(fp.remotePort);
                        ports.stop(fp.remotePort);
                      },
                    ),
                  ],
                ),
                onTap: () => openForwardedPort(context, fp),
              ),
            const Divider(),
            const _Header('Listening on remote'),
            if (detected.isEmpty) const _Empty('Nothing detected yet'),
            for (final d in detected)
              ListTile(
                leading: const Icon(Icons.sensors, color: AppColors.textDim),
                title: Text('${d.port}'),
                subtitle: d.process.isEmpty ? null : Text(d.process, style: const TextStyle(color: AppColors.textDim)),
                trailing: TextButton(
                  onPressed: () async {
                    ports.ignored.remove(d.port);
                    final fp = await ports.forward(d.port);
                    if (context.mounted) openForwardedPort(context, fp);
                  },
                  child: const Text('Forward'),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _manual(BuildContext context, PortForwarder ports) async {
    final remote = TextEditingController();
    final local = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Forward port'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: remote, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Remote port')),
            const SizedBox(height: 12),
            TextField(controller: local, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Local port (optional)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Forward')),
        ],
      ),
    );
    if (ok != true) return;
    final r = int.tryParse(remote.text.trim());
    if (r == null) return;
    ports.ignored.remove(r);
    try {
      await ports.forward(r, localPort: int.tryParse(local.text.trim()));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, color: AppColors.textDim, letterSpacing: 1)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Text(text, style: const TextStyle(color: AppColors.textDim)),
      );
}

class _PreviewPage extends StatefulWidget {
  const _PreviewPage({required this.url, required this.title});
  final String url;
  final String title;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  late final WebViewController _c = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _c.reload()),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            onPressed: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
          ),
        ],
      ),
      body: WebViewWidget(controller: _c),
    );
  }
}
