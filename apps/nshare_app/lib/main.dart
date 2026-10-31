import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'desktop.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nshare/nshare.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) FlutterForegroundTask.initCommunicationPort();
  final controller = NshareController();
  if (!Platform.isAndroid && !Platform.isIOS) {
    await DesktopIntegration(controller).initialize();
  }
  runApp(NshareApp(controller: controller));
}

class NshareApp extends StatelessWidget {
  const NshareApp({super.key, required this.controller});
  final NshareController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'nshare',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff3659b8)),
      useMaterial3: true,
    ),
    home: NshareHome(controller: controller),
  );
}

class NshareHome extends StatefulWidget {
  const NshareHome({super.key, required this.controller});
  final NshareController controller;
  @override
  State<NshareHome> createState() => _HomeState();
}

class _HomeState extends State<NshareHome> with WidgetsBindingObserver {
  int page = 0;
  bool resumeReceiver = false;
  final ownHost = TextEditingController();
  final host = TextEditingController(),
      port = TextEditingController(text: '53317'),
      pin = TextEditingController(),
      source = TextEditingController(),
      invite = TextEditingController();
  NshareController get c => widget.controller;
  static const labels = [
    'Devices',
    'Send',
    'Receive',
    'Queue',
    'History',
    'Settings',
  ];
  static const icons = [
    Icons.devices,
    Icons.send,
    Icons.download,
    Icons.queue,
    Icons.history,
    Icons.settings,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.confirm = confirm;
    c.confirmClipboard = clipboardApproval;
    c.addListener(changed);
    if (!c.ready) unawaited(c.initialize());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<bool> confirm(String title, String details) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(child: SelectableText(details)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Approve'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> clipboardApproval(ClipboardOffer offer) async {
    final accepted = await confirm(
      'Incoming clipboard text',
      'From ${offer.peer.name}. Copy this text to your clipboard?\n\n${offer.text}',
    );
    if (accepted) await Clipboard.setData(ClipboardData(text: offer.text));
    return accepted;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((Platform.isIOS ||
            (Platform.isAndroid && !c.settings.receiveInBackground)) &&
        state == AppLifecycleState.paused &&
        c.service?.receiver != null) {
      resumeReceiver = true;
      unawaited(c.stopReceiver());
    } else if ((Platform.isIOS ||
            (Platform.isAndroid && !c.settings.receiveInBackground)) &&
        state == AppLifecycleState.resumed &&
        resumeReceiver) {
      resumeReceiver = false;
      unawaited(c.perform(() => c.startReceiver()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(changed);
    ownHost.dispose();
    for (final field in [host, port, pin, source, invite]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool folder) async {
    String? path;
    if (folder) {
      path = c.mobile
          ? await const MethodChannel(
              'dev.nshare/files',
            ).invokeMethod<String>('importFolder')
          : await FilePicker.platform.getDirectoryPath();
    } else {
      path = (await FilePicker.platform.pickFiles(
        allowMultiple: false,
      ))?.files.single.path;
    }
    if (path != null) {
      source.text = path;
      if (mounted) setState(() => page = 1);
    }
  }

  Widget field(
    String label,
    TextEditingController controller, {
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  int targetPort() {
    final value = int.tryParse(port.text);
    if (value == null || value < 1 || value > 65535) {
      throw const NshareException('usage', 'Port must be 1–65535');
    }
    return value;
  }

  Widget target() => Column(
    children: [
      field('IP address or hostname', host),
      field('Port', port),
      field('Verified full SHA-256 fingerprint', pin),
    ],
  );
  Widget action(String label, Future<void> Function() work, {IconData? icon}) =>
      Padding(
        padding: const EdgeInsets.all(4),
        child: FilledButton.tonalIcon(
          onPressed: c.busy ? null : () => unawaited(c.perform(work)),
          icon: Icon(icon ?? Icons.arrow_forward),
          label: Text(label),
        ),
      );
  Widget devices() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        children: [
          action(
            c.searching ? 'Searching…' : 'Refresh nearby devices',
            () => c.search(),
            icon: Icons.refresh,
          ),
          action('Enter address manually', () async {
            setState(() => page = 1);
          }),
        ],
      ),
      const Text(
        'Discovery locates devices. Verify identity before trusting a new peer.',
      ),
      if (c.devices.isEmpty && !c.searching)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No nearby receivers. Start receiving on the other device, or enter its IP address.',
          ),
        ),
      for (final device in c.devices)
        Card(
          child: ListTile(
            title: Text(device.name),
            subtitle: Text(
              '${device.address}:${device.port}${device.remembered ? ' (saved; reachability unverified)' : ''}\n${device.fingerprint}',
            ),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              host.text = device.address;
              port.text = '${device.port}';
              pin.text = device.fingerprint;
              setState(() => page = 1);
              unawaited(
                c.perform(() async {
                  if (!await confirm(
                    'Verify discovered identity',
                    'Compare this fingerprint on the other device before using it:\n${device.fingerprint}',
                  )) {
                    pin.clear();
                  }
                }),
              );
            },
          ),
        ),
      const Divider(),
      const Text('Pair without a camera'),
      field('Paste invitation from a trusted device', invite, lines: 3),
      action('Pair using invitation', () => c.join(invite.text)),
      if (Platform.isAndroid || Platform.isIOS)
        action('Scan pairing QR', scan, icon: Icons.qr_code_scanner),
    ],
  );
  Widget send() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        children: [
          action(
            'Choose file',
            () => pick(false),
            icon: Icons.insert_drive_file,
          ),
          action('Choose folder', () => pick(true), icon: Icons.folder),
        ],
      ),
      field('File or folder path', source),
      target(),
      Text(
        'Compression: ${c.settings.compression ? 'enabled by your setting' : 'off'}',
      ),
      Wrap(
        children: [
          action('Add to transfer queue', () async {
            if (source.text.isEmpty || host.text.isEmpty) {
              throw const NshareException(
                'usage',
                'Choose a source and target',
              );
            }
            if (!await confirm(
              'Confirm target identity',
              'Use this verified fingerprint?\n${pin.text}',
            )) {
              return;
            }
            await c.enqueue(source.text, host.text, targetPort(), pin.text);
            setState(() => page = 3);
          }, icon: Icons.queue),
          action('Send clipboard text', () async {
            if (await confirm(
              'Send clipboard',
              'Send current clipboard text to this verified fingerprint?\n${pin.text}',
            )) {
              await c.sendClipboard(host.text, targetPort(), pin.text);
            }
          }, icon: Icons.content_paste),
        ],
      ),
    ],
  );
  Widget receive() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        c.receiverDescription,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      SelectableText('Destination: ${c.receiveDirectory?.path ?? 'Loading…'}'),
      const Text(
        'Each incoming transfer and clipboard offer requires approval.',
      ),
      if (Platform.isIOS)
        const Text(
          'iOS receiving works while this app is active. Suspended apps cannot stay reachable.',
        ),
      if (Platform.isAndroid)
        const Text(
          'Background receiving requires an ongoing foreground-service notification.',
        ),
      Wrap(
        children: [
          action(
            c.receiving ? 'Stop receiving' : 'Start receiving',
            () => c.receiving ? c.stopReceiver() : c.startReceiver(),
            icon: c.receiving ? Icons.stop : Icons.play_arrow,
          ),
          if (!c.mobile)
            action('Choose destination', () async {
              final value = await FilePicker.platform.getDirectoryPath();
              if (value != null) {
                if (c.receiving) {
                  throw const NshareException(
                    'busy',
                    'Stop receiving before changing destination',
                  );
                }
                await c.setReceiveDirectory(Directory(value));
              }
            }),
        ],
      ),
      if (c.mobile)
        action('Export received folder', () async {
          if (c.receiving) {
            throw const NshareException(
              'busy',
              'Stop receiving before exporting a consistent copy',
            );
          }
          await const MethodChannel('dev.nshare/files').invokeMethod<String>(
            'exportFolder',
            {'path': c.receiveDirectory!.path},
          );
        }, icon: Icons.folder_copy),
      const Divider(),
      const Text(
        'Display a pairing QR or copy its invitation. A PC does not need a camera.',
      ),
      field('This device’s reachable LAN IP address', ownHost),
      action('Choose this device IP', () async {
        final addresses = await localAddresses();
        if (!mounted) return;
        final value = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Local network addresses'),
            children: [
              for (final address in addresses)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, address.address),
                  child: Text('${address.interfaceName}: ${address.address}'),
                ),
              if (addresses.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No local addresses found.'),
                ),
            ],
          ),
        );
        if (value != null) ownHost.text = value;
      }),
      action(
        'Create five-minute invitation',
        () => c.makeInvitation(ownHost.text),
        icon: Icons.qr_code,
      ),
      if (c.invitation != null) ...[
        Semantics(
          label: 'Pairing QR code',
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: QrImageView(data: c.invitation!.uri.toString(), size: 260),
          ),
        ),
        SelectableText(c.invitation!.uri.toString()),
        action(
          'Copy invitation',
          () => Clipboard.setData(
            ClipboardData(text: c.invitation!.uri.toString()),
          ),
        ),
      ],
      if (c.identity != null)
        SelectableText('This device fingerprint:\n${c.identity!.fingerprint}'),
    ],
  );
  Widget queue(bool history) {
    final jobs = c.jobs
        .where(
          (j) =>
              [
                JobStatus.completed,
                JobStatus.failed,
                JobStatus.cancelled,
              ].contains(j.status) ==
              history,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          history ? 'Transfer history' : 'Persistent transfer queue',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (jobs.isEmpty) const Text('No transfers here yet.'),
        for (final job in jobs)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(job.path),
                  Text('${job.host}:${job.port} • ${job.status.name}'),
                  if (job.error != null) Text('Error: ${job.error}'),
                  if (job.status == JobStatus.completed)
                    Text('${job.files} verified files, ${job.bytes} bytes'),
                  Wrap(
                    children: [
                      if ([
                        JobStatus.queued,
                        ...activeJobStatuses,
                        JobStatus.interrupted,
                      ].contains(job.status))
                        action('Pause', () => c.queueAction(job.id, 'pause')),
                      if ([
                        JobStatus.paused,
                        JobStatus.interrupted,
                      ].contains(job.status))
                        action('Resume', () => c.queueAction(job.id, 'resume')),
                      if ([
                        JobStatus.failed,
                        JobStatus.cancelled,
                      ].contains(job.status))
                        action('Retry', () => c.queueAction(job.id, 'retry')),
                      if (![
                        JobStatus.completed,
                        JobStatus.cancelled,
                      ].contains(job.status))
                        action('Cancel', () => c.queueAction(job.id, 'cancel')),
                      if (!activeJobStatuses.contains(job.status))
                        action('Remove', () => c.queueAction(job.id, 'remove')),
                      if (!history)
                        action(
                          'Move to front',
                          () => c.queueAction(job.id, 'move', position: 0),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget settings() => Column(
    children: [
      SwitchListTile(
        title: const Text('Compress outgoing transfers'),
        subtitle: const Text(
          'Off by default. Receiver must also permit compression.',
        ),
        value: c.settings.compression,
        onChanged: c.busy
            ? null
            : (v) => unawaited(c.perform(() => c.setSetting('compression', v))),
      ),
      SwitchListTile(
        title: const Text('Allow incoming compression'),
        subtitle: const Text(
          'Explicit permission to decompress received file blocks.',
        ),
        value: c.settings.allowCompression,
        onChanged: c.receiving
            ? null
            : (v) => unawaited(
                c.perform(() => c.setSetting('allowCompression', v)),
              ),
      ),
      SwitchListTile(
        title: const Text('Keep receiving in background'),
        subtitle: Text(
          Platform.isIOS
              ? 'iOS requires the app to remain active.'
              : Platform.isAndroid
              ? 'Uses an ongoing notification. Stop receiving before changing.'
              : 'Keep the application running in the system tray.',
        ),
        value: c.settings.receiveInBackground,
        onChanged: (Platform.isIOS || c.receiving)
            ? null
            : (v) => unawaited(
                c.perform(() => c.setSetting('receiveInBackground', v)),
              ),
      ),
      if (!c.mobile)
        SwitchListTile(
          title: const Text('Start at login'),
          value: c.settings.startAtLogin,
          onChanged: (v) =>
              unawaited(c.perform(() => c.setSetting('startAtLogin', v))),
        ),
      const ListTile(
        title: Text('Local network only'),
        subtitle: Text(
          'No accounts, relays, cloud pairing, or Internet service required.',
        ),
      ),
      action('Manage trusted peers', () async {
        final peers = await c.trustedPeers();
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Trusted peers'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (peers.isEmpty) const Text('No trusted peers'),
                    for (final peer in peers.entries)
                      ListTile(
                        title: Text((peer.value as Map)['name'].toString()),
                        subtitle: SelectableText(peer.key),
                        trailing: IconButton(
                          tooltip: 'Forget peer',
                          icon: const Icon(Icons.delete),
                          onPressed: () async {
                            await c.forget(peer.key);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }),
    ],
  );
  Future<void> scan() async {
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (result != null) await c.join(result);
  }

  @override
  Widget build(BuildContext context) {
    final content = !c.ready
        ? Center(
            child: c.error == null
                ? const CircularProgressIndicator()
                : SelectableText(c.error!),
          )
        : SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (c.error != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(c.error!),
                    ),
                  ),
                if (c.busy) const LinearProgressIndicator(),
                if (c.progress != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${c.progress!.phase.name}: ${c.progress!.bytes}/${c.progress!.total} bytes',
                    ),
                  ),
                switch (page) {
                  0 => devices(),
                  1 => send(),
                  2 => receive(),
                  3 => queue(false),
                  4 => queue(true),
                  _ => settings(),
                },
              ],
            ),
          );
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 850;
        return Scaffold(
          appBar: AppBar(
            title: const Text('nshare'),
            actions: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: Text(c.receiving ? 'Receiving' : 'Receiver off'),
                ),
              ),
            ],
          ),
          body: Row(
            children: [
              if (wide)
                NavigationRail(
                  selectedIndex: page,
                  onDestinationSelected: (v) => setState(() => page = v),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationRailDestination(
                        icon: Icon(icons[i]),
                        label: Text(labels[i]),
                      ),
                  ],
                ),
              Expanded(child: content),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: page,
                  onDestinationSelected: (v) => setState(() => page = v),
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationDestination(
                        icon: Icon(icons[i]),
                        label: labels[i],
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanState();
}

class _ScanState extends State<ScanPage> {
  bool found = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan trusted device invitation')),
    body: MobileScanner(
      onDetect: (capture) {
        if (found) return;
        for (final barcode in capture.barcodes) {
          final text = barcode.rawValue;
          if (text != null && text.startsWith('nshare://pair')) {
            found = true;
            Navigator.pop(context, text);
            break;
          }
        }
      },
      errorBuilder: (context, error) => Center(
        child: Text(
          'Camera unavailable: ${error.errorCode.name}. Use a copied invitation instead.',
        ),
      ),
    ),
  );
}
