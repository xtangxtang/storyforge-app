import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_logger.dart';
import 'http_client_factory.dart';
import 'llm_service.dart';
import 'persistent_image_store.dart';

/// Generation backend for Volcengine Ark (agent plan):
///   - image: Seedream 5.0 lite  (POST /images/generations, sync)
///   - video: Seedance 2.0       (POST /contents/generations/tasks, async poll)
///
/// Mirrors the public surface of [DashscopeService]/[ComfyuiService] so it sits
/// behind the same [MediaService] facade.
///
/// Two Ark-specific quirks are handled here:
///  1. The agent-plan models follow ENGLISH prompts well but garble Chinese
///     ones (a CN prompt can come back as an unrelated infographic). So every
///     visual prompt is translated to English via the LLM before sending.
///  2. Seedream requires an image >= 3.7MP, so we generate at 1440x2560 (9:16).
class ArkService {
  final http.Client _client;
  final LlmService _llm;

  ArkService({http.Client? client, LlmService? llm})
      : _client = client ?? createConfiguredHttpClient(),
        _llm = llm ?? LlmService();

  // 9:16 portrait at exactly the 3.7MP minimum Seedream enforces.
  static const String _imageSize = '1440x2560';
  static const String _videoRatio = '9:16';
  static const String _videoResolution = '720p';
  static const int _maxRefImages = 3;

  final Map<String, String> _translationCache = {};

  String get _base {
    final url = AppConfig.arkBaseUrl.trim();
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  String get _key => AppConfig.arkApiKey.trim();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_key',
      };

  void _ensureConfigured() {
    if (_base.isEmpty) {
      throw Exception('Ark 地址未配置，请到设置中填写 Ark Base URL。');
    }
    if (_key.isEmpty) {
      throw Exception('Ark API Key 未配置，请到设置中填写火山 Ark 的 key。');
    }
  }

  // --------------------------------------------------------------------------
  // Image — Seedream 5.0 lite
  // --------------------------------------------------------------------------

  /// Text-to-image, or image-to-image when [referenceImageUrls] are supplied
  /// (used as consistency anchors, up to 3 — same as the ComfyUI path).
  Future<String> generateImage(String prompt,
      {List<String>? referenceImageUrls}) async {
    _ensureConfigured();
    final enPrompt = await _toEnglish(prompt);

    final refs = (referenceImageUrls ?? const <String>[])
        .where((u) => u.isNotEmpty)
        .take(_maxRefImages)
        .toList();
    final images = <String>[];
    for (final r in refs) {
      images.add(await _toImageInput(r));
    }

    final body = <String, dynamic>{
      'model': AppConfig.arkImageModel,
      'prompt': enPrompt,
      'size': _imageSize,
      'response_format': 'url',
      // Keep the "AI生成" watermark ON. Seedance's i2v moderation rejects
      // photorealistic frames as "real person" (PrivacyInformation) when they
      // look like real photos; the watermark marks the frame as AI-generated so
      // i2v accepts it — which is what lets the consistent keyframe actually
      // drive the video (without it every shot falls back to t2v and loses all
      // cross-shot continuity). It's also required by China's AIGC labeling rules.
      'watermark': true,
      if (images.isNotEmpty) 'image': images,
    };

    await AppLogger.info('Ark image generation started', data: {
      'tag': 'ark.image',
      'endpoint': '$_base/images/generations',
      'model': AppConfig.arkImageModel,
      'refImages': images.length,
      'promptLength': enPrompt.length,
    });

    http.Response resp;
    try {
      resp = await _client
          .post(Uri.parse('$_base/images/generations'),
              headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 180));
    } on TimeoutException {
      throw Exception('Ark 出图超时（180 秒）。');
    } on SocketException catch (e) {
      throw Exception('无法连接 Ark：${e.message}');
    }

    if (resp.statusCode != 200) {
      await AppLogger.error('Ark image rejected', data: {
        'tag': 'ark.image',
        'statusCode': resp.statusCode,
        'bodyPreview': AppLogger.preview(resp.body),
      });
      throw Exception('Ark 出图失败 (${_errMessage(resp.body, resp.statusCode)})');
    }

