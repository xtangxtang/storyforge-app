import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'app_logger.dart';
import 'http_client_factory.dart';
import 'persistent_image_store.dart';

/// Generation backend for a self-hosted ComfyUI server (e.g. the A100 box).
///
/// Mirrors the public surface of [DashscopeService] so it can sit behind the
/// same [MediaService] facade. Image/video are produced by POSTing an
/// API-format workflow to `/prompt`, polling `/history/{id}`, then returning a
/// `/view?...` URL that the rest of the app downloads exactly like a cloud URL.
class ComfyuiService {
  final http.Client _client;

  ComfyuiService({http.Client? client})
      : _client = client ?? createConfiguredHttpClient();

  // Text-encoder / VAE filenames are fixed by the deployment; only the
  // diffusion model is surfaced in settings (AppConfig.image/videoModel).
  static const String _qwenClip = 'qwen_2.5_vl_7b_fp8_scaled.safetensors';
  static const String _qwenVae = 'qwen_image_vae.safetensors';
  // Qwen-Image-Edit-2509 supports up to 3 reference images via
  // TextEncodeQwenImageEditPlus; used for character/scene consistency.
  static const String _qwenEditModel =
      'qwen_image_edit_2509_fp8_e4m3fn.safetensors';
  static const int _maxRefImages = 3;
  static const String _wanClip = 'umt5_xxl_fp8_e4m3fn_scaled.safetensors';
  static const String _wanVae = 'wan2.2_vae.safetensors';

  static const String _negImage =
      'blurry, low quality, lowres, jpeg artifacts, distorted, deformed, '
      'watermark, text, extra limbs, bad anatomy';
  static const String _negVideo =
      'static, blurry, distorted, low quality, watermark';

  // Quality / framing. The app is a vertical (9:16) short-video product, so both
  // images and video are generated portrait at matched aspect — previously the
  // keyframe was square (1024²) while the video was landscape (1280×704), which
  // forced the i2v node to crop/stretch the first frame. Image size sits at
  // Qwen-Image's ~1.5MP sweet spot; video uses Wan2.2-TI2V-5B's portrait 720p.
  static const int _imgWidth = 928;
  static const int _imgHeight = 1664; // 9:16, ~1.5MP
  static const int _imgSteps = 30;
  static const double _imgCfg = 4.0;
  static const int _vidWidth = 704;
  static const int _vidHeight = 1280; // 9:16 portrait 720p
  static const int _vidSteps = 30;

