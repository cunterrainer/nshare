import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../identity/identity.dart';
import '../transfer/transfer.dart';
import 'queue.dart';
import 'sharing.dart';

/// User-local control endpoint. Bearer credentials live in owner-only state.
class LocalService {
  LocalService._(
    this.directory,
    this.identity,
    this.trust,
    this._lock,
    this._http,
    this._token,
  );
  final Directory directory;
  final DeviceIdentity identity;
  final TrustStore trust;
  final RandomAccessFile _lock;
  final HttpServer _http;
  final String _token;
  static final _owners = <String>{};
  TransferReceiver? receiver;
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
    if (receiver != null) {
      throw const NshareException('busy', 'Receiver already running');
    }
    receiver = await TransferReceiver.start(
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
      onProgress: onProgress,
      onResult: onResult,
      onError: onError,
    );
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
      } else if (request.method == 'POST' && request.uri.path == '/stop') {
        request.response.write('{}');
        await request.response.close();
        unawaited(close());
        return;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _runner?.stop();
      await _running;
      _runner = null;
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
  Future<Map<String, dynamic>> request(String path, {bool post = false}) async {
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

  Future<Map<String, dynamic>> status() => request('/status');
  Future<void> stop() async {
    await request('/stop', post: true);
  }
}
