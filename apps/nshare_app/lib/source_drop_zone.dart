import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:nshare/nshare.dart';
import 'package:path/path.dart' as p;

/// Dropping selects sources. Transfer still requires explicit target confirmation.
class SourceDropZone extends StatefulWidget {
  const SourceDropZone({
    super.key,
    required this.enabled,
    required this.onPaths,
    required this.onError,
    required this.persistFile,
    required this.child,
  });
  final bool enabled;
  final Future<void> Function(List<String>) onPaths;
  final void Function(Object) onError;
  final Future<String> Function(String) persistFile;
  final Widget child;
  @override
  State<SourceDropZone> createState() => _SourceDropZoneState();
}

class _SourceDropZoneState extends State<SourceDropZone> {
  bool hovering = false, importing = false;
  Future<void> dropped(DropDoneDetails details) async {
    if (importing) return;
    setState(() {
      hovering = false;
      importing = true;
    });
    try {
      if (details.files.isEmpty || details.files.length > 1024) {
        throw const NshareException(
          'source',
          'Drop between 1 and 1024 local files or folders',
        );
      }
      final paths = <String>{};
      for (final file in details.files) {
        final path = p.normalize(p.absolute(file.path));
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory) {
          throw const NshareException(
            'source',
            'Drop ordinary local files or folders; links are not followed',
          );
        }
        if (file.fromPromise && type == FileSystemEntityType.directory) {
          throw const NshareException(
            'source',
            'Choose this folder using the folder picker to retain it for queued transfers',
          );
        }
        paths.add(file.fromPromise ? await widget.persistFile(path) : path);
      }
      if (mounted) await widget.onPaths(paths.toList());
    } catch (error) {
      if (mounted) widget.onError(error);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return DropTarget(
      onDragEntered: (_) => setState(() => hovering = true),
      onDragExited: (_) => setState(() => hovering = false),
      onDragDone: dropped,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(
            color: hovering
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              importing
                  ? 'Preparing dropped sources…'
                  : 'Drop files or folders here',
            ),
            widget.child,
          ],
        ),
      ),
    );
  }
}
