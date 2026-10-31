import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../identity/identity.dart';
import '../transfer/transfer.dart';
import 'state.dart';

enum JobStatus {
  waitingForPeer,
  scanning,
  connecting,
  awaitingApproval,
  verifying,
  queued,
  transferring,
  paused,
  interrupted,
  completed,
  failed,
  cancelled,
}

const activeJobStatuses = {
  JobStatus.scanning,
  JobStatus.connecting,
  JobStatus.awaitingApproval,
  JobStatus.transferring,
  JobStatus.verifying,
};

class TransferJob {
  TransferJob({
    required this.id,
    required this.path,
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.compression,
    required this.status,
    this.error,
    this.files = 0,
    this.bytes = 0,
    this.retryCount = 0,
    this.notBefore = 0,
    this.resume = true,
  });
  final String id, path, host, fingerprint;
  final int port, files, bytes, retryCount, notBefore;
  final bool compression, resume;
  final JobStatus status;
  final String? error;
  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'host': host,
    'port': port,
    'fingerprint': fingerprint,
    'compression': compression,
    'resume': resume,
    'status': status.name,
    'error': error,
    'files': files,
    'bytes': bytes,
    'retryCount': retryCount,
    'notBefore': notBefore,
  };
  factory TransferJob.fromJson(Map<String, dynamic> json) {
    try {
      final job = TransferJob(
        id: json['id'] as String,
        path: json['path'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        fingerprint: json['fingerprint'] as String,
        compression: json['compression'] as bool,
        resume: json['resume'] as bool? ?? true,
        status: JobStatus.values.byName(json['status'] as String),
        error: json['error'] as String?,
        files: json['files'] as int? ?? 0,
        bytes: json['bytes'] as int? ?? 0,
        retryCount: json['retryCount'] as int? ?? 0,
        notBefore: json['notBefore'] as int? ?? 0,
      );
      if (job.id.isEmpty ||
          !p.isAbsolute(job.path) ||
          job.host.isEmpty ||
          job.port < 1 ||
          job.port > 65535 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(job.fingerprint) ||
          job.files < 0 ||
          job.bytes < 0 ||
          job.retryCount < 0 ||
          job.retryCount > 3 ||
          job.notBefore < 0) {
        throw const FormatException();
      }
      return job;
    } catch (_) {
      throw const NshareException('state', 'Invalid queue job');
    }
  }
}

class QueueStore {
  QueueStore(this.directory) : _store = StateStore(directory, 'queue');
  final Directory directory;
  final StateStore _store;
  List<Map<String, dynamic>> _jobs(Map<String, dynamic> data) {
    final value = data['jobs'] ?? <dynamic>[];
    if (value is! List) throw const NshareException('state', 'Invalid queue');
    final jobs = value
        .map(
          (v) => TransferJob.fromJson(
            Map<String, dynamic>.from(v as Map),
          ).toJson(),
        )
        .toList();
    if (jobs.map((v) => v['id']).toSet().length != jobs.length) {
      throw const NshareException('state', 'Duplicate job IDs');
    }
    return jobs;
  }

  Future<List<TransferJob>> list() async =>
      _jobs(await _store.read()).map(TransferJob.fromJson).toList();
  Future<TransferJob> add(
    String path,
    String host,
    int port,
    String fingerprint, {
    bool compression = false,
    bool resume = true,
  }) async {
    final job = TransferJob.fromJson(
      TransferJob(
        id: randomNonce().replaceAll('=', ''),
        path: p.normalize(p.absolute(path)),
        host: host,
        port: port,
        fingerprint: fingerprint.toLowerCase(),
        compression: compression,
        resume: resume,
        status: JobStatus.queued,
      ).toJson(),
    );
    await _store.update((data) {
      final jobs = _jobs(data);
      if (jobs.length >= 10000) {
        throw const NshareException('limit', 'Queue contains 10000 jobs');
      }
      jobs.add(job.toJson());
      data['jobs'] = jobs;
    });
    return job;
  }

