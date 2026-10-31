import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import '../identity/identity.dart';
import '../storage/storage.dart' show validateRelativePath;

/// Persist picker/cache files before enqueueing; callers own retention of copies.
Future<File> stageSourceFile(File source, Directory privateRoot) async {
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const NshareException(
      'source',
      'Selected source is not an ordinary file',
    );
  }
  final name = validateRelativePath(p.basename(source.path));
  final before = await source.stat();
  await privateRoot.create(recursive: true);
  await privatePath(privateRoot.path, directory: true);
  final snapshot = await privateRoot.createTemp('source_');
  try {
    await privatePath(snapshot.path, directory: true);
    final target = await source.copy(p.join(snapshot.path, name));
    final after = await source.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        await target.length() != before.size) {
      throw const NshareException('source', 'Source changed while importing');
    }
    await privatePath(target.path);
    return target;
  } catch (_) {
    await snapshot.delete(recursive: true);
    rethrow;
  }
}
