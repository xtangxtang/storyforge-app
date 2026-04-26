import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String _llmBaseUrl = 'LLM_BASE_URL';
  static const String _llmApiKey = 'LLM_API_KEY';
  static const String _llmModel = 'LLM_MODEL';
  static const String _dashscopeApiKey = 'DASHSCOPE_API_KEY';
  static const String _httpsProxy = 'HTTPS_PROXY';

  static const String defaultLlmBaseUrl =
      'https://coding.dashscope.aliyuncs.com/compatible-mode/v1';
  static const String defaultDashscopeBaseUrl =
      'https://dashscope.aliyuncs.com';
  static const String defaultModel = 'qwen3.6-plus';

  static String llmBaseUrl = defaultLlmBaseUrl;
  static String llmApiKey = '';
  static String llmModel = defaultModel;
  static String dashscopeApiKey = '';
  static String dashscopeBaseUrl = defaultDashscopeBaseUrl;
  static String httpsProxy = '';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    llmBaseUrl = prefs.getString(_llmBaseUrl) ?? defaultLlmBaseUrl;
    llmApiKey = prefs.getString(_llmApiKey) ?? '';
    llmModel = prefs.getString(_llmModel) ?? defaultModel;
    dashscopeApiKey = prefs.getString(_dashscopeApiKey) ?? '';
    httpsProxy = prefs.getString(_httpsProxy) ?? '';
  }

  static Future<void> save({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? dashscopeKey,
    String? proxy,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      await prefs.setString(_llmBaseUrl, baseUrl);
      llmBaseUrl = baseUrl;
    }
    if (apiKey != null) {
      await prefs.setString(_llmApiKey, apiKey);
      llmApiKey = apiKey;
    }
    if (model != null) {
      await prefs.setString(_llmModel, model);
      llmModel = model;
    }
    if (dashscopeKey != null) {
      await prefs.setString(_dashscopeApiKey, dashscopeKey);
      dashscopeApiKey = dashscopeKey;
    }
    if (proxy != null) {
      await prefs.setString(_httpsProxy, proxy);
      httpsProxy = proxy;
    }
  }

  static bool get isConfigured =>
      llmApiKey.isNotEmpty && dashscopeApiKey.isNotEmpty;
}
