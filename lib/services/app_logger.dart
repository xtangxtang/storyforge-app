import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

class AppLogger {
  static File? _logFile;
  static Future<void>? _initFuture;
  static Future<void> _writeChain = Future.value();

  static String get logFilePath => _logFile?.path ?? _buildLogFilePath();

  static Future<void> info(
    String message, {
    Map<String, Object?>? data,
  }) {
    return _enqueue('INFO', message, data: data);
  }

  static Future<void> warn(
    String message, {
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stackTrace,
  }) {
    return _enqueue(
      'WARN',
      message,
      data: data,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static Future<void> error(
    String message, {
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stackTrace,
  }) {
    return _enqueue(
      'ERROR',
      message,
      data: data,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static String preview(String text, {int maxLength = 400}) {
    final normalized = text.replaceAll('\r', '').replaceAll('\n', '\\n');
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength)}...(truncated)';
  }

  static Future<void> _enqueue(
    String level,
    String message, {
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    try {
      await _ensureReady();
      final entry = _formatEntry(
        level,
        message,
        data: data,
        error: error,
        stackTrace: stackTrace,
      );

      _writeChain = _writeChain.catchError((_) {}).then((_) async {
        await _logFile!.writeAsString(
          entry,
          mode: FileMode.append,
          flush: true,
        );
      });

      await _writeChain;
    } catch (_) {
      // Logging must never break the app flow.
    }
  }

  static Future<void> _ensureReady() async {
    if (_logFile != null) {
      return;
    }

    _initFuture ??= _initialize();
    await _initFuture;
  }

  static Future<void> _initialize() async {
    final file = File(_buildLogFilePath());
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    _logFile = file;
  }

  static String _buildLogFilePath() {
    final root = _resolveWritableRoot();
    return p.join(root, 'Storyforge', 'logs', 'storyforge.log');
  }

  static String _resolveWritableRoot() {
    if (Platform.isWindows) {
      return Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    }

    return Platform.environment['HOME'] ?? Directory.systemTemp.path;
  }

  static String _formatEntry(
    String level,
    String message, {
    Map<String, Object?>? data,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final buffer = StringBuffer()
      ..writeln('[${DateTime.now().toIso8601String()}] $level $message');

    data?.forEach((key, value) {
      buffer.writeln('  $key: ${_formatValue(value)}');
    });

    if (error != null) {
      buffer.writeln('  error: ${_formatValue(error)}');
    }

    if (stackTrace != null) {
      buffer.writeln('  stackTrace: ${stackTrace.toString().trim()}');
    }

    buffer.writeln();
    return buffer.toString();
  }

  static String _formatValue(Object? value) {
    if (value == null) {
      return 'null';
    }

    final text = value.toString().replaceAll('\r', '').replaceAll('\n', '\\n');
    if (text.length <= 500) {
      return text;
    }
    return '${text.substring(0, 500)}...(truncated)';
  }
}