  String get _base {
    final url = AppConfig.comfyuiBaseUrl.trim();
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  int _randomSeed() => Random().nextInt(0x7FFFFFFF);

  /// Text-to-image via Qwen-Image. When `referenceImageUrls` are provided, they
  /// are uploaded and used as consistency anchors through Qwen-Image-Edit-2509
  /// (multi-image conditioning, up to 3 refs); otherwise plain t2i is used.
  Future<String> generateImage(String prompt,
      {List<String>? referenceImageUrls}) async {
    if (_base.isEmpty) {
      throw Exception('ComfyUI 地址未配置，请到设置中填写 ComfyUI Base URL。');
    }
    final refs = (referenceImageUrls ?? const <String>[])
        .where((u) => u.isNotEmpty)
        .take(_maxRefImages)
        .toList();

    final Map<String, dynamic> wf;
    String mode;
    if (refs.isEmpty) {
      wf = _qwenImageWorkflow(prompt);
      mode = 't2i';
    } else {
      final names = <String>[];
      for (var i = 0; i < refs.length; i++) {
        final bytes = await _fetchImageBytes(refs[i]);
        names.add(await _uploadImage(bytes, 'storyforge_ref$i.png'));
      }
      wf = _qwenEditWorkflow(prompt, names);
      mode = 'edit(${names.length} refs)';
    }

    await AppLogger.info('ComfyUI image generation started', data: {
      'tag': 'comfyui.image',
      'endpoint': '$_base/prompt',
      'mode': mode,
      'model': refs.isEmpty ? AppConfig.imageModel : _qwenEditModel,
      'promptLength': prompt.length,
    });
    final outputs = await _runPrompt(wf,
        timeout: const Duration(seconds: 300), tag: 'comfyui.image');
    final url = _firstOutputUrl(outputs, const ['images']);
    if (url == null) throw Exception('ComfyUI 出图响应中没有图片');
    await AppLogger.info('ComfyUI image generation completed',
        data: {'tag': 'comfyui.image', 'mode': mode, 'url': url});
    return url;
  }

  /// ComfyUI has no native multi-image consistency mode; generate one by one.
  Future<List<String>> generateImagesSequential(List<String> prompts) async {
    final urls = <String>[];
    for (final p in prompts) {
      urls.add(await generateImage(p));
    }
    return urls;
  }

  /// Image-to-video via Wan2.2-TI2V-5B. The first frame is fetched (from a URL
  /// or local cache), uploaded to ComfyUI's input folder, then animated.
  Future<String> generateVideo({
    required String prompt,
    required String firstFrameUrl,
    int duration = 5,
    List<String>? referenceImageUrls,
  }) async {
    if (_base.isEmpty) {
      throw Exception('ComfyUI 地址未配置，请到设置中填写 ComfyUI Base URL。');
    }
    final bytes = await _fetchImageBytes(firstFrameUrl);
    final imageName = await _uploadImage(bytes, 'storyforge_start.png');

    const fps = 24;
    // TI2V-5B is 24fps. Cap clips at ~3s: the 5B model loses motion coherence
    // over long generations (limbs melt, subjects drift) — short clips stay
    // physically plausible. Longer shots should be split, not stretched here.
    const maxFrames = 73; // ~3s
    var length = duration * fps + 1;
    if (length < 25) length = 25; // ~1s floor
    if (length > maxFrames) length = maxFrames;

    final wf = _wanI2VWorkflow(prompt, imageName, length, fps);
    await AppLogger.info('ComfyUI video generation started', data: {
      'tag': 'comfyui.video',
      'endpoint': '$_base/prompt',
      'model': AppConfig.videoModel,
      'length': length,
      'firstFrame': imageName,
    });
    final outputs = await _runPrompt(wf,
        timeout: const Duration(seconds: 900), tag: 'comfyui.video');
    final url = _firstOutputUrl(outputs, const ['images', 'gifs', 'videos']);
    if (url == null) throw Exception('ComfyUI 出视频响应中没有视频');
    await AppLogger.info('ComfyUI video generation completed',
        data: {'tag': 'comfyui.video', 'url': url});
    return url;
  }

  void dispose() => _client.close();

  // --------------------------------------------------------------------------
  // Workflows (API format), mirroring the manually verified graphs.
  // --------------------------------------------------------------------------

  Map<String, dynamic> _qwenImageWorkflow(String prompt) {
    return {
      '1': {
        'class_type': 'UNETLoader',
        'inputs': {
          'unet_name': AppConfig.imageModel,
          'weight_dtype': 'default',
        },
      },
      '2': {
        'class_type': 'CLIPLoader',
        'inputs': {'clip_name': _qwenClip, 'type': 'qwen_image'},
      },
      '3': {
        'class_type': 'VAELoader',
        'inputs': {'vae_name': _qwenVae},
      },
      '4': {
        'class_type': 'CLIPTextEncode',
        'inputs': {
          'text': prompt,
          'clip': ['2', 0]
        },
      },
      '5': {
        'class_type': 'CLIPTextEncode',
        'inputs': {
          'text': _negImage,
          'clip': ['2', 0]
        },
      },
      '6': {
        'class_type': 'EmptySD3LatentImage',
        'inputs': {'width': _imgWidth, 'height': _imgHeight, 'batch_size': 1},
      },
      '7': {
        'class_type': 'ModelSamplingAuraFlow',
        'inputs': {
          'model': ['1', 0],
          'shift': 3.1
        },
      },
      '8': {
        'class_type': 'KSampler',
        'inputs': {
          'model': ['7', 0],
          'seed': _randomSeed(),
          'steps': _imgSteps,
          'cfg': _imgCfg,
          'sampler_name': 'euler',
          'scheduler': 'simple',
          'positive': ['4', 0],
          'negative': ['5', 0],
          'latent_image': ['6', 0],
          'denoise': 1.0,
        },
      },
      '9': {
        'class_type': 'VAEDecode',
        'inputs': {
          'samples': ['8', 0],
          'vae': ['3', 0]
        },
      },
      '10': {
        'class_type': 'SaveImage',
        'inputs': {
          'images': ['9', 0],
          'filename_prefix': 'storyforge_img'
        },
      },
    };
  }

  /// Qwen-Image-Edit-2509 with up to 3 reference images for consistency.
  /// Verified against the server: UNETLoader(edit) + TextEncodeQwenImageEditPlus
  /// (prompt + image1..N) + ModelSamplingAuraFlow + KSampler.
  Map<String, dynamic> _qwenEditWorkflow(
      String prompt, List<String> imageNames) {
    final wf = <String, dynamic>{
      '1': {
        'class_type': 'UNETLoader',
        'inputs': {'unet_name': _qwenEditModel, 'weight_dtype': 'default'},
      },
      '2': {
        'class_type': 'CLIPLoader',
        'inputs': {'clip_name': _qwenClip, 'type': 'qwen_image'},
      },
      '3': {
        'class_type': 'VAELoader',
        'inputs': {'vae_name': _qwenVae},
      },
      '5': {
        'class_type': 'TextEncodeQwenImageEditPlus',
        'inputs': {
          'clip': ['2', 0],
          'prompt': _negImage
        },
      },
      '7': {
        'class_type': 'ModelSamplingAuraFlow',
        'inputs': {
          'model': ['1', 0],
          'shift': 3.0
        },
      },
      '8': {
        'class_type': 'EmptySD3LatentImage',
        'inputs': {'width': _imgWidth, 'height': _imgHeight, 'batch_size': 1},
      },
      '9': {
        'class_type': 'KSampler',
        'inputs': {
          'model': ['7', 0],
          'seed': _randomSeed(),
          'steps': _imgSteps,
          'cfg': _imgCfg,
          'sampler_name': 'euler',
          'scheduler': 'simple',
          'positive': ['4', 0],
          'negative': ['5', 0],
          'latent_image': ['8', 0],
          'denoise': 1.0,
        },
      },
      '10': {
        'class_type': 'VAEDecode',
        'inputs': {
          'samples': ['9', 0],
          'vae': ['3', 0]
        },
      },
      '11': {
        'class_type': 'SaveImage',
        'inputs': {
          'images': ['10', 0],
          'filename_prefix': 'storyforge_img'
        },
      },
    };
    final posInputs = <String, dynamic>{
      'clip': ['2', 0],
      'prompt': prompt,
      'vae': ['3', 0],
    };
    for (var i = 0; i < imageNames.length; i++) {
      final loadId = '${20 + i}';
      wf[loadId] = {
        'class_type': 'LoadImage',
        'inputs': {'image': imageNames[i]},
      };
      posInputs['image${i + 1}'] = [loadId, 0];
    }
    wf['4'] = {
      'class_type': 'TextEncodeQwenImageEditPlus',
      'inputs': posInputs,
    };
    return wf;
  }

  Map<String, dynamic> _wanI2VWorkflow(
      String prompt, String imageName, int length, int fps) {
    return {
      '1': {
        'class_type': 'UNETLoader',
        'inputs': {
          'unet_name': AppConfig.videoModel,
          'weight_dtype': 'default',
        },
      },
      '2': {
        'class_type': 'CLIPLoader',
        'inputs': {'clip_name': _wanClip, 'type': 'wan'},
      },
      '3': {
        'class_type': 'VAELoader',
        'inputs': {'vae_name': _wanVae},
      },
      '4': {
        'class_type': 'CLIPTextEncode',
        'inputs': {
          'text': prompt,
          'clip': ['2', 0]
        },
      },
      '5': {
        'class_type': 'CLIPTextEncode',
        'inputs': {
          'text': _negVideo,
          'clip': ['2', 0]
        },
      },
      '6': {
        'class_type': 'LoadImage',
        'inputs': {'image': imageName},
      },
      '7': {
        'class_type': 'Wan22ImageToVideoLatent',
        'inputs': {
          'vae': ['3', 0],
          'width': _vidWidth,
          'height': _vidHeight,
          'length': length,
          'batch_size': 1,
          'start_image': ['6', 0],
        },
      },
      '8': {
        'class_type': 'ModelSamplingSD3',
        'inputs': {
          'model': ['1', 0],
          'shift': 8.0
        },
      },
      '9': {
        'class_type': 'KSampler',
        'inputs': {
          'model': ['8', 0],
          'seed': _randomSeed(),
          'steps': _vidSteps,
          'cfg': 5.0,
          'sampler_name': 'euler',
          'scheduler': 'simple',
          'positive': ['4', 0],
          'negative': ['5', 0],
          'latent_image': ['7', 0],
          'denoise': 1.0,
        },
      },
      '10': {
        'class_type': 'VAEDecode',
        'inputs': {
          'samples': ['9', 0],
          'vae': ['3', 0]
        },
      },
      '11': {
        'class_type': 'CreateVideo',
        'inputs': {
          'images': ['10', 0],
          'fps': fps.toDouble()
        },
      },
      '12': {
        'class_type': 'SaveVideo',
        'inputs': {
          'video': ['11', 0],
          'filename_prefix': 'storyforge_vid',
          'format': 'mp4',
          'codec': 'h264',
        },
      },
    };
  }

  // --------------------------------------------------------------------------
  // HTTP helpers
  // --------------------------------------------------------------------------

  Future<Map<String, dynamic>> _runPrompt(
    Map<String, dynamic> workflow, {
    required Duration timeout,
    required String tag,
  }) async {
    final clientId = 'storyforge_${DateTime.now().microsecondsSinceEpoch}';
    http.Response resp;
    try {
      resp = await _client
          .post(
            Uri.parse('$_base/prompt'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'prompt': workflow, 'client_id': clientId}),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw Exception('ComfyUI 提交超时（60 秒）。请检查 ComfyUI 地址与网络。');
    } on SocketException catch (e) {
      throw Exception('无法连接 ComfyUI ($_base)：${e.message}');
    }

    if (resp.statusCode != 200) {
      final msg = _promptErrorMessage(resp.body, resp.statusCode);
      await AppLogger.error('ComfyUI /prompt rejected', data: {
        'tag': tag,
        'statusCode': resp.statusCode,
        'bodyPreview': AppLogger.preview(resp.body),
      });
      throw Exception('ComfyUI 任务提交失败 ($msg)');
    }

    final promptId =
        (jsonDecode(resp.body) as Map<String, dynamic>)['prompt_id'] as String?;
    if (promptId == null) throw Exception('ComfyUI 响应中没有 prompt_id');

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 2));
      http.Response h;
      try {
        h = await _client
            .get(Uri.parse('$_base/history/$promptId'))
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        continue;
      } on SocketException {
        continue;
      }
      if (h.statusCode != 200) continue;
      final data = jsonDecode(h.body) as Map<String, dynamic>;
      final entry = data[promptId];
      if (entry is! Map) continue;

