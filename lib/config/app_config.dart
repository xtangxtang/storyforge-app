import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  // LLM config
  static const String _llmBaseUrl = 'LLM_BASE_URL';
  static const String _llmApiKey = 'LLM_API_KEY';
  static const String _llmModel = 'LLM_MODEL';

  // Image config
  static const String _imageBaseUrl = 'IMAGE_BASE_URL';
  static const String _imageApiKey = 'IMAGE_API_KEY';
  static const String _imageModel = 'IMAGE_MODEL';

  // Video config
  static const String _videoBaseUrl = 'VIDEO_BASE_URL';
  static const String _videoApiKey = 'VIDEO_API_KEY';
  static const String _videoModel = 'VIDEO_MODEL';

  // Video generation mode: 'api' (wan2.7-i2v via DashScope) or 'seedance' (web automation)
  static const String _videoGenerationMode = 'VIDEO_GENERATION_MODE';

  // Network
  static const String _httpsProxy = 'HTTPS_PROXY';

  // Seedance web automation
  static const String _seedanceUrl = 'SEEDANCE_URL';
  static const String _seedanceEmail = 'SEEDANCE_EMAIL';
  static const String _seedancePassword = 'SEEDANCE_PASSWORD';

  static const Set<String> _legacyLlmBaseUrls = {
    'https://coding.dashscope.aliyuncs.com/compatible-mode/v1',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
  };

  // Defaults
  static const String defaultLlmBaseUrl =
      'https://coding.dashscope.aliyuncs.com/v1';
  static const String defaultImageBaseUrl = 'https://dashscope.aliyuncs.com';
  static const String defaultVideoBaseUrl = 'https://dashscope.aliyuncs.com';
  static const String defaultModel = 'qwen3.6-plus';
  static const String defaultImageModel = 'wan2.7-image-pro';
  static const String defaultVideoModel = 'wan2.7-i2v';

  // Runtime values
  static String llmBaseUrl = defaultLlmBaseUrl;
  static String llmApiKey = '';
  static String llmModel = defaultModel;

  static String imageBaseUrl = defaultImageBaseUrl;
  static String imageApiKey = '';
  static String imageModel = defaultImageModel;

  static String videoBaseUrl = defaultVideoBaseUrl;
  static String videoApiKey = '';
  static String videoModel = defaultVideoModel;

  static String videoGenerationMode = 'api'; // 'api' or 'seedance'
  static bool get useSeedanceForVideo => videoGenerationMode == 'seedance';

  static String httpsProxy = '';

  // Seedance web
  static String seedanceUrl = 'https://seedance.io/zh/seedance-2';
  static String seedanceEmail = '';
  static String seedancePassword = '';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    llmBaseUrl =
        _normalizeBaseUrl(prefs.getString(_llmBaseUrl) ?? defaultLlmBaseUrl);
    if (_legacyLlmBaseUrls.contains(llmBaseUrl)) {
      llmBaseUrl = defaultLlmBaseUrl;
      await prefs.setString(_llmBaseUrl, llmBaseUrl);
    }
    llmApiKey = prefs.getString(_llmApiKey) ?? '';
    llmModel = prefs.getString(_llmModel) ?? defaultModel;

    imageBaseUrl = prefs.getString(_imageBaseUrl) ?? defaultImageBaseUrl;
    imageApiKey = prefs.getString(_imageApiKey) ?? '';
    imageModel = prefs.getString(_imageModel) ?? defaultImageModel;

    videoBaseUrl = prefs.getString(_videoBaseUrl) ?? defaultVideoBaseUrl;
    videoApiKey = prefs.getString(_videoApiKey) ?? '';
    videoModel = prefs.getString(_videoModel) ?? defaultVideoModel;

    videoGenerationMode = prefs.getString(_videoGenerationMode) ?? 'api';

    httpsProxy = prefs.getString(_httpsProxy) ?? '';

    seedanceUrl =
        prefs.getString(_seedanceUrl) ?? 'https://seedance.io/zh/seedance-2';
    seedanceEmail = prefs.getString(_seedanceEmail) ?? '';
    seedancePassword = prefs.getString(_seedancePassword) ?? '';
  }

  static Future<void> save({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? imageBaseUrl,
    String? imageApiKey,
    String? imageModel,
    String? videoBaseUrl,
    String? videoApiKey,
    String? videoModel,
    String? videoGenerationMode,
    String? proxy,
    String? seedanceUrl,
    String? seedanceEmail,
    String? seedancePassword,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      final normalizedBaseUrl = _normalizeBaseUrl(baseUrl);
      await prefs.setString(_llmBaseUrl, normalizedBaseUrl);
      llmBaseUrl = normalizedBaseUrl;
    }
    if (apiKey != null) {
      await prefs.setString(_llmApiKey, apiKey);
      llmApiKey = apiKey;
    }
    if (model != null) {
      await prefs.setString(_llmModel, model);
      llmModel = model;
    }
    if (imageBaseUrl != null) {
      await prefs.setString(_imageBaseUrl, imageBaseUrl);
      AppConfig.imageBaseUrl = imageBaseUrl;
    }
    if (imageApiKey != null) {
      await prefs.setString(_imageApiKey, imageApiKey);
      AppConfig.imageApiKey = imageApiKey;
    }
    if (imageModel != null) {
      await prefs.setString(_imageModel, imageModel);
      AppConfig.imageModel = imageModel;
    }
    if (videoBaseUrl != null) {
      await prefs.setString(_videoBaseUrl, videoBaseUrl);
      AppConfig.videoBaseUrl = videoBaseUrl;
    }
    if (videoApiKey != null) {
      await prefs.setString(_videoApiKey, videoApiKey);
      AppConfig.videoApiKey = videoApiKey;
    }
    if (videoModel != null) {
      await prefs.setString(_videoModel, videoModel);
      AppConfig.videoModel = videoModel;
    }
    if (videoGenerationMode != null) {
      await prefs.setString(_videoGenerationMode, videoGenerationMode);
      AppConfig.videoGenerationMode = videoGenerationMode;
    }
    if (proxy != null) {
      await prefs.setString(_httpsProxy, proxy);
      httpsProxy = proxy;
    }
    if (seedanceUrl != null) {
      await prefs.setString(_seedanceUrl, seedanceUrl);
      AppConfig.seedanceUrl = seedanceUrl;
    }
    if (seedanceEmail != null) {
      await prefs.setString(_seedanceEmail, seedanceEmail);
      AppConfig.seedanceEmail = seedanceEmail;
    }
    if (seedancePassword != null) {
      await prefs.setString(_seedancePassword, seedancePassword);
      AppConfig.seedancePassword = seedancePassword;
    }
  }

  static bool get isConfigured {
    final hasTextAndImageKeys = llmApiKey.isNotEmpty && imageApiKey.isNotEmpty;
    if (!hasTextAndImageKeys) return false;
    if (useSeedanceForVideo) return true;
    return videoApiKey.isNotEmpty;
  }

  static String _normalizeBaseUrl(String value) {
    return value.trim().replaceAll(RegExp(r'/+$'), '');
  }
}
