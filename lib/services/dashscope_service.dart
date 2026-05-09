import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_logger.dart';
import 'http_client_factory.dart';

class DashscopeService {
  final http.Client _client;

  DashscopeService({http.Client? client})
      : _client = client ?? createConfiguredHttpClient();

  /// Generate a single image for a storyboard shot.
  /// Uses wan2.7-image-pro with n=1.
  /// Consistency across shots relies on consistent prompt descriptions
  /// (character appearance, scene setting, style tags).
  Future<String> generateImage(String prompt, {List<String>? referenceImageUrls}) async {
    final apiKey = AppConfig.imageApiKey;
    final model = AppConfig.imageModel;
    final proxy = normalizeConfiguredProxy() ?? 'DIRECT';

    if (apiKey.isEmpty) {
      throw Exception('图像 API Key 未配置，请到设置中添加。');
    }

    // Resolve base URL: use configured value if it looks like a DashScope endpoint,
    // otherwise fall back to the default. MAAS /compatible-mode/v1 endpoints only
    // support OpenAI-compatible chat completions, not DashScope image/video APIs.
    final effectiveBaseUrl = _resolveDashScopeBaseUrl(AppConfig.imageBaseUrl);

    final uri = Uri.parse(
      '$effectiveBaseUrl/api/v1/services/aigc/multimodal-generation/generation',
    );
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    // Build content array with reference images (if any) + text prompt
    final contentItems = <Map<String, dynamic>>[];
    if (referenceImageUrls != null && referenceImageUrls.isNotEmpty) {
      for (final url in referenceImageUrls) {
        contentItems.add({'image': url});
      }
    }
    contentItems.add({'text': prompt});

    final body = jsonEncode({
      'model': model,
      'input': {
        'messages': [
          {
            'role': 'user',
            'content': contentItems,
          },
        ],
      },
      'parameters': {
        'n': 1,
        'size': '2048*2048',
      },
    });

    await AppLogger.info(
      'Image generation request started',
      data: {
        'tag': 'image.generate',
        'endpoint': uri.toString(),
        'model': model,
        'promptLength': prompt.length,
        'proxy': proxy,
      },
    );

    http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 300));
    } on TimeoutException {
      await AppLogger.error(
        'Image generation timed out',
        data: {'tag': 'image.generate', 'endpoint': uri.toString(), 'proxy': proxy},
      );
      throw Exception('图片生成超时（300 秒）。请检查网络或代理设置。');
    } on SocketException catch (e, st) {
      await AppLogger.error(
        'Image generation network failed',
        data: {'tag': 'image.generate', 'endpoint': uri.toString(), 'proxy': proxy},
        error: e,
        stackTrace: st,
      );
      throw Exception('图片生成网络请求失败: ${e.message}');
    } catch (e, st) {
      await AppLogger.error(
        'Image generation request failed before response',
        data: {'tag': 'image.generate', 'endpoint': uri.toString()},
        error: e,
        stackTrace: st,
      );
      throw Exception('图片生成请求失败: $e');
    }

    await AppLogger.info(
      'Image generation response received',
      data: {
        'tag': 'image.generate',
        'statusCode': response.statusCode,
        'endpoint': uri.toString(),
        'bodyLength': response.body.length,
      },
    );

    if (response.statusCode != 200) {
      await AppLogger.error(
        'Image generation API returned non-200 status',
        data: {
          'tag': 'image.generate',
          'statusCode': response.statusCode,
          'endpoint': uri.toString(),
          'bodyPreview': AppLogger.preview(response.body),
        },
      );
      throw Exception('图片生成失败 (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    // Check if it's async (has task_id)
    final taskId = data['output']?['task_id'] as String?;
    await AppLogger.info(
      'Image response taskId check',
      data: {
        'tag': 'image.generate',
        'taskId': taskId ?? '(null)',
        'outputKeys': data['output']?.keys.toList().join(','),
      },
    );
    if (taskId != null) {
      await AppLogger.info(
        'Image generation async task started',
        data: {'tag': 'image.generate', 'taskId': taskId},
      );
      return _pollImageTask(taskId);
    }

    // Sync response - parse single image
    final choices = data['output']?['choices'] as List?;
    if (choices != null && choices.isNotEmpty) {
      final firstChoice = choices[0];
      final message = firstChoice['message'] as Map?;
      final content = message?['content'] as List?;
      if (content != null && content.isNotEmpty) {
        final imageUrl = content[0]['image'] as String?;
        if (imageUrl != null && imageUrl.isNotEmpty) {
          await AppLogger.info(
            'Image generation sync completed',
            data: {'tag': 'image.generate', 'imageUrl': imageUrl.substring(0, 60)},
          );
          return imageUrl;
        }
      }
    }

    await AppLogger.error(
      'No image URL in response',
      data: {
        'tag': 'image.generate',
        'endpoint': uri.toString(),
        'bodyPreview': AppLogger.preview(response.body),
      },
    );
    throw Exception('图片生成响应中没有图片 URL');
  }

  Future<String> _pollImageTask(String taskId) async {
    final baseUrl = _resolveDashScopeBaseUrl(AppConfig.imageBaseUrl);
    final apiKey = AppConfig.imageApiKey;

    for (int i = 0; i < 120; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final uri = Uri.parse('$baseUrl/api/v1/tasks/$taskId');
      final headers = {'Authorization': 'Bearer $apiKey'};
      http.Response response;
      try {
        response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 60));
      } on TimeoutException {
        throw Exception('图片任务轮询超时');
      } on SocketException catch (e) {
        throw Exception('图片任务轮询失败: ${e.message}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['output']?['task_status'] as String?;

      if (status == 'SUCCEEDED') {
        // Try results array first
        final results = data['output']?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          return results[0]['url'] as String;
        }
        // Try choices array
        final choices = data['output']?['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final content = choices[0]['message']?['content'] as List?;
          if (content != null && content.isNotEmpty) {
            return content[0]['image'] as String;
          }
        }
        throw Exception('任务结果中没有图片 URL');
      } else if (status == 'FAILED') {
        final message = data['output']?['message'] as String? ?? 'Task failed';
        throw Exception('图片生成失败: $message');
      }
    }

    throw Exception('图片生成超时（10 分钟）');
  }

  /// Generate video via image-to-video (i2v) model.
  /// Tries async mode first, falls back to sync mode if 403 is received.
  /// Optional `referenceImageUrls` are added as additional reference frames
  /// to improve character/scene consistency in the output.
  Future<String> generateVideo({
    required String prompt,
    required String firstFrameUrl,
    int duration = 5,
    List<String>? referenceImageUrls,
  }) async {
    final apiKey = AppConfig.videoApiKey;
    final model = AppConfig.videoModel;
    final proxy = normalizeConfiguredProxy() ?? 'DIRECT';

    if (apiKey.isEmpty) {
      throw Exception('视频 API Key 未配置，请到设置中添加。');
    }

    final effectiveBaseUrl = _resolveDashScopeBaseUrl(AppConfig.videoBaseUrl);

    // Try async mode first
    try {
      return await _generateVideoAsync(
        baseUrl: effectiveBaseUrl,
        apiKey: apiKey,
        model: model,
        proxy: proxy,
        prompt: prompt,
        firstFrameUrl: firstFrameUrl,
        duration: duration,
        referenceImageUrls: referenceImageUrls,
      );
    } catch (e) {
      final errorStr = e.toString();
      // If 403 with "does not support asynchronous calls", fall back to sync mode
      if (errorStr.contains('403') && errorStr.contains('asynchronous')) {
        await AppLogger.info(
          'Video async mode failed (403), falling back to sync mode',
          data: {'tag': 'video.generate', 'error': errorStr},
        );
        return await _generateVideoSync(
          baseUrl: effectiveBaseUrl,
          apiKey: apiKey,
          model: model,
          proxy: proxy,
          prompt: prompt,
          firstFrameUrl: firstFrameUrl,
          duration: duration,
          referenceImageUrls: referenceImageUrls,
        );
      }
      rethrow;
    }
  }

  Future<String> _generateVideoAsync({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String proxy,
    required String prompt,
    required String firstFrameUrl,
    required int duration,
    List<String>? referenceImageUrls,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/services/aigc/video-generation/video-synthesis');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
      'X-DashScope-Async': 'enable',
    };

    // Build media array: first_frame + optional reference images
    final mediaItems = <Map<String, dynamic>>[
      {'type': 'first_frame', 'url': firstFrameUrl},
    ];
    if (referenceImageUrls != null && referenceImageUrls.isNotEmpty) {
      for (final url in referenceImageUrls) {
        mediaItems.add({'type': 'ref', 'url': url});
      }
    }

    final body = jsonEncode({
      'model': model,
      'input': {
        'prompt': prompt,
        'media': mediaItems,
      },
      'parameters': {
        'resolution': '720P',
        'duration': duration,
        'prompt_extend': true,
      },
    });

    await AppLogger.info(
      'Video generation async request started',
      data: {
        'tag': 'video.generate',
        'endpoint': uri.toString(),
        'model': model,
        'proxy': proxy,
      },
    );

    http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw Exception('视频生成请求超时（60 秒）。请检查网络或代理设置。');
    } on SocketException catch (e) {
      throw Exception('视频生成网络请求失败: ${e.message}');
    } catch (e) {
      throw Exception('视频生成请求失败: $e');
    }

    await AppLogger.info(
      'Video async response received',
      data: {
        'tag': 'video.generate',
        'statusCode': response.statusCode,
        'endpoint': uri.toString(),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('视频生成失败 (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final taskId = data['output']?['task_id'] as String?;
    if (taskId == null) {
      throw Exception('视频生成响应中没有 task_id');
    }

    return _pollVideoTask(taskId);
  }

  Future<String> _generateVideoSync({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String proxy,
    required String prompt,
    required String firstFrameUrl,
    required int duration,
    List<String>? referenceImageUrls,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/services/aigc/video-generation/video-synthesis');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
      // No X-DashScope-Async header for sync mode
    };

    // Build media array: first_frame + optional reference images
    final mediaItems = <Map<String, dynamic>>[
      {'type': 'first_frame', 'url': firstFrameUrl},
    ];
    if (referenceImageUrls != null && referenceImageUrls.isNotEmpty) {
      for (final url in referenceImageUrls) {
        mediaItems.add({'type': 'ref', 'url': url});
      }
    }

    final body = jsonEncode({
      'model': model,
      'input': {
        'prompt': prompt,
        'media': mediaItems,
      },
      'parameters': {
        'resolution': '720P',
        'duration': duration,
        'prompt_extend': true,
      },
    });

    await AppLogger.info(
      'Video generation sync request started',
      data: {
        'tag': 'video.generate',
        'endpoint': uri.toString(),
        'model': model,
        'proxy': proxy,
      },
    );

    http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 300)); // 5 minutes for sync video gen
    } on TimeoutException {
      throw Exception('视频生成请求超时（300 秒）。请检查网络或代理设置。');
    } on SocketException catch (e) {
      throw Exception('视频生成网络请求失败: ${e.message}');
    } catch (e) {
      throw Exception('视频生成请求失败: $e');
    }

    await AppLogger.info(
      'Video sync response received',
      data: {
        'tag': 'video.generate',
        'statusCode': response.statusCode,
        'endpoint': uri.toString(),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('视频生成失败 (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    // Sync response: check for video_url directly in output
    final videoUrl = data['output']?['video_url'] as String?;
    if (videoUrl != null && videoUrl.isNotEmpty) {
      await AppLogger.info(
        'Video generation sync completed',
        data: {'tag': 'video.generate', 'videoUrl': videoUrl},
      );
      return videoUrl;
    }

    // Or check results array
    final results = data['output']?['results'] as List?;
    if (results != null && results.isNotEmpty) {
      final url = results[0]['url'] as String?;
      if (url != null && url.isNotEmpty) {
        await AppLogger.info(
          'Video generation sync completed (from results)',
          data: {'tag': 'video.generate', 'videoUrl': url},
        );
        return url;
      }
    }

    // Or check choices (some APIs return this format)
    final choices = data['output']?['choices'] as List?;
    if (choices != null && choices.isNotEmpty) {
      final message = choices[0]['message'] as Map?;
      final content = message?['content'] as List?;
      if (content != null && content.isNotEmpty) {
        final url = content[0]['video'] as String?;
        if (url != null && url.isNotEmpty) {
          await AppLogger.info(
            'Video generation sync completed (from choices)',
            data: {'tag': 'video.generate', 'videoUrl': url},
          );
          return url;
        }
      }
    }

    throw Exception('视频生成响应中没有视频 URL');
  }

  Future<String> _pollVideoTask(String taskId) async {
    final baseUrl = _resolveDashScopeBaseUrl(AppConfig.videoBaseUrl);
    final apiKey = AppConfig.videoApiKey;

    for (int i = 0; i < 120; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final uri = Uri.parse('$baseUrl/api/v1/tasks/$taskId');
      final headers = {'Authorization': 'Bearer $apiKey'};
      http.Response response;
      try {
        response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 60));
      } on TimeoutException {
        throw Exception('视频任务轮询超时');
      } on SocketException catch (e) {
        throw Exception('视频任务轮询失败: ${e.message}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['output']?['task_status'] as String?;

      if (status == 'SUCCEEDED') {
        final videoUrl = data['output']?['video_url'] as String?;
        if (videoUrl != null && videoUrl.isNotEmpty) {
          return videoUrl;
        }
        final results = data['output']?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          return results[0]['url'] as String;
        }
        throw Exception('任务结果中没有视频 URL');
      } else if (status == 'FAILED') {
        final message = data['output']?['message'] as String? ?? 'Task failed';
        throw Exception('视频生成失败: $message');
      }
    }

    throw Exception('视频生成超时（10 分钟）');
  }

  void dispose() => _client.close();

  /// Generate a batch of storyboard images in sequential mode.
  /// Uses wan2.7-image-pro with enable_sequential: true.
  /// The API generates `prompts.length` images that are visually consistent
  /// with each other (same characters, style, lighting).
  /// Returns a list of image URLs in the same order as the input prompts.
  Future<List<String>> generateImagesSequential(List<String> prompts) async {
    final apiKey = AppConfig.imageApiKey;
    final model = AppConfig.imageModel;
    final proxy = normalizeConfiguredProxy() ?? 'DIRECT';
    final n = prompts.length;

    if (apiKey.isEmpty) {
      throw Exception('图像 API Key 未配置，请到设置中添加。');
    }
    if (n == 0) {
      throw Exception('没有需要生成的图片');
    }
    if (n > 8) {
      throw Exception('组图模式最多支持 8 张图片，当前请求 $n 张');
    }

    final effectiveBaseUrl = _resolveDashScopeBaseUrl(AppConfig.imageBaseUrl);

    // Build a combined prompt with numbered shots and consistency instruction
    final shotDescriptions = prompts.asMap().entries.map((e) {
      return '第${e.key + 1}张：${e.value}';
    }).join('；');
    final combinedPrompt =
        '电影感组图，按顺序生成以下分镜画面，角色外貌、服装、场景特征必须前后一致。'
        '$shotDescriptions';

    final uri = Uri.parse(
      '$effectiveBaseUrl/api/v1/services/aigc/multimodal-generation/generation',
    );
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    final body = jsonEncode({
      'model': model,
      'input': {
        'messages': [
          {
            'role': 'user',
            'content': [
              {'text': combinedPrompt},
            ],
          },
        ],
      },
      'parameters': {
        'enable_sequential': true,
        'n': n,
        'size': '2K',
      },
    });

    await AppLogger.info(
      'Sequential image generation request started',
      data: {
        'tag': 'image.generate_sequential',
        'endpoint': uri.toString(),
        'model': model,
        'promptCount': n,
        'combinedPromptLength': combinedPrompt.length,
        'proxy': proxy,
      },
    );

    http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 300));
    } on TimeoutException {
      await AppLogger.error(
        'Sequential image generation timed out',
        data: {
          'tag': 'image.generate_sequential',
          'endpoint': uri.toString(),
          'proxy': proxy,
        },
      );
      throw Exception('组图生成超时（300 秒）。请检查网络或代理设置。');
    } on SocketException catch (e, st) {
      await AppLogger.error(
        'Sequential image generation network failed',
        data: {
          'tag': 'image.generate_sequential',
          'endpoint': uri.toString(),
          'proxy': proxy,
        },
        error: e,
        stackTrace: st,
      );
      throw Exception('组图生成网络请求失败: ${e.message}');
    } catch (e, st) {
      await AppLogger.error(
        'Sequential image generation request failed before response',
        data: {
          'tag': 'image.generate_sequential',
          'endpoint': uri.toString(),
        },
        error: e,
        stackTrace: st,
      );
      throw Exception('组图生成请求失败: $e');
    }

    if (response.statusCode != 200) {
      throw Exception('组图生成失败 (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    // Check if it's async (has task_id)
    final taskId = data['output']?['task_id'] as String?;
    if (taskId != null) {
      await AppLogger.info(
        'Sequential image generation async task started',
        data: {'tag': 'image.generate_sequential', 'taskId': taskId},
      );
      return _pollSequentialImageTask(taskId, n);
    }

    // Sync response - parse multiple images
    final choices = data['output']?['choices'] as List?;
    if (choices != null && choices.isNotEmpty) {
      final urls = <String>[];
      for (final choice in choices) {
        final message = choice['message'] as Map?;
        final content = message?['content'] as List?;
        if (content != null && content.isNotEmpty) {
          final imageUrl = content[0]['image'] as String?;
          if (imageUrl != null && imageUrl.isNotEmpty) {
            urls.add(imageUrl);
          }
        }
      }
      if (urls.isNotEmpty) {
        await AppLogger.info(
          'Sequential image generation sync completed',
          data: {
            'tag': 'image.generate_sequential',
            'imageCount': urls.length,
          },
        );
        return urls;
      }
    }

    throw Exception('组图生成响应中没有图片 URL');
  }

  Future<List<String>> _pollSequentialImageTask(String taskId, int expectedCount) async {
    final baseUrl = _resolveDashScopeBaseUrl(AppConfig.imageBaseUrl);
    final apiKey = AppConfig.imageApiKey;

    for (int i = 0; i < 120; i++) {
      await Future.delayed(const Duration(seconds: 5));
      final uri = Uri.parse('$baseUrl/api/v1/tasks/$taskId');
      final headers = {'Authorization': 'Bearer $apiKey'};
      http.Response response;
      try {
        response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 60));
      } on TimeoutException {
        throw Exception('组图任务轮询超时');
      } on SocketException catch (e) {
        throw Exception('组图任务轮询失败: ${e.message}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['output']?['task_status'] as String?;

      if (status == 'SUCCEEDED') {
        // Try results array first (sequential mode returns results[])
        final results = data['output']?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final urls = <String>[];
          for (final r in results) {
            final url = r['url'] as String?;
            if (url != null && url.isNotEmpty) {
              urls.add(url);
            }
          }
          if (urls.isNotEmpty) return urls;
        }
        // Try choices array as fallback
        final choices = data['output']?['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final urls = <String>[];
          for (final choice in choices) {
            final content = choice['message']?['content'] as List?;
            if (content != null && content.isNotEmpty) {
              final imageUrl = content[0]['image'] as String?;
              if (imageUrl != null && imageUrl.isNotEmpty) {
                urls.add(imageUrl);
              }
            }
          }
          if (urls.isNotEmpty) return urls;
        }
        throw Exception('组图任务结果中没有图片 URL');
      } else if (status == 'FAILED') {
        final message = data['output']?['message'] as String? ?? 'Task failed';
        throw Exception('组图生成失败: $message');
      }
      // PENDING or RUNNING - continue polling
    }

    throw Exception('组图生成超时（10 分钟）');
  }

  /// Resolve base URL for DashScope multimodal-generation / video-synthesis APIs.
  ///
  /// MAAS platform endpoints (e.g. `.../compatible-mode/v1`) only support
  /// OpenAI-compatible chat completions, not DashScope-specific image/video APIs.
  /// If the configured base URL looks like an OpenAI-compatible endpoint,
  /// fall back to the default DashScope endpoint.
  static String _resolveDashScopeBaseUrl(String configuredBaseUrl) {
    // If the URL contains OpenAI-compatible path segments, it won't work
    // with DashScope multimodal-generation or video-synthesis APIs.
    if (configuredBaseUrl.contains('/compatible-mode') ||
        configuredBaseUrl.contains('/chat/completions')) {
      return 'https://dashscope.aliyuncs.com';
    }
    // Strip trailing /v1 or /v1/ to avoid double path segments like /v1/api/v1/
    var url = configuredBaseUrl;
    if (url.endsWith('/v1/')) {
      url = url.substring(0, url.length - 4);
    } else if (url.endsWith('/v1')) {
      url = url.substring(0, url.length - 3);
    }
    return url;
  }
}