      final status = entry['status'];
      final statusStr =
          (status is Map) ? status['status_str'] as String? : null;
      if (statusStr == 'error') {
        final messages = (status as Map)['messages'];
        throw Exception('ComfyUI 执行出错: ${jsonEncode(messages)}');
      }
      final outputs = entry['outputs'];
      if (outputs is Map && outputs.isNotEmpty) {
        return outputs.cast<String, dynamic>();
      }
      // present but no outputs yet -> keep polling
    }
    throw Exception('ComfyUI 任务超时（${timeout.inSeconds} 秒）');
  }

  String? _firstOutputUrl(Map<String, dynamic> outputs, List<String> keys) {
    for (final node in outputs.values) {
      if (node is! Map) continue;
      for (final k in keys) {
        final arr = node[k];
        if (arr is List && arr.isNotEmpty) {
          final item = arr.first;
          if (item is Map && item['filename'] != null) {
            return _viewUrl(
              item['filename'].toString(),
              (item['subfolder'] ?? '').toString(),
              (item['type'] ?? 'output').toString(),
            );
          }
        }
      }
    }
    return null;
  }

  String _viewUrl(String filename, String subfolder, String type) {
    final qs = <String, String>{
      'filename': filename,
      'subfolder': subfolder,
      'type': type,
    }
        .entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$_base/view?$qs';
  }

  Future<List<int>> _fetchImageBytes(String source) async {
    if (PersistentImageStore.isLocalPath(source)) {
      final path = PersistentImageStore.normalizeLocalPath(source);
      if (path != null && File(path).existsSync()) {
        return File(path).readAsBytes();
      }
      throw Exception('首帧本地文件不存在: $source');
    }
    final uri = Uri.tryParse(source);
    if (uri == null) throw Exception('首帧 URL 无效: $source');
    http.Response resp;
    try {
      resp = await _client.get(uri).timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw Exception('获取首帧超时');
    } on SocketException catch (e) {
      throw Exception('获取首帧失败: ${e.message}');
    }
    if (resp.statusCode != 200) {
      throw Exception('获取首帧失败 (HTTP ${resp.statusCode})');
    }
    return resp.bodyBytes;
  }

  Future<String> _uploadImage(List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/upload/image'))
      ..fields['overwrite'] = 'true'
      ..files.add(
          http.MultipartFile.fromBytes('image', bytes, filename: filename));
    http.StreamedResponse streamed;
    try {
      streamed = await _client.send(req).timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw Exception('上传首帧到 ComfyUI 超时');
    } on SocketException catch (e) {
      throw Exception('上传首帧到 ComfyUI 失败: ${e.message}');
    }
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception('上传首帧失败 (HTTP ${streamed.statusCode}): $body');
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    final name = j['name'] as String?;
    final subfolder = (j['subfolder'] as String?) ?? '';
    if (name == null) throw Exception('上传首帧响应中没有文件名');
    return subfolder.isNotEmpty ? '$subfolder/$name' : name;
  }

  String _promptErrorMessage(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] != null) {
          return '${err['type'] ?? statusCode}: ${err['message']}';
        }
      }
    } catch (_) {}
    return 'HTTP $statusCode';
  }
}
