import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/models.dart';

/// Desktop CLI and Flutter use the same identity/settings/queue by default.
Directory defaultStateDirectory() {
  final env = Platform.environment;
  final base = Platform.isWindows ? env['APPDATA'] : env['XDG_CONFIG_HOME'];
  if (base != null && base.isNotEmpty) return Directory(p.join(base, 'nshare'));
  final home = env[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (home == null) {
    throw const NshareException(
      'usage',
      'Supply a state directory when HOME is unavailable',
    );
  }
  return Directory(p.join(home, '.config', 'nshare'));
}
