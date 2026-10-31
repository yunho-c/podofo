import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// macOS bookmarks live in the app's native preferences, shared by session and
/// recent-history paths. Other platforms keep their ordinary filesystem access.
class DocumentFileAccess {
  static const channel = MethodChannel('podofo/file_access');

  static Future<FileAccessLease> acquire(
    String path, {
    bool selected = false,
    bool restore = true,
  }) async {
    path = p.normalize(p.absolute(path));
    if (!Platform.isMacOS || !restore) return FileAccessLease._(path, null);
    final result = (await channel.invokeMapMethod<String, dynamic>('acquire', {
      'path': path,
      'selected': selected,
    }))!;
    return FileAccessLease._(
      result['path'] as String,
      result['token'] as String?,
    );
  }

  /// Call after Save As or atomic replacement, while its access is still active.
  static Future<void> remember(String path) async {
    if (Platform.isMacOS) {
      await channel.invokeMethod<void>('remember', {'path': path});
    }
  }

  static Future<Directory> stagingDirectory(String path) async {
    if (!Platform.isMacOS) {
      return Directory(p.dirname(path)).createTemp('.podofo-save-');
    }
    final staging = await channel.invokeMethod<String>('stagingDirectory', {
      'path': path,
    });
    return Directory(staging!);
  }
}

class FileAccessLease {
  FileAccessLease._(this.path, this._token);
  final String path;
  String? _token;
  bool _released = false;

  /// macOS must read inside native file coordination, including symlink
  /// resolution. A Dart read before that can fail on an undownloaded cloud PDF.
  Future<({String path, Uint8List bytes})> read() async {
    if (_released) throw StateError('File access has been released.');
    if (!Platform.isMacOS) {
      final resolved = await File(path).resolveSymbolicLinks();
      return (path: resolved, bytes: await File(resolved).readAsBytes());
    }
    try {
      final result = (await DocumentFileAccess.channel
          .invokeMapMethod<String, dynamic>('read', {'path': path}))!;
      return (
        path: result['path'] as String,
        bytes: result['bytes'] as Uint8List,
      );
    } on PlatformException catch (error) {
      throw DocumentFileReadException(error);
    }
  }

  Future<void> release() async {
    _released = true;
    final token = _token;
    _token = null;
    if (token != null) {
      await DocumentFileAccess.channel.invokeMethod<void>('release', {
        'token': token,
      });
    }
  }
}

/// Keep native diagnostics available without displaying MethodChannel details
/// in the document's recovery notice.
class DocumentFileReadException implements Exception {
  DocumentFileReadException(this.cause);
  final PlatformException cause;

  @override
  String toString() =>
      cause.message ?? 'Could not read this PDF. Please retry.';
}
