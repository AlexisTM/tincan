import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Mirrors the bridge's MediaKind, which decides how a file is shown.
const imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp'];
const videoExtensions = ['mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v'];
const imageTypes = XTypeGroup(label: 'Images', extensions: imageExtensions);
const mediaTypes =
    XTypeGroup(label: 'Images & video', extensions: [...imageExtensions, ...videoExtensions]);

/// file_selector on Android reads a picked file whole into memory and
/// has no save dialog at all, so Android goes through MainActivity's
/// document picker instead.
const _android = MethodChannel('tincan/files');

/// Picks one file, returning a path the app can read, or null. On
/// Android that is a private copy of the chosen document.
Future<String?> pickFile(List<XTypeGroup> groups, {List<String> mimeTypes = const ['*/*']}) async {
  if (Platform.isAndroid) {
    return _android.invokeMethod<String>('pick', {'mimeTypes': mimeTypes});
  }
  return (await openFile(acceptedTypeGroups: groups))?.path;
}

/// Drops the private copy [pickFile] made on Android, once used; any
/// other path is the user's own file.
Future<void> releasePicked(String? path) async {
  if (path == null || !Platform.isAndroid) return;
  await File(path).parent.delete(recursive: true).then((_) {}, onError: (_) {});
}

/// Where the user chose to save a file. Produce it at [path], then
/// [commit]; on Android that copies it out to the chosen document.
class SaveTarget {
  SaveTarget._(this.path, this._uri, this._scratch);

  final String path;
  final String? _uri;
  final Directory? _scratch;

  /// Runs [produce] (which returns an error, or null) and commits.
  Future<String?> write(Future<String?> Function(String path) produce) async {
    String? err;
    try {
      err = await produce(path);
      if (err == null && _uri != null) {
        await _android.invokeMethod<void>('write', {'uri': _uri, 'path': path});
      }
    } catch (e) {
      err = '$e';
    } finally {
      await _scratch?.delete(recursive: true);
    }
    // The picker already created an empty document; don't leave it.
    if (err != null && _uri != null) {
      await _android.invokeMethod<void>('discard', {'uri': _uri}).catchError((_) {});
    }
    return err;
  }
}

/// Asks where to save [suggestedName]; null if the user cancels.
Future<SaveTarget?> chooseSaveTarget(String suggestedName, List<XTypeGroup> groups) async {
  if (!Platform.isAndroid) {
    final loc = await getSaveLocation(suggestedName: suggestedName, acceptedTypeGroups: groups);
    return loc == null ? null : SaveTarget._(loc.path, null, null);
  }
  final uri = await _android.invokeMethod<String>('create', {'name': suggestedName});
  if (uri == null) return null;
  final scratch = await Directory.systemTemp.createTemp('tincan-save-');
  return SaveTarget._(p.join(scratch.path, suggestedName), uri, scratch);
}
