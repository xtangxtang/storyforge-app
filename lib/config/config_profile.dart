/// A named, self-contained snapshot of all generation/network settings.
///
/// Profiles let the user keep several backends side by side (e.g. a cloud
/// DashScope setup and a self-hosted ComfyUI on a GPU box) and switch between
/// them without re-typing keys/URLs. The active profile is applied onto the
/// [AppConfig] static fields so the rest of the app keeps reading config the
/// same way it always has.
class ConfigProfile {
  final String id;
  String name;

  // LLM (planning / scripting). ComfyUI cannot do this, so even a ComfyUI
  // profile still points its LLM at a chat-completions endpoint.
  String llmBaseUrl;
  String llmApiKey;
  String llmModel;

  // Image generation
  String imageProvider; // 'dashscope' | 'comfyui'
  String imageBaseUrl;
  String imageApiKey;
  String imageModel;

  // Video generation
  String videoProvider; // 'dashscope' | 'comfyui'
  String
      videoGenerationMode; // 'api' | 'seedance' (only used when provider == dashscope)
  String videoBaseUrl;
  String videoApiKey;
  String videoModel;

  // Self-hosted ComfyUI
  String comfyuiBaseUrl;

  // Volcengine Ark (agent plan): Seedream 5.0 lite (image) + Seedance 2.0 (video).
  // Selected when image/videoProvider == 'ark'. Ark models follow ENGLISH prompts.
  String arkBaseUrl;
  String arkApiKey;
  String arkImageModel;
  String arkVideoModel;

  // Network
  String httpsProxy;

  // Seedance web automation
  String seedanceUrl;
  String seedanceEmail;
  String seedancePassword;

  ConfigProfile({
    required this.id,
    required this.name,
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.llmModel,
    required this.imageProvider,
    required this.imageBaseUrl,
    required this.imageApiKey,
    required this.imageModel,
    required this.videoProvider,
    required this.videoGenerationMode,
    required this.videoBaseUrl,
    required this.videoApiKey,
    required this.videoModel,
    required this.comfyuiBaseUrl,
    required this.arkBaseUrl,
    required this.arkApiKey,
    required this.arkImageModel,
    required this.arkVideoModel,
    required this.httpsProxy,
    required this.seedanceUrl,
    required this.seedanceEmail,
    required this.seedancePassword,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'llmBaseUrl': llmBaseUrl,
        'llmApiKey': llmApiKey,
        'llmModel': llmModel,
        'imageProvider': imageProvider,
        'imageBaseUrl': imageBaseUrl,
        'imageApiKey': imageApiKey,
        'imageModel': imageModel,
        'videoProvider': videoProvider,
        'videoGenerationMode': videoGenerationMode,
        'videoBaseUrl': videoBaseUrl,
        'videoApiKey': videoApiKey,
        'videoModel': videoModel,
        'comfyuiBaseUrl': comfyuiBaseUrl,
        'arkBaseUrl': arkBaseUrl,
        'arkApiKey': arkApiKey,
        'arkImageModel': arkImageModel,
        'arkVideoModel': arkVideoModel,
        'httpsProxy': httpsProxy,
        'seedanceUrl': seedanceUrl,
        'seedanceEmail': seedanceEmail,
        'seedancePassword': seedancePassword,
      };

  factory ConfigProfile.fromJson(Map<String, dynamic> j) {
    String s(String key, [String fallback = '']) =>
        (j[key] as String?) ?? fallback;
    return ConfigProfile(
      id: s('id', DateTime.now().microsecondsSinceEpoch.toString()),
      name: s('name', '未命名'),
      llmBaseUrl: s('llmBaseUrl'),
      llmApiKey: s('llmApiKey'),
      llmModel: s('llmModel'),
      imageProvider: s('imageProvider', 'dashscope'),
      imageBaseUrl: s('imageBaseUrl'),
      imageApiKey: s('imageApiKey'),
      imageModel: s('imageModel'),
      videoProvider: s('videoProvider', 'dashscope'),
      videoGenerationMode: s('videoGenerationMode', 'api'),
      videoBaseUrl: s('videoBaseUrl'),
      videoApiKey: s('videoApiKey'),
      videoModel: s('videoModel'),
      comfyuiBaseUrl: s('comfyuiBaseUrl'),
      arkBaseUrl: s('arkBaseUrl'),
      arkApiKey: s('arkApiKey'),
      arkImageModel: s('arkImageModel'),
      arkVideoModel: s('arkVideoModel'),
      httpsProxy: s('httpsProxy'),
      seedanceUrl: s('seedanceUrl'),
      seedanceEmail: s('seedanceEmail'),
      seedancePassword: s('seedancePassword'),
    );
  }

  ConfigProfile copyWith({String? id, String? name}) => ConfigProfile(
        id: id ?? this.id,
        name: name ?? this.name,
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
}
