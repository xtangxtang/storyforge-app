import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String _llmBaseUrl = 'LLM_BASE_URL';
  static const String _llmApiKey = 'LLM_API_KEY';
  static const String _llmModel = 'LLM_MODEL';
  static const String _dashscopeApiKey = 'DASHSCOPE_API_KEY';
  static const String _httpsProxy = 'HTTPS_PROXY';
    static const Set<String> _legacyLlmBaseUrls = {
    'https://coding.dashscope.aliyuncs.com/compatible-mode/v1',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    };

  static const String defaultLlmBaseUrl =
      'https://coding.dashscope.aliyuncs.com/v1';
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
    llmBaseUrl =
        _normalizeBaseUrl(prefs.getString(_llmBaseUrl) ?? defaultLlmBaseUrl);
    if (_legacyLlmBaseUrls.contains(llmBaseUrl)) {
      llmBaseUrl = defaultLlmBaseUrl;
      await prefs.setString(_llmBaseUrl, llmBaseUrl);
    }
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

  static String _normalizeBaseUrl(String value) {
    return value.trim().replaceAll(RegExp(r'/+$'), '');
  }
}
