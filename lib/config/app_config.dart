import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config_profile.dart';

/// Global configuration.
///
/// Config is organized into named [ConfigProfile]s (e.g. a cloud DashScope
/// setup vs a self-hosted ComfyUI box). The active profile is mirrored onto the
/// static fields below so the rest of the app keeps reading `AppConfig.xxx`
/// exactly as before. The individual `_xxx` SharedPreferences keys are now only
/// read once, to migrate a pre-profile install into the first profile.
class AppConfig {
  // --- Legacy SharedPreferences keys (read only during one-time migration) ---
  static const String _llmBaseUrl = 'LLM_BASE_URL';
  static const String _llmApiKey = 'LLM_API_KEY';
  static const String _llmModel = 'LLM_MODEL';
  static const String _imageBaseUrl = 'IMAGE_BASE_URL';
  static const String _imageApiKey = 'IMAGE_API_KEY';
  static const String _imageModel = 'IMAGE_MODEL';
  static const String _videoBaseUrl = 'VIDEO_BASE_URL';
  static const String _videoApiKey = 'VIDEO_API_KEY';
  static const String _videoModel = 'VIDEO_MODEL';
  static const String _videoGenerationMode = 'VIDEO_GENERATION_MODE';
  static const String _httpsProxy = 'HTTPS_PROXY';
  static const String _seedanceUrl = 'SEEDANCE_URL';
  static const String _seedanceEmail = 'SEEDANCE_EMAIL';
  static const String _seedancePassword = 'SEEDANCE_PASSWORD';

  // --- Profile storage keys ---
  static const String _kProfiles = 'CONFIG_PROFILES_V1';
  static const String _kActiveProfileId = 'ACTIVE_PROFILE_ID';

  static const Set<String> _legacyLlmBaseUrls = {
    'https://coding.dashscope.aliyuncs.com/compatible-mode/v1',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
  };

  // --- Defaults ---
  static const String defaultLlmBaseUrl =
      'https://coding.dashscope.aliyuncs.com/v1';
  static const String defaultImageBaseUrl = 'https://dashscope.aliyuncs.com';
  static const String defaultVideoBaseUrl = 'https://dashscope.aliyuncs.com';
  static const String defaultModel = 'qwen3.6-plus';
  static const String defaultImageModel = 'wan2.7-image-pro';
  static const String defaultVideoModel = 'wan2.7-i2v';
  static const String defaultComfyuiBaseUrl = 'http://172.16.116.208:8188';
  static const String defaultComfyuiImageModel =
      'qwen_image_2512_fp8_e4m3fn.safetensors';
  static const String defaultComfyuiVideoModel =
      'wan2.2_ti2v_5B_fp16.safetensors';
  // Volcengine Ark (agent plan). Models follow ENGLISH prompts; image size must
  // be >= 3.7MP. Key is NOT hardcoded — entered in Settings, stored in prefs.
  static const String defaultArkBaseUrl =
      'https://ark.cn-beijing.volces.com/api/plan/v3';
  static const String defaultArkImageModel = 'doubao-seedream-5.0-lite';
  static const String defaultArkVideoModel = 'doubao-seedance-2.0';

  // --- Runtime values (mirror of the active profile) ---
  static String llmBaseUrl = defaultLlmBaseUrl;
  static String llmApiKey = '';
  static String llmModel = defaultModel;

  static String imageProvider = 'dashscope'; // 'dashscope' | 'comfyui'
  static String imageBaseUrl = defaultImageBaseUrl;
  static String imageApiKey = '';
  static String imageModel = defaultImageModel;

  static String videoProvider = 'dashscope'; // 'dashscope' | 'comfyui'
  static String videoBaseUrl = defaultVideoBaseUrl;
  static String videoApiKey = '';
  static String videoModel = defaultVideoModel;

  // Only relevant while videoProvider == 'dashscope': 'api' | 'seedance'
  static String videoGenerationMode = 'api';

