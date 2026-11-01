import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Exclusive across processes AND Dart isolates. POSIX fcntl locks alone are
/// process-owned, so a second Flutter engine could otherwise become an owner.
/// Keep the original Dart lock for compatibility with existing CLI processes.
class FileLease implements Finalizable {
  FileLease._(this._stream) {
    if (_stream != null) _nativeFinalizer.attach(this, _stream!, detach: this);
  }
  Pointer<Void>? _stream;
  RandomAccessFile? _file;
  bool _closed = false;
  static bool get _posix =>
      Platform.isLinux ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isIOS;
  static final _libc = DynamicLibrary.process();
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final _fdopen = _libc
      .lookupFunction<
        Pointer<Void> Function(Int32, Pointer<Utf8>),
        Pointer<Void> Function(int, Pointer<Utf8>)
      >('fdopen');
  static final _closeDescriptor = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _descriptor = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fileno');
  static final _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isAndroid
            ? '__errno'
            : Platform.isLinux
            ? '__errno_location'
            : '__error',
      );
  // fclose's integer return is deliberately ignored; its pointer argument has
  // the native-finalizer ABI. Group shutdown also releases abandoned leases.
  static final _closePointer = _libc
      .lookup<NativeFunction<Void Function(Pointer<Void>)>>('fclose');
  static final _close = _closePointer
      .asFunction<void Function(Pointer<Void>)>();
  static final _nativeFinalizer = NativeFinalizer(_closePointer);

  static Future<FileLease> acquire(File file, {bool blocking = false}) async {
    Pointer<Void>? stream;
    if (_posix) {
      // A different inode is essential: closing a contender's descriptor on
      // the original inode would release its process's existing fcntl lock.
      final sentinel = File('${file.path}.process');
      if (!await sentinel.exists()) await sentinel.create();
      final path = sentinel.path.toNativeUtf8();
      final mode = 'r+'.toNativeUtf8();
      try {
        // Set close-on-exec atomically with open: another engine can spawn
        // a child between separate fopen and fcntl calls.
        final closeOnExec = Platform.isLinux || Platform.isAndroid
            ? 0x80000
            : 0x1000000;
        final descriptor = _open(path, 2 | closeOnExec, 0);
        if (descriptor < 0) {
          throw FileSystemException('Cannot open isolate lock', sentinel.path);
        }
        stream = _fdopen(descriptor, mode);
        if (stream == nullptr) _closeDescriptor(descriptor);
      } finally {
        malloc.free(path);
        malloc.free(mode);
      }
      if (stream == nullptr) {
        throw FileSystemException('Cannot open isolate lock', sentinel.path);
      }
    }
    final lease = FileLease._(stream);
    try {
      if (stream != null) {
        final descriptor = _descriptor(stream);
        while (true) {
          final error = _errno();
          // LOCK_EX | LOCK_NB: polling avoids blocking the VM's I/O workers.
          if (_flock(descriptor, 6) == 0) break;
          final code = error.value;
          if (!blocking || (code != 11 && code != 35)) {
            throw FileSystemException(
              'File lease unavailable',
              file.path,
              OSError('Lock is held or unavailable', code),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      lease._file = await file.open(mode: FileMode.append);
      await lease._file!.lock(
        blocking ? FileLock.blockingExclusive : FileLock.exclusive,
      );
      return lease;
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _file?.close();
    } finally {
      final stream = _stream;
      if (stream != null) {
        _nativeFinalizer.detach(this);
        // Explicitly release the open-description lock before closing. A child
        // between fork and exec may still temporarily share this description.
        _flock(_descriptor(stream), 8); // LOCK_UN
        _close(stream);
        _stream = null;
      }
    }
  }
}