  Future<void> change(String id, String action, {int? position}) =>
      _store.update((data) {
        final jobs = _jobs(data);
        final index = jobs.indexWhere((v) => v['id'] == id);
        if (index < 0) throw const NshareException('usage', 'Unknown job ID');
        final job = jobs[index];
        final status = JobStatus.values.byName(job['status'] as String);
        switch (action) {
          case 'pause':
            if (![
              JobStatus.queued,
              JobStatus.waitingForPeer,
              ...activeJobStatuses,
              JobStatus.interrupted,
            ].contains(status)) {
              throw const NshareException('usage', 'Job cannot be paused');
            }
            job['status'] = JobStatus.paused.name;
          case 'resume':
            if (![JobStatus.paused, JobStatus.interrupted].contains(status)) {
              throw const NshareException('usage', 'Job cannot be resumed');
            }
            job['status'] = JobStatus.queued.name;
            job['error'] = null;
            job['resume'] = true;
            job['notBefore'] = 0;
          case 'retry':
            if (![
              JobStatus.failed,
              JobStatus.interrupted,
              JobStatus.cancelled,
            ].contains(status)) {
              throw const NshareException('usage', 'Job cannot be retried');
            }
            job['status'] = JobStatus.queued.name;
            job['error'] = null;
            job['resume'] = true;
            job['notBefore'] = 0;
            job['retryCount'] = 0;
          case 'restart':
            if (![
              JobStatus.failed,
              JobStatus.interrupted,
              JobStatus.cancelled,
              JobStatus.paused,
            ].contains(status)) {
              throw const NshareException(
                'usage',
                'Pause or stop a job before restarting',
              );
            }
            job['status'] = JobStatus.queued.name;
            job['resume'] = false;
            job['retryCount'] = 0;
            job['notBefore'] = 0;
            job['error'] = null;
          case 'cancel':
            if ([JobStatus.completed, JobStatus.cancelled].contains(status)) {
              throw const NshareException('usage', 'Job already terminal');
            }
            job['status'] = JobStatus.cancelled.name;
          case 'move':
            if (position == null || position < 0 || position >= jobs.length) {
              throw const NshareException('usage', 'Invalid queue position');
            }
            jobs.removeAt(index);
            jobs.insert(position, job);
          case 'remove':
            if (activeJobStatuses.contains(status)) {
              throw const NshareException(
                'usage',
                'Cancel an active job before removing it',
              );
            }
            jobs.removeAt(index);
          default:
            throw const NshareException('usage', 'Unknown queue action');
        }
        data['jobs'] = jobs;
      });
  Future<void> recover() => _store.update((data) {
    final jobs = _jobs(data);
    for (final job in jobs) {
      if (activeJobStatuses.any((s) => s.name == job['status'])) {
        job['status'] = JobStatus.interrupted.name;
        job['error'] = 'Receiver owner stopped; resume explicitly';
      }
    }
    data['jobs'] = jobs;
  });
  Future<TransferJob?> claim() => _store.update((data) {
    final jobs = _jobs(data);
    final index = jobs.indexWhere(
      (v) =>
          [
            JobStatus.queued.name,
            JobStatus.waitingForPeer.name,
          ].contains(v['status']) &&
          (v['notBefore'] as int) <= DateTime.now().millisecondsSinceEpoch,
    );
    if (index < 0) return null;
    jobs[index]['status'] = JobStatus.scanning.name;
    data['jobs'] = jobs;
    return TransferJob.fromJson(jobs[index]);
  });
  Future<void> phase(String id, TransferPhase phase) => _store.update((data) {
    final jobs = _jobs(data);
    final index = jobs.indexWhere((j) => j['id'] == id);
    if (index < 0 ||
        !activeJobStatuses.any((s) => s.name == jobs[index]['status'])) {
      return;
    }
    final status = switch (phase) {
      TransferPhase.scanning => JobStatus.scanning,
      TransferPhase.connecting => JobStatus.connecting,
      TransferPhase.awaitingApproval => JobStatus.awaitingApproval,
      TransferPhase.verifying => JobStatus.verifying,
      TransferPhase.transferring => JobStatus.transferring,
      TransferPhase.complete => null,
    };
    if (status != null) jobs[index]['status'] = status.name;
    data['jobs'] = jobs;
  });
  Future<void> finish(String id, {TransferResult? result, Object? error}) =>
      _store.update((data) {
        final jobs = _jobs(data);
        final index = jobs.indexWhere((v) => v['id'] == id);
        if (index < 0) return;
        final job = jobs[index];
        // User pause/cancel wins over an in-flight network completion.
        if (activeJobStatuses.any((s) => s.name == job['status'])) {
          final transient =
              error is SocketException ||
              error is TimeoutException ||
              (error is NshareException &&
                  [
                    'network',
                    'timeout',
                    'disconnected',
                    'uncertain',
                    'busy',
                  ].contains(error.code));
          final attempts = job['retryCount'] as int;
          if (result == null && transient && attempts < 3) {
            job['retryCount'] = attempts + 1;
            job['notBefore'] = DateTime.now()
                .add(Duration(seconds: 1 << attempts))
                .millisecondsSinceEpoch;
            job['status'] = JobStatus.waitingForPeer.name;
          } else {
            job['status'] =
                (result != null ? JobStatus.completed : JobStatus.failed).name;
          }

          job['error'] = error is NshareException
              ? error.code
              : error == null
              ? null
              : 'transfer';
          if (result != null) {
            job['files'] = result.files;
            job['bytes'] = result.bytes;
          }
        }
        data['jobs'] = jobs;
      });
}

