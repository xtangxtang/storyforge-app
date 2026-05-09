import 'dart:io';

import 'package:flutter/material.dart';

import '../services/persistent_image_store.dart';

class PersistentImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final source = PersistentImageStore.preferredSource(
      localPath: localPath,
      remoteUrl: remoteUrl,
    );

    final fallback = placeholder ??
        Container(
          width: width,
          height: height,
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
      return Image.file(
        File(normalized),
        key: imageKey,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: errorBuilder ?? (_, __, ___) => fallback,
      );
    }

    return Image.network(
      source,
      key: imageKey,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: errorBuilder ?? (_, __, ___) => fallback,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: Colors.grey.shade800,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}