  static String comfyuiBaseUrl = defaultComfyuiBaseUrl;

  // Volcengine Ark
  static String arkBaseUrl = defaultArkBaseUrl;
  static String arkApiKey = '';
  static String arkImageModel = defaultArkImageModel;
  static String arkVideoModel = defaultArkVideoModel;

  static String httpsProxy = '';

  static String seedanceUrl = 'https://seedance.io/zh/seedance-2';
  static String seedanceEmail = '';
  static String seedancePassword = '';

  static bool get useSeedanceForVideo =>
      videoProvider == 'dashscope' && videoGenerationMode == 'seedance';
  static bool get useComfyuiForImage => imageProvider == 'comfyui';
  static bool get useComfyuiForVideo => videoProvider == 'comfyui';
  static bool get useArkForImage => imageProvider == 'ark';
  static bool get useArkForVideo => videoProvider == 'ark';

  // --- Profiles ---
  static List<ConfigProfile> profiles = [];
  static String activeProfileId = '';

  static ConfigProfile? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.isNotEmpty ? profiles.first : null;
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfiles);
    if (raw == null || raw.isEmpty) {
      await _migrateFromLegacy(prefs);
    } else {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => ConfigProfile.fromJson(e as Map<String, dynamic>))
            .toList();
        profiles = list;
      } catch (_) {
        profiles = [];
      }
      if (profiles.isEmpty) {
        await _migrateFromLegacy(prefs);
      } else {
        activeProfileId =
            prefs.getString(_kActiveProfileId) ?? profiles.first.id;
        if (activeProfile == null) activeProfileId = profiles.first.id;
      }
    }
    final active = activeProfile;
    if (active != null) _applyProfile(active);

    await _loadLocalOverrides();
    _applyLocalOverrides();
  }

  // --- Local config override (gitignored config.local.json) ---
  // Lets the user keep API keys out of source control: any non-empty value in
  // config.local.json overrides the active profile's runtime field at startup
  // (and on every profile switch), without ever being committed.
  static Map<String, dynamic> _localOverrides = const {};

  static Future<void> _loadLocalOverrides() async {
    for (final path in _localConfigCandidatePaths()) {
      try {
        final f = File(path);
        if (!f.existsSync()) continue;
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          _localOverrides = Map<String, dynamic>.from(decoded);
          return;
        }
      } catch (_) {
        // ignore a malformed/locked file — overrides are best-effort
      }
    }
    _localOverrides = const {};
  }

  static List<String> _localConfigCandidatePaths() {
    const name = 'config.local.json';
    final paths = <String>[name]; // cwd (project root under `flutter run`)
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      paths.add('$exeDir${Platform.pathSeparator}$name');
    } catch (_) {}
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      paths.add('$localAppData\\Storyforge\\$name');
    }
    return paths;
  }

  static String? _ov(String key) {
    final v = _localOverrides[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  /// Apply non-empty values from config.local.json onto the runtime fields.
  /// Secret-bearing fields are intentionally limited to the useful set.
  static void _applyLocalOverrides() {
    final p = activeProfile;
    void set(String key, void Function(String v) apply) {
      final v = _ov(key);
      if (v != null) apply(v);
    }

    set('llmApiKey', (v) {
      llmApiKey = v;
      p?.llmApiKey = v;
    });
    set('arkApiKey', (v) {
      arkApiKey = v;
      p?.arkApiKey = v;
    });
    set('arkBaseUrl', (v) {
      arkBaseUrl = v;
      p?.arkBaseUrl = v;
    });
    set('arkImageModel', (v) {
      arkImageModel = v;
      p?.arkImageModel = v;
    });
    set('arkVideoModel', (v) {
      arkVideoModel = v;
      p?.arkVideoModel = v;
    });
    set('imageApiKey', (v) {
      imageApiKey = v;
      p?.imageApiKey = v;
    });
    set('videoApiKey', (v) {
      videoApiKey = v;
      p?.videoApiKey = v;
    });
    set('httpsProxy', (v) {
      httpsProxy = v;
      p?.httpsProxy = v;
    });
  }

  /// Build the initial profile set from the old flat SharedPreferences keys.
  /// Creates a "DashScope（云端）" profile, a "ComfyUI（A100 本地）" profile, and a
  /// "火山 Ark（豆包）" profile (Seedream 5.0 lite + Seedance 2.0). Ark is the
  /// default — the user just needs to paste the Ark API key in Settings once.
  static Future<void> _migrateFromLegacy(SharedPreferences prefs) async {
    var llmBase =
        _normalizeBaseUrl(prefs.getString(_llmBaseUrl) ?? defaultLlmBaseUrl);
    if (_legacyLlmBaseUrls.contains(llmBase)) llmBase = defaultLlmBaseUrl;

    final dash = ConfigProfile(
      id: _newId(),
      name: 'DashScope（云端）',
      llmBaseUrl: llmBase,
      llmApiKey: prefs.getString(_llmApiKey) ?? '',
      llmModel: prefs.getString(_llmModel) ?? defaultModel,
      imageProvider: 'dashscope',
      imageBaseUrl: prefs.getString(_imageBaseUrl) ?? defaultImageBaseUrl,
      imageApiKey: prefs.getString(_imageApiKey) ?? '',
      imageModel: prefs.getString(_imageModel) ?? defaultImageModel,
      videoProvider: 'dashscope',
      videoGenerationMode: prefs.getString(_videoGenerationMode) ?? 'api',
      videoBaseUrl: prefs.getString(_videoBaseUrl) ?? defaultVideoBaseUrl,
      videoApiKey: prefs.getString(_videoApiKey) ?? '',
      videoModel: prefs.getString(_videoModel) ?? defaultVideoModel,
      comfyuiBaseUrl: defaultComfyuiBaseUrl,
      arkBaseUrl: defaultArkBaseUrl,
      arkApiKey: '',
      arkImageModel: defaultArkImageModel,
      arkVideoModel: defaultArkVideoModel,
      httpsProxy: prefs.getString(_httpsProxy) ?? '',
      seedanceUrl:
          prefs.getString(_seedanceUrl) ?? 'https://seedance.io/zh/seedance-2',
      seedanceEmail: prefs.getString(_seedanceEmail) ?? '',
      seedancePassword: prefs.getString(_seedancePassword) ?? '',
    );

    // ComfyUI profile reuses the LLM + proxy from the current config, since
    // planning/scripting still go through a chat-completions endpoint.
    final comfy = ConfigProfile(
      id: _newId(),
      name: 'ComfyUI（A100 本地）',
      llmBaseUrl: dash.llmBaseUrl,
      llmApiKey: dash.llmApiKey,
      llmModel: dash.llmModel,
      imageProvider: 'comfyui',
      imageBaseUrl: dash.imageBaseUrl,
      imageApiKey: dash.imageApiKey,
      imageModel: defaultComfyuiImageModel,
      videoProvider: 'comfyui',
      videoGenerationMode: 'api',
      videoBaseUrl: dash.videoBaseUrl,
      videoApiKey: dash.videoApiKey,
      videoModel: defaultComfyuiVideoModel,
      comfyuiBaseUrl: defaultComfyuiBaseUrl,
      arkBaseUrl: defaultArkBaseUrl,
      arkApiKey: '',
      arkImageModel: defaultArkImageModel,
      arkVideoModel: defaultArkVideoModel,
      httpsProxy: dash.httpsProxy,
      seedanceUrl: dash.seedanceUrl,
      seedanceEmail: dash.seedanceEmail,
      seedancePassword: dash.seedancePassword,
    );

    // Ark profile: cloud Seedream/Seedance. Image + video both on Ark; LLM +
    // proxy reuse the existing config. Key entered in Settings (not stored here).
    final ark = ConfigProfile(
      id: _newId(),
      name: '火山 Ark（豆包）',
      llmBaseUrl: dash.llmBaseUrl,
      llmApiKey: dash.llmApiKey,
      llmModel: dash.llmModel,
      imageProvider: 'ark',
      imageBaseUrl: dash.imageBaseUrl,
      imageApiKey: dash.imageApiKey,
      imageModel: defaultImageModel,
      videoProvider: 'ark',
      videoGenerationMode: 'api',
      videoBaseUrl: dash.videoBaseUrl,
      videoApiKey: dash.videoApiKey,
      videoModel: defaultVideoModel,
      comfyuiBaseUrl: defaultComfyuiBaseUrl,
      arkBaseUrl: defaultArkBaseUrl,
      arkApiKey: '',
      arkImageModel: defaultArkImageModel,
      arkVideoModel: defaultArkVideoModel,
      httpsProxy: dash.httpsProxy,
      seedanceUrl: dash.seedanceUrl,
      seedanceEmail: dash.seedanceEmail,
      seedancePassword: dash.seedancePassword,
    );

    profiles = [ark, comfy, dash];
    activeProfileId = ark.id;
    await _persist(prefs);
  }

  static void _applyProfile(ConfigProfile p) {
    llmBaseUrl = p.llmBaseUrl;
    llmApiKey = p.llmApiKey;
    llmModel = p.llmModel;
    imageProvider = p.imageProvider;
    imageBaseUrl = p.imageBaseUrl;
    imageApiKey = p.imageApiKey;
    imageModel = p.imageModel;
    videoProvider = p.videoProvider;
    videoGenerationMode = p.videoGenerationMode;
    videoBaseUrl = p.videoBaseUrl;
    videoApiKey = p.videoApiKey;
    videoModel = p.videoModel;
    comfyuiBaseUrl = p.comfyuiBaseUrl;
    arkBaseUrl = p.arkBaseUrl;
    arkApiKey = p.arkApiKey;
    arkImageModel = p.arkImageModel;
    arkVideoModel = p.arkVideoModel;
    httpsProxy = p.httpsProxy;
    seedanceUrl = p.seedanceUrl;
    seedanceEmail = p.seedanceEmail;
    seedancePassword = p.seedancePassword;
  }

  static ConfigProfile _snapshotCurrent(String id, String name) =>
      ConfigProfile(
        id: id,
        name: name,
        llmBaseUrl: llmBaseUrl,
        llmApiKey: llmApiKey,
        llmModel: llmModel,
        imageProvider: imageProvider,
        imageBaseUrl: imageBaseUrl,
        imageApiKey: imageApiKey,
        imageModel: imageModel,
        videoProvider: videoProvider,
        videoGenerationMode: videoGenerationMode,
        videoBaseUrl: videoBaseUrl,
        videoApiKey: videoApiKey,
        videoModel: videoModel,
        comfyuiBaseUrl: comfyuiBaseUrl,
        arkBaseUrl: arkBaseUrl,
        arkApiKey: arkApiKey,
        arkImageModel: arkImageModel,
        arkVideoModel: arkVideoModel,
        httpsProxy: httpsProxy,
        seedanceUrl: seedanceUrl,
        seedanceEmail: seedanceEmail,
        seedancePassword: seedancePassword,
      );

  static Future<void> _persist(SharedPreferences prefs) async {
    await prefs.setString(
        _kProfiles, jsonEncode(profiles.map((e) => e.toJson()).toList()));
    await prefs.setString(_kActiveProfileId, activeProfileId);
  }

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// Switch the active profile and apply its values.
  static Future<void> switchProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    activeProfileId = id;
    final p = activeProfile;
    if (p != null) _applyProfile(p);
    _applyLocalOverrides();
    await _persist(prefs);
  }

  /// Snapshot the current runtime config into a brand new profile and activate
  /// it. Returns the created profile.
  static Future<ConfigProfile> createProfileFromCurrent(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final p =
        _snapshotCurrent(_newId(), name.trim().isEmpty ? '新配置' : name.trim());
    profiles.add(p);
    activeProfileId = p.id;
    await _persist(prefs);
    return p;
  }

  static Future<void> deleteProfile(String id) async {
    if (profiles.length <= 1) return; // never delete the last profile
    final prefs = await SharedPreferences.getInstance();
    profiles.removeWhere((p) => p.id == id);
    if (activeProfileId == id) {
      activeProfileId = profiles.first.id;
      final active = activeProfile;
      if (active != null) _applyProfile(active);
    }
    await _persist(prefs);
  }

  static Future<void> renameProfile(String id, String name) async {
    final prefs = await SharedPreferences.getInstance();
    for (final p in profiles) {
      if (p.id == id) p.name = name.trim().isEmpty ? p.name : name.trim();
    }
    await _persist(prefs);
  }

  /// Persist edits from the settings form into the active profile.
  static Future<void> save({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? imageProvider,
    String? imageBaseUrl,
    String? imageApiKey,
    String? imageModel,
    String? videoProvider,
    String? videoBaseUrl,
    String? videoApiKey,
    String? videoModel,
    String? videoGenerationMode,
    String? comfyuiBaseUrl,
    String? arkBaseUrl,
    String? arkApiKey,
    String? arkImageModel,
    String? arkVideoModel,
    String? proxy,
    String? seedanceUrl,
    String? seedanceEmail,
    String? seedancePassword,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final p = activeProfile;
    if (p == null) return;

    if (baseUrl != null) p.llmBaseUrl = _normalizeBaseUrl(baseUrl);
    if (apiKey != null) p.llmApiKey = apiKey;
    if (model != null) p.llmModel = model;
    if (imageProvider != null) p.imageProvider = imageProvider;
    if (imageBaseUrl != null) p.imageBaseUrl = imageBaseUrl;
    if (imageApiKey != null) p.imageApiKey = imageApiKey;
    if (imageModel != null) p.imageModel = imageModel;
    if (videoProvider != null) p.videoProvider = videoProvider;
    if (videoBaseUrl != null) p.videoBaseUrl = videoBaseUrl;
    if (videoApiKey != null) p.videoApiKey = videoApiKey;
    if (videoModel != null) p.videoModel = videoModel;
    if (videoGenerationMode != null) {
      p.videoGenerationMode = videoGenerationMode;
    }
    if (comfyuiBaseUrl != null) {
      p.comfyuiBaseUrl = _normalizeBaseUrl(comfyuiBaseUrl);
    }
    if (arkBaseUrl != null) p.arkBaseUrl = _normalizeBaseUrl(arkBaseUrl);
    if (arkApiKey != null) p.arkApiKey = arkApiKey;
    if (arkImageModel != null) p.arkImageModel = arkImageModel;
    if (arkVideoModel != null) p.arkVideoModel = arkVideoModel;
    if (proxy != null) p.httpsProxy = proxy;
    if (seedanceUrl != null) p.seedanceUrl = seedanceUrl;
    if (seedanceEmail != null) p.seedanceEmail = seedanceEmail;
    if (seedancePassword != null) p.seedancePassword = seedancePassword;

    _applyProfile(p);
    await _persist(prefs);
  }

  static bool get isConfigured {
    if (llmApiKey.isEmpty) return false;
    final imageOk = useArkForImage
        ? arkApiKey.isNotEmpty
        : (useComfyuiForImage
            ? comfyuiBaseUrl.isNotEmpty
            : imageApiKey.isNotEmpty);
    if (!imageOk) return false;
    if (useArkForVideo) return arkApiKey.isNotEmpty;
    if (useComfyuiForVideo) return comfyuiBaseUrl.isNotEmpty;
    if (useSeedanceForVideo) return true;
    return videoApiKey.isNotEmpty;
  }

  static String _normalizeBaseUrl(String value) {
    return value.trim().replaceAll(RegExp(r'/+$'), '');
  }
}
