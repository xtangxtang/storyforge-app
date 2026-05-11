import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/persistent_image_store.dart';

/// A StatefulWidget that loads local file images with cache-busting support.
/// When a file is overwritten (e.g. asset regeneration), the widget detects
/// the change via file modification time and forces a reload.
class PersistentImage extends StatefulWidget {
  final String? remoteUrl;
  final String? localPath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Key? imageKey;
  final Widget? placeholder;
  final Widget Function(BuildContext, Object?, StackTrace?)? errorBuilder;

  const PersistentImage({
    super.key,
    this.remoteUrl,
    this.localPath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.imageKey,
    this.placeholder,
    this.errorBuilder,
  });

  @override
  State<PersistentImage> createState() => _PersistentImageState();
}

class _PersistentImageState extends State<PersistentImage> {
  Uint8List? _fileBytes;
  int? _lastModTime;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _loadFileIfNeeded();
  }

  @override
  void didUpdateWidget(PersistentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Always check file modification time on rebuild — the file on disk
    // may have been replaced (e.g. asset regeneration) even though
    // localPath/remoteUrl props haven't changed.
    _loadFileIfNeeded();
  }

  void _loadFileIfNeeded() {
    final source = PersistentImageStore.preferredSource(
      localPath: widget.localPath,
      remoteUrl: widget.remoteUrl,
    );

    if (source == null || source.isEmpty || !PersistentImageStore.isLocalPath(source)) {
      return;
    }

    final normalized = PersistentImageStore.normalizeLocalPath(source);
    if (normalized == null || normalized.isEmpty || !File(normalized).existsSync()) {
      return;
    }

    final file = File(normalized);
    try {
      final modTime = file.lastModifiedSync().millisecondsSinceEpoch;
      if (normalized == _loadedPath && modTime == _lastModTime && _fileBytes != null) {
        return; // Same file, same modification time — no reload needed
      }
      final bytes = file.readAsBytesSync();
      if (mounted) {
        setState(() {
          _fileBytes = bytes;
          _lastModTime = modTime;
          _loadedPath = normalized;
        });
      }
    } catch (_) {
      // File access error — will show fallback
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = PersistentImageStore.preferredSource(
      localPath: widget.localPath,
      remoteUrl: widget.remoteUrl,
    );

    final fallback = widget.placeholder ??
        Container(
          width: widget.width,
          height: widget.height,
          color: Colors.grey.shade800,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        );

    if (source == null || source.isEmpty) {
      return fallback;
    }

    if (PersistentImageStore.isLocalPath(source)) {
      final normalized = PersistentImageStore.normalizeLocalPath(source);
      if (normalized == null || normalized.isEmpty || !File(normalized).existsSync()) {
        return fallback;
      }
      if (_fileBytes != null) {
        return Image.memory(
          _fileBytes!,
          key: widget.imageKey ?? ValueKey('${normalized}_$_lastModTime'),
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: widget.errorBuilder ?? (_, __, ___) => fallback,
        );
      }
      // No bytes loaded yet — show fallback
      return fallback;
    }

    return Image.network(
      source,
      key: widget.imageKey,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: widget.errorBuilder ?? (_, __, ___) => fallback,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: widget.width,
          height: widget.height,
          color: Colors.grey.shade800,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}