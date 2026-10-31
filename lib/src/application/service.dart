import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../identity/identity.dart';
import '../transfer/transfer.dart';
import 'queue.dart';
import 'sharing.dart';

enum ServiceApproval { app, terminal, automatic, unavailable }

/// User-local control endpoint. Bearer credentials live in owner-only state.
class LocalService {
  LocalService._(
    this.directory,
    this.identity,
    this.trust,
    this._lock,
    this._http,
    this._token,
    this._onProgress,
  );
  final Directory directory;
  final DeviceIdentity identity;
  final TrustStore trust;
  final RandomAccessFile _lock;
  final HttpServer _http;
  final String _token;
  final ProgressCallback? _onProgress;
  bool _startingReceiver = false;
  Completer<void>? _receiverStartDone;
  static final _owners = <String>{};
  TransferReceiver? receiver;
  ServiceApproval _approvalMode = ServiceApproval.app;
  QueueRunner? _runner;
  Future<void>? _running;
  bool _closed = false;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  bool get isClosed => _closed;
  File get _descriptor => File(p.join(directory.path, 'service.json'));
  Map<String, dynamic> get status => {
    'pid': pid,
    'fingerprint': identity.fingerprint,
    'receiverPort': receiver?.port,
    'stopping': _closed,
    'output': receiver?.output.absolute.path,
    'conflict': receiver?.conflict.name,
    'allowCompression': receiver?.allowCompression,
    'approvalMode': receiver == null ? null : _approvalMode.name,
    'queueRunning': _runner != null,
  };
  static Future<LocalService> start(
    Directory directory,
    DeviceIdentity identity,
    TrustStore trust, {
    ProgressCallback? onProgress,
  }) async {
    final key = p.normalize(p.absolute(directory.path));
    if (!_owners.add(key)) {
      throw const NshareException(
        'busy',
        'A receiver service already owns this state',
      );
    }
    RandomAccessFile? lock;
    HttpServer? http;
    try {
      await directory.create(recursive: true);
      await privatePath(directory.path, directory: true);
      lock = await File(
        p.join(key, 'service-owner.lock'),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
      } on FileSystemException {
        throw const NshareException(
          'busy',
          'A receiver service already owns this state',
        );
      }
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = LocalService._(
        directory,
        identity,
        trust,
        lock,
        http,
        randomNonce(),
        onProgress,
      );
      await atomicJson(service._descriptor, {
        'version': 1,
        'port': http.port,
        'token': service._token,
      });
      http.listen(service._handle);
      final runner = QueueRunner(QueueStore(directory), identity, trust);
      service._runner = runner;
      service._running = runner
          .run(watch: true, onProgress: onProgress)
          .catchError((Object error) {
            service._runner = null;
          });
      return service;
    } catch (_) {
      await http?.close(force: true);
      await lock?.close();
      _owners.remove(key);
      rethrow;
    }
  }

  Future<void> startReceiver({
    required Directory output,
    required OfferApproval approveOffer,
    PairingApproval? approvePeer,
    ClipboardApproval? approveClipboard,
    String? expectedFingerprint,
    bool allowCompression = false,
    ConflictPolicy conflict = ConflictPolicy.refuse,
    ServiceApproval approvalMode = ServiceApproval.app,
    int port = 53317,
    bool discover = true,
    InternetAddress? bind,
    void Function(TransferProgress)? onProgress,
    void Function(TransferResult)? onResult,
    void Function(Object)? onError,
  }) async {
    if (_closed) {
      throw const NshareException('service', 'Receiver service has stopped');
    }
    if (receiver != null || _startingReceiver) {
      throw const NshareException('busy', 'Receiver already running');
    }
    _startingReceiver = true;
    final startDone = Completer<void>();
    _receiverStartDone = startDone;
    try {
      _approvalMode = approvalMode;
      final started = await TransferReceiver.start(
        identity: identity,
        trust: trust,
        output: output,
        approveOffer: approveOffer,
        approvePeer: approvePeer,
        approveClipboard: approveClipboard,
        expectedFingerprint: expectedFingerprint,
        allowCompression: allowCompression,
        conflict: conflict,
        port: port,
        discover: discover,
        bind: bind,
        onProgress: onProgress ?? _onProgress,
        onResult: onResult,
        onError: onError,
      );
      if (_closed) {
        await started.close();
        throw const NshareException('service', 'Receiver service has stopped');
      }
      receiver = started;
    } finally {
      _startingReceiver = false;
      startDone.complete();
      _receiverStartDone = null;
    }
  }

