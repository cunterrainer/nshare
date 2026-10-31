import 'dart:io';
import 'package:nshare/nshare.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late QueueStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nshare_queue_');
    store = QueueStore(root);
  });
  tearDown(() => root.delete(recursive: true));
  Future<TransferJob> add() =>
      store.add('${root.path}/file', '127.0.0.1', 53317, 'a' * 64);
  test('new queue is empty without writing state', () async {
    expect(await store.list(), isEmpty);
    expect(root.listSync(), isEmpty);
  });
  test('concurrent additions retain all jobs', () async {
    await Future.wait(List.generate(20, (_) => add()));
    expect((await QueueStore(root).list()).length, 20);
  });
  test('claim preserves FIFO and persists active state', () async {
    final a = await add();
    final b = await add();
    expect((await store.claim())!.id, a.id);
    expect((await store.claim())!.id, b.id);
    expect(await store.claim(), isNull);
  });
  test(
    'recovery interrupts active jobs and leaves queued work intact',
    () async {
      final a = await add();
      await add();
      await store.claim();
      await store.recover();
      final jobs = await store.list();
      expect(jobs.first.id, a.id);
      expect(jobs.first.status, JobStatus.interrupted);
      expect(jobs.last.status, JobStatus.queued);
    },
  );
  for (final status in JobStatus.values) {
    for (final action in ['pause', 'resume', 'retry', 'cancel', 'remove']) {
      test('$action from ${status.name} enforces lifecycle', () async {
        final job = await add();
        final state = StateStore(root, 'queue');
        await state.update((data) {
          (data['jobs'] as List).first['status'] = status.name;
        });
        final allowed = switch (action) {
          'pause' => [
            JobStatus.queued,
            JobStatus.waitingForPeer,
            ...activeJobStatuses,
            JobStatus.interrupted,
          ].contains(status),
          'resume' => [
            JobStatus.paused,
            JobStatus.interrupted,
          ].contains(status),
          'retry' => [
            JobStatus.failed,
            JobStatus.interrupted,
            JobStatus.cancelled,
          ].contains(status),
          'cancel' => ![
            JobStatus.completed,
            JobStatus.cancelled,
          ].contains(status),
          'remove' => !activeJobStatuses.contains(status),
          _ => false,
        };
        if (allowed) {
          await store.change(job.id, action);
          final jobs = await store.list();
          if (action == 'remove') {
            expect(jobs, isEmpty);
          } else {
            expect(jobs.single.status, switch (action) {
              'pause' => JobStatus.paused,
              'cancel' => JobStatus.cancelled,
              _ => JobStatus.queued,
            });
          }
        } else {
          await expectLater(
            store.change(job.id, action),
            throwsA(isA<NshareException>()),
          );
          expect((await store.list()).single.status, status);
        }
      });
    }
  }
  test('reorder is persisted independently of job ID', () async {
    final a = await add();
    final b = await add();
    await store.change(b.id, 'move', position: 0);
    expect((await store.list()).map((j) => j.id), [b.id, a.id]);
  });
  for (final position in [-1, 2, 999]) {
    test('invalid position $position preserves queue', () async {
      final job = await add();
      await expectLater(
        store.change(job.id, 'move', position: position),
        throwsA(isA<NshareException>()),
      );
      expect((await store.list()).single.id, job.id);
    });
  }
  test('late success does not override explicit pause', () async {
    final job = await add();
    await store.claim();
    await store.change(job.id, 'pause');
    await store.finish(job.id, result: const TransferResult(1, 10));
    expect((await store.list()).single.status, JobStatus.paused);
  });
  test('late failure does not override explicit cancellation', () async {
    final job = await add();
    await store.claim();
    await store.change(job.id, 'cancel');
    await store.finish(
      job.id,
      error: const NshareException('network', 'failed'),
    );
    expect((await store.list()).single.status, JobStatus.cancelled);
  });
  test('completion persists counts', () async {
    final job = await add();
    await store.claim();
    await store.finish(job.id, result: const TransferResult(2, 100));
    final result = (await store.list()).single;
    expect(result.status, JobStatus.completed);
    expect(result.files, 2);
    expect(result.bytes, 100);
  });
  test('failure stores code without clipboard or secret content', () async {
    final job = await add();
    await store.claim();
    await store.finish(
      job.id,
      error: const NshareException('identity', 'private text'),
    );
    expect((await store.list()).single.error, 'identity');
  });
  for (final code in [
    'timeout',
    'network',
    'disconnected',
    'uncertain',
    'busy',
  ]) {
    test('transient $code uses bounded persistent retries', () async {
      final job = await add();
      for (var attempt = 1; attempt <= 4; attempt++) {
        await StateStore(root, 'queue').update((data) {
          final raw = (data['jobs'] as List).first as Map;
          raw['status'] = JobStatus.transferring.name;
          raw['notBefore'] = 0;
        });
        await store.finish(job.id, error: NshareException(code, 'transient'));
        final current = (await store.list()).single;
        expect(current.retryCount, attempt.clamp(0, 3));
        expect(
          current.status,
          attempt <= 3 ? JobStatus.waitingForPeer : JobStatus.failed,
        );
      }
    });
  }
  for (final code in [
    'identity',
    'rejected',
    'integrity',
    'source',
    'protocol',
  ]) {
    test('permanent $code is never retried automatically', () async {
      final job = await add();
      await store.claim();
      await store.finish(job.id, error: NshareException(code, 'permanent'));
      expect((await store.list()).single.status, JobStatus.failed);
      expect((await store.list()).single.retryCount, 0);
    });
  }
}
