import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import 'app_logger.dart';
import 'http_client_factory.dart';

class PersistentImageStore {
  final http.Client _client;

  PersistentImageStore({http.Client? client})
      : _client = client ?? createConfiguredHttpClient();

  static bool isLocalPath(String? source) {
    if (source == null || source.isEmpty) return false;
    if (source.startsWith('file://')) return true;
    if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(source)) return true;
    return source.startsWith('/') || source.startsWith('\\');
  }

  static String? normalizeLocalPath(String? source) {
    if (source == null || source.isEmpty) return null;
    if (source.startsWith('file://')) {
      return Uri.parse(source).toFilePath(windows: Platform.isWindows);
    }
    return source;
  }

  static bool hasLocalImage(String? localPath) {
    final normalized = normalizeLocalPath(localPath);
    if (normalized == null || normalized.isEmpty) return false;
    return File(normalized).existsSync();
  }

  static String? preferredSource({String? localPath, String? remoteUrl}) {
    if (hasLocalImage(localPath)) {
      return normalizeLocalPath(localPath);
    }
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      return remoteUrl;
    }
    return null;
  }

  static String guessMimeType(String? source) {
    final lower = (source ?? '').toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  Future<String?> persistRemoteImage(
    String? remoteUrl, {
    required String category,
    required String entityId,
  }) async {
    if (remoteUrl == null || remoteUrl.isEmpty) return null;
    if (isLocalPath(remoteUrl)) {
      return normalizeLocalPath(remoteUrl);
    }

    final uri = Uri.tryParse(remoteUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 120));
      if (response.statusCode != 200) {
        await AppLogger.warn(
          'Image cache download failed with non-200 status',
          data: {
            'tag': 'image.cache',
            'statusCode': response.statusCode,
            'url': remoteUrl,
          },
        );
        return null;
      }

      final dbPath = await getDatabasesPath();
      final dir = Directory(p.join(dbPath, 'image_cache', category));
      await dir.create(recursive: true);

      final ext = _resolveExtension(uri.path, response.headers['content-type']);
      // Use a hash of the entityId to ensure uniqueness while preserving Chinese characters.
      // The previous approach (replaceAll non-ASCII to '_') caused collisions:
      // 'asset_陈振飞' and 'asset_俞墨凡' both became 'asset___', overwriting each other.
      final safeId = entityId.isEmpty ? 'img' : '${_hashString(entityId)}';
      final filePath = p.join(dir.path, '${safeId}_$category$ext');
      await File(filePath).writeAsBytes(response.bodyBytes, flush: true);
      return filePath;
    } on TimeoutException {
      await AppLogger.warn(
        'Image cache download timed out',
        data: {'tag': 'image.cache', 'url': remoteUrl},
      );
      return null;
    } catch (e, st) {
      await AppLogger.warn(
        'Image cache download failed',
        data: {'tag': 'image.cache', 'url': remoteUrl},
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  String _resolveExtension(String path, String? contentType) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.webp' || ext == '.gif') {
      return ext;
    }

    final normalizedContentType = (contentType ?? '').toLowerCase();
    if (normalizedContentType.contains('jpeg')) return '.jpg';
    if (normalizedContentType.contains('webp')) return '.webp';
    if (normalizedContentType.contains('gif')) return '.gif';
    return '.png';
  }

  /// Generate a short hash from a string to use in file names.
  /// This preserves uniqueness for Chinese characters and other non-ASCII text,
  /// avoiding the collision issue where different Chinese names all mapped to '_'.
  String _hashString(String input) {
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = (hash * 31 + input.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