    final url = _firstDataUrl(resp.body);
    if (url == null) throw Exception('Ark 出图响应中没有图片 URL');
    await AppLogger.info('Ark image generation completed',
        data: {'tag': 'ark.image', 'url': _preview(url)});
    return url;
  }

  /// Ark has no batch consistency mode; generate one by one.
  Future<List<String>> generateImagesSequential(List<String> prompts) async {
    final urls = <String>[];
    for (final p in prompts) {
      urls.add(await generateImage(p));
    }
    return urls;
  }

  // --------------------------------------------------------------------------
  // Video — Seedance 2.0 (async task + polling)
  // --------------------------------------------------------------------------

  /// Video generation. Two modes:
  ///
  ///  - **reference_video CHAIN** (default for multi-shot continuity): pass the
  ///    PREVIOUS shot's video as [referenceVideoUrl]. Seedance inherits its
  ///    subject / world / style / lighting, giving far stronger cross-shot
  ///    consistency than a character sheet. NO image inputs are sent (image
  ///    moderation blocks realistic faces; a video reference passes in the
  ///    cinematic semi-real look). The previous video must be a web URL.
  ///
  ///  - **t2v + reference_image** (fallback when no [referenceVideoUrl], e.g. the
  ///    first shot): text drives it, [referenceImageUrls]/[firstFrameUrl] attach
  ///    as `reference_image`. (i2v first-frame is deliberately avoided —
  ///    photoreal first-frames trip the `PrivacyInformation` moderation.)
  ///
  /// Continuity background: feeding a realistic still image (first_frame) is
  /// blocked, so true frame-exact chaining is impossible for realistic content;
  /// reference_video is the strongest continuity the backend allows.
  Future<String> generateVideo({
    required String prompt,
    required String firstFrameUrl,
    int duration = 5,
    List<String>? referenceImageUrls,
    List<String>? referenceVideoUrls,
  }) async {
    _ensureConfigured();
    final enPrompt = await _toEnglish(prompt);
    final dur = duration.clamp(3, 10);

    // Seedance reads generation params as trailing --flags in the text command.
    final text = '$enPrompt --ratio $_videoRatio '
        '--resolution $_videoResolution --duration $dur';

    // Up to 3 prior-shot videos (one per present character, chosen upstream) carry
    // each character's look forward.
    final refVideos = (referenceVideoUrls ?? const <String>[])
        .where((u) => u.trim().isNotEmpty)
        .take(3)
        .toList();
    final chain = refVideos.isNotEmpty;

    // Image references are only used in the (fallback) t2v path — never together
    // with a reference_video (and never as i2v first-frame).
    final refInputs = <String>[];
    if (!chain) {
      final sources = (referenceImageUrls ?? const <String>[])
          .where((u) => u.isNotEmpty)
          .take(_maxRefImages)
          .toList();
      if (sources.isEmpty && firstFrameUrl.isNotEmpty) {
        sources.add(firstFrameUrl);
      }
      for (final s in sources) {
        refInputs.add(await _toImageInput(s));
      }
    }

    Object? lastErr;
    var dropRefs = false; // moderation on t2v -> drop image refs
    final vids =
        List<String>.from(refVideos); // moderation -> drop one per retry
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        return await _submitVideoTask(
          text,
          refInputs: dropRefs ? const [] : refInputs,
          referenceVideoUrls: chain ? vids : null,
          dur: dur,
        );
      } catch (e) {
        lastErr = e;
        if (_isRateLimit(e)) {
          await AppLogger.warn(
              'Ark video rate-limited (attempt ${attempt + 1})',
              data: {'tag': 'ark.video'},
              error: e);
          await Future.delayed(const Duration(seconds: 40));
          continue;
        }
        if (_isTransient(e)) {
          await AppLogger.warn(
              'Ark video transient error (attempt ${attempt + 1})',
              data: {'tag': 'ark.video'},
              error: e);
          await Future.delayed(const Duration(seconds: 15));
          continue;
        }
        if (_isModerationError(e)) {
          await AppLogger.warn(
              'Ark video moderation block (attempt ${attempt + 1})',
              data: {'tag': 'ark.video'},
              error: e);
          // a reference video (or image) likely tripped "real person": drop one
          // reference video per retry (preserve the rest); else drop image refs.
          if (chain && vids.isNotEmpty) {
            vids.removeLast();
          } else {
            dropRefs = true;
          }
          continue;
        }
        rethrow;
      }
    }
    throw Exception('Ark 视频生成失败（已重试）：$lastErr');
  }

  bool _isModerationError(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('sensitive') ||
        m.contains('privacy') ||
        m.contains('moderation') ||
        m.contains('审核');
  }

  bool _isRateLimit(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('429') ||
        m.contains('quota') ||
        m.contains('toomanyrequests') ||
        m.contains('rate limit');
  }

  bool _isTransient(Object e) {
    final m = e.toString().toLowerCase();
    return m.contains('internalserviceerror') ||
        m.contains('internal error') ||
        m.contains('http 500') ||
        m.contains('http 502') ||
        m.contains('http 503') ||
        m.contains('http 504') ||
        m.contains('超时') ||
        m.contains('timeout');
  }

  Future<String> _submitVideoTask(String text,
      {String? firstFrame,
      List<String>? referenceVideoUrls,
      required List<String> refInputs,
      required int dur}) async {
    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': text},
      // reference_video(s): up to 3 prior-shot clips (web URLs, no role mixing
      // with images) — carry each present character's look/world forward.
      for (final v in (referenceVideoUrls ?? const <String>[])
          .where((u) => u.isNotEmpty)
          .take(3))
        {
          'type': 'video_url',
          'video_url': {'url': v},
          'role': 'reference_video',
        },
      // i2v: the controlled keyframe is the first frame (composition/staging);
      // motion comes from the text. Identity is already baked into the keyframe.
      if (firstFrame != null)
        {
          'type': 'image_url',
          'image_url': {'url': firstFrame},
          'role': 'first_frame',
        },
      for (final r in refInputs)
        {
          'type': 'image_url',
          'image_url': {'url': r},
          'role': 'reference_image',
        },
    ];

    final body = {'model': AppConfig.arkVideoModel, 'content': content};

    await AppLogger.info('Ark video task submit', data: {
      'tag': 'ark.video',
      'endpoint': '$_base/contents/generations/tasks',
      'model': AppConfig.arkVideoModel,
      'duration': dur,
      'mode': (referenceVideoUrls != null && referenceVideoUrls.isNotEmpty)
          ? 'reference_video x${referenceVideoUrls.length}'
          : (firstFrame != null ? 'i2v' : 't2v'),
      'refImages': refInputs.length,
    });

    http.Response resp;
    try {
      resp = await _client
          .post(Uri.parse('$_base/contents/generations/tasks'),
              headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw Exception('Ark 视频任务提交超时。');
    } on SocketException catch (e) {
      throw Exception('无法连接 Ark：${e.message}');
    }
    if (resp.statusCode != 200) {
      await AppLogger.error('Ark video submit rejected', data: {
        'tag': 'ark.video',
        'statusCode': resp.statusCode,
        'bodyPreview': AppLogger.preview(resp.body),
      });
      throw Exception(
          'Ark 视频任务提交失败 (${_errMessage(resp.body, resp.statusCode)})');
    }
    final taskId =
        (jsonDecode(resp.body) as Map<String, dynamic>)['id'] as String?;
    if (taskId == null) throw Exception('Ark 视频响应中没有任务 id');

    return _pollVideo(taskId);
  }

  Future<String> _pollVideo(String taskId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 900));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 5));
      http.Response h;
      try {
        h = await _client
            .get(Uri.parse('$_base/contents/generations/tasks/$taskId'),
                headers: _headers)
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        continue;
      } on SocketException {
        continue;
      }
      if (h.statusCode != 200) continue;
      final data = jsonDecode(h.body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      if (status == 'succeeded') {
        final content = data['content'];
        final url = content is Map ? content['video_url'] as String? : null;
        if (url == null || url.isEmpty) {
          throw Exception('Ark 视频完成但响应中没有 video_url');
        }
        await AppLogger.info('Ark video completed',
            data: {'tag': 'ark.video', 'taskId': taskId});
        return url;
      }
      if (status == 'failed') {
        throw Exception('Ark 视频生成失败: ${jsonEncode(data['error'] ?? data)}');
      }
      // queued / running -> keep polling
    }
    throw Exception('Ark 视频任务超时（900 秒）');
  }

  void dispose() {
    _client.close();
    _llm.dispose();
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// Translate a Chinese visual prompt to English (Ark models need English).
  /// No-op for prompts that contain no CJK characters. Cached per string.
  Future<String> _toEnglish(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    if (!_hasCjk(trimmed)) return trimmed;
    final cached = _translationCache[trimmed];
    if (cached != null) return cached;

    try {
      final resp = await _llm.chatCompletion(
        messages: [
          ChatMessage(
            role: 'system',
            content:
                'You translate image/video generation prompts into natural, '
                'concise English for a text-to-image/video model. Preserve every '
                'visual detail: subject, appearance, clothing, action/pose, '
                'camera, composition, lighting, mood, art style. Do NOT add or '
                'drop content. Output ONLY the English prompt, with no quotes, '
                'labels, or explanation.',
          ),
          ChatMessage(role: 'user', content: trimmed),
        ],
        temperature: 0.2,
        requestTag: 'ark.translate',
      );
      final en = resp.content.trim();
      final result = en.isEmpty ? trimmed : en;
      _translationCache[trimmed] = result;
      return result;
    } catch (e) {
      // Translation is best-effort; fall back to the original on failure.
      await AppLogger.warn('Ark prompt translation failed; using original',
          data: {'tag': 'ark.translate'}, error: e);
      return trimmed;
    }
  }

  bool _hasCjk(String s) => RegExp(r'[一-鿿㐀-䶿]').hasMatch(s);

  /// Turn a reference into an Ark `image` input: pass public http(s) URLs as-is
  /// (Ark fetches them server-side), base64-encode local files / private hosts.
  Future<String> _toImageInput(String source) async {
    if (source.startsWith('http://') || source.startsWith('https://')) {
      final host = Uri.tryParse(source)?.host ?? '';
      if (!_isPrivateHost(host)) return source; // public — let Ark fetch it
    }
    final bytes = await _fetchBytes(source);
    final b64 = base64Encode(bytes);
    final mime =
        source.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    return 'data:$mime;base64,$b64';
  }

  bool _isPrivateHost(String host) {
    if (host == 'localhost') return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final o = [for (final p in parts) int.tryParse(p) ?? -1];
    if (o.any((v) => v < 0 || v > 255)) return false;
    if (o[0] == 127 || o[0] == 10) return true;
    if (o[0] == 192 && o[1] == 168) return true;
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
    return false;
  }

  Future<List<int>> _fetchBytes(String source) async {
    if (PersistentImageStore.isLocalPath(source)) {
      final path = PersistentImageStore.normalizeLocalPath(source);
      if (path != null && File(path).existsSync()) {
        return File(path).readAsBytes();
      }
      throw Exception('参考图本地文件不存在: $source');
    }
    final uri = Uri.tryParse(source);
    if (uri == null) throw Exception('参考图 URL 无效: $source');
    final resp = await _client.get(uri).timeout(const Duration(seconds: 120));
    if (resp.statusCode != 200) {
      throw Exception('获取参考图失败 (HTTP ${resp.statusCode})');
    }
    return resp.bodyBytes;
  }

  String? _firstDataUrl(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final data = decoded['data'];
      if (data is List && data.isNotEmpty && data.first is Map) {
        final url = (data.first as Map)['url'];
        if (url is String && url.isNotEmpty) return url;
      }
    } catch (_) {}
    return null;
  }

  String _errMessage(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] != null) {
          return '${err['code'] ?? statusCode}: ${err['message']}';
        }
      }
    } catch (_) {}
    return 'HTTP $statusCode';
  }

  String _preview(String url) => url.length > 60 ? url.substring(0, 60) : url;
}