/// Holds the lock for its lifetime: only one runner may recover and claim jobs.
class QueueRunner {
  QueueRunner(this.store, this.identity, this.trust);
  final QueueStore store;
  final DeviceIdentity identity;
  final TrustStore trust;
  static final _owners = <String>{};
  final stopped = CancellationToken();
  CancellationToken? _active;
  void stop() {
    stopped.cancel();
    _active?.cancel();
  }

  Future<void> run({
    bool watch = false,
    void Function(TransferProgress)? onProgress,
  }) async {
    final key = p.normalize(p.absolute(store.directory.path));
    if (!_owners.add(key)) {
      throw const NshareException(
        'busy',
        'A queue runner already owns this state',
      );
    }
    RandomAccessFile? lock;
    try {
      await store.directory.create(recursive: true);
      lock = await File(
        p.join(key, 'queue-owner.lock'),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
      } on FileSystemException {
        throw const NshareException(
          'busy',
          'A queue runner already owns this state',
        );
      }
      await store.recover();
      while (!stopped.isCancelled) {
        final job = await store.claim();
        if (job == null) {
          if (!watch &&
              !(await store.list()).any(
                (j) => j.status == JobStatus.waitingForPeer,
              )) {
            break;
          }
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 250)),
            stopped.whenCancelled,
          ]);
          continue;
        }
        final cancellation = CancellationToken();
        _active = cancellation;
        var polling = false;
        final timer = Timer.periodic(const Duration(milliseconds: 150), (
          _,
        ) async {
          if (polling) return;
          polling = true;
          try {
            final jobs = await store.list();
            final current = jobs.where((v) => v.id == job.id).firstOrNull;
            if (current == null ||
                !activeJobStatuses.contains(current.status)) {
              cancellation.cancel();
            }
          } catch (_) {
            cancellation.cancel();
          } finally {
            polling = false;
          }
        });
        TransferPhase? previousPhase;
        var lastPhaseSaved = DateTime.fromMillisecondsSinceEpoch(0);
        try {
          final result = await sendPath(
            job.path,
            job.host,
            job.port,
            identity,
            trust,
            expectedFingerprint: job.fingerprint,
            compression: job.compression,
            resume: job.resume,
            cancellation: cancellation,
            onProgress: (progress) {
              if (previousPhase != progress.phase &&
                  DateTime.now().difference(lastPhaseSaved).inMilliseconds >=
                      250) {
                previousPhase = progress.phase;
                lastPhaseSaved = DateTime.now();
                unawaited(
                  store.phase(job.id, progress.phase).catchError((
                    Object error,
                  ) {
                    cancellation.cancel();
                  }),
                );
              }
              onProgress?.call(progress);
            },
          );
          await store.finish(job.id, result: result);
        } catch (error) {
          if (stopped.isCancelled) {
            // Shutdown is recoverable, not a failed or implicitly retried transfer.
            await store.recover();
          } else {
            await store.finish(job.id, error: error);
          }
        } finally {
          timer.cancel();
          _active = null;
        }
      }
    } finally {
      await lock?.close();
      _owners.remove(key);
    }
  }
}
