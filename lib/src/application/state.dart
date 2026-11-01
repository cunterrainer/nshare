import '../core/file_lock.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../identity/identity.dart';

/// Atomic JSON plus an inter-process lock and an in-process serial executor.
class StateStore {
  StateStore(this.directory, this.name);
  final Directory directory;
  final String name;
  static final _tails = <String, Future<void>>{};
  File get file => File(p.join(directory.path, '$name.json'));
  Future<Map<String, dynamic>> read() async {
    // A pristine profile stays read-only. Once a writer has created its lock,
    // even an absent JSON file must be read inside that writer's transaction.
    if (!await file.exists() && !await File('${file.path}.lock').exists()) {
      return {'version': 1};
    }
    return _locked(_readUnlocked);
  }

  Future<Map<String, dynamic>> _readUnlocked() async {
    if (!await file.exists()) return {'version': 1};
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const NshareException(
        'state',
        'Unsupported or corrupt state version',
      );
    }
    return value;
  }

  Future<T> update<T>(FutureOr<T> Function(Map<String, dynamic>) change) =>
      _locked(() async {
        final data = await _readUnlocked();
        final result = await change(data);
        await atomicJson(file, data);
        return result;
      });

  // Reads participate in the same transaction as replacements. In particular,
  // Windows readers must not hold an open JSON file while a writer renames it,
  // or observe a temporarily absent destination as an empty queue.
  Future<T> _locked<T>(Future<T> Function() action) {
    final key = p.normalize(p.absolute(file.path));
    final result = (_tails[key] ?? Future<void>.value()).then((_) async {
      await directory.create(recursive: true);
      await privatePath(directory.path, directory: true);
      final lock = await FileLease.acquire(File('$key.lock'), blocking: true);
      try {
        return await action();
      } finally {
        await lock.close();
      }
    });
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return result;
  }
}

class AppSettings {
  const AppSettings({
    this.compression = false,
    this.allowCompression = false,
    this.receiveInBackground = false,
    this.startAtLogin = false,
  });
  final bool compression, allowCompression, receiveInBackground, startAtLogin;
  Map<String, dynamic> toJson() => {
    'compression': compression,
    'allowCompression': allowCompression,
    'receiveInBackground': receiveInBackground,
    'startAtLogin': startAtLogin,
  };
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    for (final key in [
      'compression',
      'allowCompression',
      'receiveInBackground',
      'startAtLogin',
    ]) {
      if (json.containsKey(key) && json[key] is! bool) {
        throw NshareException('state', 'Invalid setting: $key');
      }
    }
    return AppSettings(
      compression: json['compression'] == true,
      allowCompression: json['allowCompression'] == true,
      receiveInBackground: json['receiveInBackground'] == true,
      startAtLogin: json['startAtLogin'] == true,
    );
  }
}

class SettingsStore {
  SettingsStore(Directory directory)
    : _store = StateStore(directory, 'settings');
  final StateStore _store;
  Future<AppSettings> load() async => AppSettings.fromJson(await _store.read());
  Future<void> set(String key, bool value) => _store.update((data) {
    if (!const AppSettings().toJson().containsKey(key)) {
      throw NshareException('usage', 'Unknown setting: $key');
    }
    data[key] = value;
    AppSettings.fromJson(data);
  });
}
