import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'ark_service.dart';
import 'comfyui_service.dart';
import 'dashscope_service.dart';

/// Facade that routes image/video generation to the backend selected by the
/// active config profile (cloud DashScope vs self-hosted ComfyUI).
///
/// Its public surface matches [DashscopeService] so existing call sites can use
/// it as a drop-in replacement.
class MediaService {
  final DashscopeService _dashscope;
  ComfyuiService? _comfyui;
  ArkService? _arkService;

  MediaService({http.Client? client})
      : _dashscope = DashscopeService(client: client);

  ComfyuiService get _comfy => _comfyui ??= ComfyuiService();
  ArkService get _ark => _arkService ??= ArkService();

  Future<String> generateImage(String prompt,
      {List<String>? referenceImageUrls}) {
    if (AppConfig.useArkForImage) {
      return _ark.generateImage(prompt, referenceImageUrls: referenceImageUrls);
    }
    if (AppConfig.useComfyuiForImage) {
      return _comfy.generateImage(prompt,
          referenceImageUrls: referenceImageUrls);
    }
    return _dashscope.generateImage(prompt,
        referenceImageUrls: referenceImageUrls);
  }

  Future<List<String>> generateImagesSequential(List<String> prompts) {
    if (AppConfig.useArkForImage) {
      return _ark.generateImagesSequential(prompts);
    }
    if (AppConfig.useComfyuiForImage) {
      return _comfy.generateImagesSequential(prompts);
    }
    return _dashscope.generateImagesSequential(prompts);
  }

  Future<String> generateVideo({
    required String prompt,
    required String firstFrameUrl,
    int duration = 5,
    List<String>? referenceImageUrls,
    List<String>? referenceVideoUrls,
  }) {
    if (AppConfig.useArkForVideo) {
      return _ark.generateVideo(
        prompt: prompt,
        firstFrameUrl: firstFrameUrl,
        duration: duration,
        referenceImageUrls: referenceImageUrls,
        referenceVideoUrls: referenceVideoUrls,
      );
    }
    if (AppConfig.useComfyuiForVideo) {
      return _comfy.generateVideo(
        prompt: prompt,
        firstFrameUrl: firstFrameUrl,
        duration: duration,
        referenceImageUrls: referenceImageUrls,
      );
    }
    return _dashscope.generateVideo(
      prompt: prompt,
      firstFrameUrl: firstFrameUrl,
      duration: duration,
      referenceImageUrls: referenceImageUrls,
    );
  }

  void dispose() {
    _dashscope.dispose();
    _comfyui?.dispose();
    _arkService?.dispose();
  }
}