  Future<void> stopReceiver() async {
    final previous = receiver;
    receiver = null;
    await previous?.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/status') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(status));
      } else if (request.method == 'POST' &&
          request.uri.path == '/receive/start') {
        final bytes = <int>[];
        await for (final chunk in request) {
          if (bytes.length + chunk.length > 16384) {
            throw const NshareException(
              'usage',
              'Control request is too large',
            );
          }
          bytes.addAll(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) {
          throw const NshareException(
            'usage',
            'Invalid receiver configuration',
          );
        }
        final output = decoded['output'];
        final port = decoded['port'];
        final accept = decoded['accept'];
        final compression = decoded['allowCompression'];
        final pin = decoded['fingerprint'];
        if (output is! String ||
            output.isEmpty ||
            !p.isAbsolute(output) ||
            port is! int ||
            port < 1 ||
            port > 65535 ||
            accept is! bool ||
            compression is! bool ||
            decoded['conflict'] is! String ||
            !ConflictPolicy.values.any((v) => v.name == decoded['conflict']) ||
            (pin != null &&
                (pin is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)))) {
          throw const NshareException(
            'usage',
            'Invalid receiver configuration',
          );
        }
        await startReceiver(
          output: Directory(output),
          port: port,
          conflict: ConflictPolicy.values.byName(decoded['conflict'] as String),
          expectedFingerprint: pin as String?,
          allowCompression: compression,
          approveOffer: (_) async => accept,
          approvalMode: accept
              ? ServiceApproval.automatic
              : ServiceApproval.unavailable,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(status));
      } else if (request.method == 'POST' && request.uri.path == '/stop') {
        request.response.write('{}');
        try {
          await request.response.close();
        } finally {
          unawaited(close());
        }
        return;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _runner?.stop();
      await _running;
      _runner = null;
      await _receiverStartDone?.future;
      await stopReceiver();
      await _http.close(force: true);
      if (await _descriptor.exists()) await _descriptor.delete();
    } finally {
      await _lock.close();
      _owners.remove(p.normalize(p.absolute(directory.path)));
      if (!_done.isCompleted) _done.complete();
    }
  }
}

class LocalServiceClient {
  LocalServiceClient(this.directory);
  final Directory directory;
  Future<Map<String, dynamic>> request(
    String path, {
    bool post = false,
    Map<String, dynamic>? body,
  }) async {
    final file = File(p.join(directory.path, 'service.json'));
    if (!await file.exists() || await file.length() > 4096) {
      throw const NshareException('service', 'Receiver service is not running');
    }
    final data = jsonDecode(await file.readAsString()) as Map;
    if (data['version'] != 1 ||
        data['port'] is! int ||
        data['port'] < 1 ||
        data['port'] > 65535 ||
        data['token'] is! String) {
      throw const NshareException('state', 'Invalid service descriptor');
    }
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await http.openUrl(
        post ? 'POST' : 'GET',
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: data['port'] as int,
          path: path,
        ),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${data['token']}',
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != 200) {
        throw const NshareException('service', 'Control request rejected');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4096) {
          throw const NshareException('service', 'Control response too large');
        }
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      http.close(force: true);
    }
  }

  Future<Map<String, dynamic>> startReceiver({
    required Directory output,
    required int port,
    required bool accept,
    required bool allowCompression,
    ConflictPolicy conflict = ConflictPolicy.refuse,
    String? expectedFingerprint,
  }) => request(
    '/receive/start',
    post: true,
    body: {
      'output': output.absolute.path,
      'port': port,
      'accept': accept,
      'allowCompression': allowCompression,
      'conflict': conflict.name,
      'fingerprint': expectedFingerprint,
    },
  );
  Future<Map<String, dynamic>> status() => request('/status');
  Future<void> stop() async {
    await request('/stop', post: true);
  }
}
