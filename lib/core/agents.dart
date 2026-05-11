import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'agent.dart';
import '../services/llm_service.dart';
import '../services/dashscope_service.dart';
import '../models/models.dart';
import '../services/app_logger.dart';
import '../services/persistent_image_store.dart';

const _briefSystemPrompt = '''你是专业的影视策划人。根据用户的创意描述，生成一个短剧项目的 Brief。

要求输出严格的 JSON 格式，不要任何多余的文字：
{
  "genre": "类型（romance/thriller/sci-fi/daily/comedy）",
  "duration": 目标时长（秒，30-120之间）,
  "aspect_ratio": "画面比例（9:16 或 16:9）",
  "mood": "情绪基调",
  "visual_style": "视觉风格描述（中文）",
  "story_outline": "故事大纲（200字以内，中文）"
}

默认：竖屏 9:16，时长 60-90 秒，面向手机短视频。''';

const _scriptSystemPrompt = '''你是专业影视编剧。根据创意编写短剧剧本，必须输出严格 JSON 格式，不要任何多余文字。

JSON 结构必须完全匹配：
{
  "scenes": [
    {
      "scene_num": 1,
      "location": "场景名称",
      "description": "场景描述（中文）",
      "action": "角色动作（中文）",
      "dialogue": ["台词1", "台词2"],
      "duration": 15
    }
  ],
  "assets": [
    {"type": "character", "name": "角色名称", "description": "角色视觉描述（中文，详细描述外貌、服装、发型等用于AI图像生成）"},
    {"type": "location", "name": "场景名称", "description": "场景视觉描述（中文，详细描述环境、光线、色调等用于AI图像生成）"},
    {"type": "prop", "name": "道具名称", "description": "道具视觉描述（中文，详细描述外观、材质、颜色等用于AI图像生成）"}
  ]
}

要求：
- 2-5 个场景，总时长匹配目标时长
- 每个场景必须有 scene_num, location, description, action, dialogue, duration
- 提取所有角色(character)、场景(location)和关键道具(prop)作为 assets
- 关键道具指对剧情有重要作用或多次出现的物品
- 所有 description 必须用中文，详细描述用于 AI 图像生成
- dialogue 可以是空数组

【资产描述的最高优先级规则 — 必须严格遵守】

1. **角色(character)描述要求**：
   - 必须明确角色的具体类型和身份（人物/动物/物体/拟人化角色等）
   - 必须描述核心外观特征（形状、颜色、尺寸、材质等）
   - 必须描述关键视觉细节（用于区分该角色与其他类似事物）
   - 示例格式："一个拟人化的包子角色，白色面团身体，带有笑脸表情，戴着红色厨师帽"
   - 禁止使用模糊描述如"一个东西"、"某个角色"
   - 描述必须与创意描述中的角色设定一致

2. **场景(location)描述要求**：
   - 必须明确场景类型（室内/室外/虚构空间等）
   - 必须描述主要建筑物或环境特征
   - 必须描述光线和色调
   - 示例格式："室外场景，中学校门口，现代建筑风格的校门，早晨阳光，暖色调"

3. **道具(prop)描述要求**：
   - 必须明确物品的具体类型
   - 必须描述外观、材质、颜色
   - 示例格式："一辆老式自行车，金属框架，黑色车架，橡胶轮胎"
''';

const _storyboardSystemPrompt =
    '''你是专业分镜师。根据提供的剧本文本制作分镜脚本，必须输出严格 JSON 格式，不要任何多余文字。

【最高优先级规则 — 违反任何一条将导致输出被拒绝】

1. **场景数量严格一致**：剧本有几个场景（scenes 数组的长度），分镜就有几组镜头。绝对不得增加或减少场景组。
2. **场景编号严格对应**：剧本场景的 scene_num 是 1, 2, 3...，分镜的 scene_num 必须是完全相同的 1, 2, 3...，一一对应，不得跳过或重排。
3. **角色绝对忠于剧本**：
   - 剧本中出现的角色名字是什么，分镜描述中就必须用同样的名字或指代。
   - 剧本中是男生就是男生，是女生就是女生，不得改变性别。
   - 不得凭空添加剧本中没有的角色。
4. **剧情绝对忠于剧本**：
   - 剧本里发生了什么动作和事件，分镜就描述什么。
   - 不得自行添加新的事件、新的相遇、新的冲突、新的情感线。
   - 不得把校园场景改成街道、把同学关系改成陌生人偶遇、把男生改成女生。
5. **道具忠于剧本设定**：剧本中出现的关键道具，分镜画面中应保持外观一致，不得替换或忽略。
6. **场景地点忠于剧本**：剧本写的场景地点是什么，分镜画面中就必须是这个地点，不得替换。
6. 每个场景 2-3 个镜头，每个镜头的 duration 之和应接近对应场景的 duration。

JSON 结构必须完全匹配：
{
  "storyboards": [
    {
      "scene_num": 1,
      "shot_num": 1,
      "shot_type": "close-up",
      "camera_move": "static",
      "description": "分镜画面描述（中文，忠实反映剧本该场景的动作和画面）",
      "first_frame_prompt": "首帧图生成提示词（中文，必须按以下五个维度组织：[主体描述]角色/人物的外貌、服装、姿态、表情；[细节描述]画面中的关键道具、纹理、材质等细节；[背景描述]场景环境、空间层次、远景中景近景；[光影描述]光源方向、明暗对比、色调氛围；[情绪描述]画面传递的情感张力、情绪基调）",
      "video_prompt": "视频生成提示词（中文，描述运镜方式、角色动作、环境变化）",
      "duration": 8
    }
  ]
}

要求：
- shot_type 用: close-up/medium/wide/extreme-close-up
- camera_move 用: static/pan/zoom/tilt/dolly
- first_frame_prompt 必须按五个维度组织：[主体描述]角色外貌、服装、姿态、表情；[细节描述]道具、纹理、材质等细节；[背景描述]场景环境、空间层次；[光影描述]光源方向、明暗对比、色调氛围；[情绪描述]画面传递的情感张力和情绪基调。每个维度都要有实质性内容，不得省略任何维度。
- video_prompt 侧重动态：运镜、角色动作、环境变化''';

class PlanningAgent extends Agent {
  @override
  String get name => 'PlanningAgent';

  final LlmService llm;
  PlanningAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final prompt = context.data['prompt'] as String?;
    if (prompt == null || prompt.isEmpty) {
      return AgentResult.error('No prompt provided for planning');
    }
    final feedback = context.data['feedback'] as String?;
    final feedbackText = feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';
    final directorGuidance = context.data['director_guidance'] as String?;
    final guidanceText = directorGuidance != null &&
            directorGuidance.trim().isNotEmpty
        ? '\n\nDirectorAgent 已向用户逐步确认的创作约束如下，必须优先遵守，不要自行覆盖：\n$directorGuidance'
        : '';
    final memoryText = _creativeMemoryInstruction(context);

    final messages = [
      ChatMessage(role: 'system', content: _briefSystemPrompt),
      ChatMessage(
          role: 'user',
          content:
              '请为以下创意生成 Brief：$prompt$guidanceText$memoryText$feedbackText'),
    ];

    if (context.data['template'] != null) {
      messages.add(
        ChatMessage(
          role: 'user',
          content: '参考模板：${jsonEncode(context.data['template'])}',
        ),
      );
    }

    try {
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: 0.8,
        requestTag: 'planning.generate',
      );

      final decoded = jsonDecode(response.content);

      // Handle both {..} and [{..}] responses from LLM
      Map<String, dynamic>? brief;
      if (decoded is Map<String, dynamic>) {
        brief = decoded;
      } else if (decoded is List && decoded.isNotEmpty) {
        final first = decoded[0];
        if (first is Map<String, dynamic>) {
          brief = first;
        } else if (first is Map) {
          brief = Map<String, dynamic>.from(first);
        }
      } else if (decoded is Map) {
        brief = Map<String, dynamic>.from(decoded);
      }

      if (brief == null) {
        return AgentResult.error('LLM returned invalid brief format');
      }

      // Robust field extraction — tolerate string numbers, nulls, etc.
      var genre = brief['genre']?.toString().trim();
      if (genre == null || genre.isEmpty) genre = 'daily';

      final rawDuration = brief['duration'];
      int duration;
      if (rawDuration is num) {
        duration = rawDuration.toInt();
      } else if (rawDuration is String) {
        duration = int.tryParse(rawDuration) ?? 60;
      } else {
        duration = 60;
      }
      duration = duration.clamp(30, 120);

      final storyOutline = brief['story_outline']?.toString();
      if (storyOutline == null || storyOutline.isEmpty) {
        return AgentResult.error(
            'LLM returned invalid brief format (missing story_outline)');
      }

      return AgentResult.success({
        'genre': genre,
        'duration': (duration as num).toInt().clamp(30, 120),
        'aspect_ratio': brief['aspect_ratio'] ?? '9:16',
        'mood': brief['mood'] ?? 'neutral',
        'visual_style': brief['visual_style'] ?? '',
        'story_outline': storyOutline,
      });
    } catch (e, st) {
      await AppLogger.error(
        'Planning agent failed',
        data: {
          'projectId': context.projectId,
        },
        error: e,
        stackTrace: st,
      );
      return AgentResult.error('Planning failed: $e');
    }
  }
}

class ScriptAgent extends Agent {
  @override
  String get name => 'ScriptAgent';

  final LlmService llm;
  ScriptAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final prompt = context.data['prompt'] as String? ?? '';
    final brief = context.data['brief'] as Map<String, dynamic>?;
    final feedback = context.data['feedback'] as String?;
    final memoryText = _creativeMemoryInstruction(context);

    final briefText = brief != null
        ? 'Brief: genre=${brief['genre']}, mood=${brief['mood']}, story=${brief['story_outline']}, style=${brief['visual_style']}'
        : '';
    final feedbackText = feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';

    final messages = [
      ChatMessage(role: 'system', content: _scriptSystemPrompt),
      ChatMessage(
        role: 'user',
        content:
            '根据以下创意编写剧本：$prompt${briefText.isNotEmpty ? '\n$briefText' : ''}$memoryText$feedbackText',
      ),
    ];

    String? responseContent;

    try {
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: 0.8,
        requestTag: 'script.generate',
      );
      responseContent = response.content;

      final decoded = jsonDecode(response.content);
      final result = _asStringDynamicMap(decoded);
      if (result == null) {
        return AgentResult.error(
          'Invalid script root format from LLM: ${decoded.runtimeType}',
        );
      }

      final rawScenes = result['scenes'];
      if (rawScenes is! List) {
        return AgentResult.error('Invalid script format from LLM');
      }

      final scenes = <Scene>[];
      for (var index = 0; index < rawScenes.length; index++) {
        final sceneMap = _asStringDynamicMap(rawScenes[index]);
        if (sceneMap == null) {
          await AppLogger.warn(
            'Script scene item has invalid type',
            data: {
              'projectId': context.projectId,
              'index': index,
              'runtimeType': rawScenes[index].runtimeType.toString(),
              'valuePreview': AppLogger.preview(rawScenes[index].toString()),
            },
          );
          return AgentResult.error(
            'Invalid script scene[$index] format: ${rawScenes[index].runtimeType}',
          );
        }
        scenes.add(Scene.fromMap(sceneMap));
      }

      final rawAssets = result['assets'];
      if (rawAssets != null && rawAssets is! List) {
        return AgentResult.error(
          'Invalid script assets format: ${rawAssets.runtimeType}',
        );
      }

      final assetList = <Asset>[];
      final assetItems = rawAssets as List? ?? const [];
      for (var index = 0; index < assetItems.length; index++) {
        final assetMap = _asStringDynamicMap(assetItems[index]);
        if (assetMap == null) {
          await AppLogger.warn(
            'Script asset item has invalid type',
            data: {
              'projectId': context.projectId,
              'index': index,
              'runtimeType': assetItems[index].runtimeType.toString(),
              'valuePreview': AppLogger.preview(assetItems[index].toString()),
            },
          );
          return AgentResult.error(
            'Invalid script asset[$index] format: ${assetItems[index].runtimeType}',
          );
        }

        final assetName = assetMap['name']?.toString() ?? '';
        final assetDescription = assetMap['description']?.toString() ?? '';
        assetList.add(
          Asset(
            id: 'asset_${assetName.replaceAll(' ', '_').toLowerCase()}',
            projectId: context.projectId,
            type: assetMap['type']?.toString() ?? 'character',
            name: assetName,
            description: assetDescription,
            prompt: assetDescription,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      await AppLogger.info(
        'Script agent parsed response',
        data: {
          'projectId': context.projectId,
          'sceneCount': scenes.length,
          'assetCount': assetList.length,
        },
      );

      return AgentResult.success({
        'scenes': scenes,
        'assets': assetList,
        'raw': result,
      });
    } catch (e, st) {
      await AppLogger.error(
        'Script agent failed',
        data: {
          'projectId': context.projectId,
          'responsePreview': responseContent == null
              ? 'n/a'
              : AppLogger.preview(responseContent, maxLength: 800),
        },
        error: e,
        stackTrace: st,
      );
      return AgentResult.error('Script generation failed: $e');
    }
  }
}

class ProductionAgent extends Agent {
  @override
  String get name => 'ProductionAgent';

  final LlmService llm;
  ProductionAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    final script = context.data['script'] as Map<String, dynamic>?;
    final brief = context.data['brief'] as Map<String, dynamic>?;
    final feedback = context.data['feedback'] as String?;
    final memoryText = _creativeMemoryInstruction(context);

    final scriptText = script != null ? _formatScriptForStoryboard(script) : '';
    final briefText = brief != null
        ? '\n策划参考：mood=${brief['mood']}, visual_style=${brief['visual_style']}'
        : '';
    final feedbackText = feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';

    final messages = [
      ChatMessage(role: 'system', content: _storyboardSystemPrompt),
      ChatMessage(
        role: 'user',
        content:
            '请根据以下剧本制作分镜。注意：必须严格按照剧本的场景、角色、剧情来制作分镜，不得自行创作新内容。\n\n$scriptText$briefText$memoryText$feedbackText',
      ),
    ];

    try {
      final temperature =
          (context.data['storyboardTemperature'] as num?)?.toDouble() ?? 0.3;
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: temperature,
        requestTag: 'storyboard.generate',
      );

      final decoded = jsonDecode(response.content);
      Map<String, dynamic>? result;
      if (decoded is Map<String, dynamic>) {
        result = decoded;
      } else if (decoded is Map) {
        result = Map<String, dynamic>.from(decoded);
      }
      if (result == null ||
          result['storyboards'] == null ||
          result['storyboards'] is! List) {
        return AgentResult.error('Invalid storyboard format from LLM');
      }

      final storyboards = <Storyboard>[];
      for (final sbItem in result['storyboards'] as List) {
        final m = _asStringDynamicMap(sbItem);
        if (m == null) {
          await AppLogger.warn('Storyboard item has invalid type',
              data: {'projectId': context.projectId});
          continue;
        }
        storyboards.add(Storyboard(
          id: 'shot_${const Uuid().v4().substring(0, 8)}',
          projectId: context.projectId,
          sceneNum: (m['scene_num'] as num?)?.toInt() ?? 0,
          shotNum: (m['shot_num'] as num?)?.toInt() ?? 0,
          shotType: m['shot_type'] as String? ?? 'medium',
          cameraMove: m['camera_move'] as String? ?? 'static',
          description: m['description'] as String? ?? '',
          firstFramePrompt: m['first_frame_prompt'] as String? ?? '',
          videoPrompt: m['video_prompt'] as String? ?? '',
          duration: _readInt(m['duration'], fallback: 5),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }

      return AgentResult.success({'storyboards': storyboards});
    } catch (e, st) {
      await AppLogger.error(
        'Production agent failed',
        data: {
          'projectId': context.projectId,
        },
        error: e,
        stackTrace: st,
      );
      return AgentResult.error('Storyboard generation failed: $e');
    }
  }
}

Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
  if (value is Asset) {
    return value.toMap();
  }

  if (value is Storyboard) {
    return value.toMap();
  }

  if (value is Scene) {
    return value.toMap();
  }

  if (value is Map<String, dynamic>) {
    return value;
  }

  if (value is Map) {
    try {
      return Map<String, dynamic>.from(value);
    } catch (_) {
      return null;
    }
  }

  return null;
}

int _readInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _creativeMemoryInstruction(AgentContext context) {
  final memory = context.data['creative_memory'] as String?;
  if (memory == null || memory.trim().isEmpty) return '';
  return '''

【项目 Wiki 记忆】
以下内容是本项目持续维护的创作事实源。必须优先遵守用户确认的约束、人物关系、视觉锚点和已生成阶段事实；如与当前任务输入冲突，以用户确认约束和最新 wiki 为准，不要自行改写。

${memory.trim()}
''';
}

/// Format script as a readable scene-by-scene list for the storyboard LLM.
/// This makes it much clearer than raw JSON what scenes, characters, and
/// actions the storyboard must faithfully follow.
String _formatScriptForStoryboard(Map<String, dynamic> script) {
  final buffer = StringBuffer();
  buffer.writeln('=== 剧本 ===\n');

  // Extract and list assets (characters, locations, and props)
  final rawAssets = script['assets'];
  if (rawAssets is List && rawAssets.isNotEmpty) {
    final characters = <Map<String, dynamic>>[];
    final locations = <Map<String, dynamic>>[];
    final props = <Map<String, dynamic>>[];
    for (final a in rawAssets) {
      Map<String, dynamic>? m;
      if (a is Asset) {
        m = {'type': a.type, 'name': a.name, 'description': a.description};
      } else {
        m = _asStringDynamicMap(a);
      }
      if (m == null) continue;
      if (m['type'] == 'character') characters.add(m);
      if (m['type'] == 'location') locations.add(m);
      if (m['type'] == 'prop') props.add(m);
    }

    if (characters.isNotEmpty) {
      buffer.writeln('【角色列表】（分镜中只能出现这些角色，不得添加新角色）');
      for (final c in characters) {
        buffer.writeln('- 名字：${c['name']}，描述：${c['description']}');
      }
      buffer.writeln('');
    }
    if (locations.isNotEmpty) {
      buffer.writeln('【场景地点】（分镜画面必须基于这些地点，不得替换）');
      for (final l in locations) {
        buffer.writeln('- 地点：${l['name']}，描述：${l['description']}');
      }
      buffer.writeln('');
    }
    if (props.isNotEmpty) {
      buffer.writeln('【关键道具】（分镜中如涉及道具必须与以下描述一致）');
      for (final p in props) {
        buffer.writeln('- 名称：${p['name']}，描述：${p['description']}');
      }
      buffer.writeln('');
    }
  }

  // List each scene explicitly
  final rawScenes = script['scenes'];
  if (rawScenes is List && rawScenes.isNotEmpty) {
    buffer.writeln('【场景清单】（分镜必须严格按以下场景逐个制作，不得增删、改写）');
    buffer.writeln('共 ${rawScenes.length} 个场景：\n');
    for (var i = 0; i < rawScenes.length; i++) {
      final item = rawScenes[i];
      String sceneNum, location, description, action;
      List<dynamic>? dialogue;

      if (item is Scene) {
        sceneNum = item.sceneNum.toString();
        location = item.location;
        description = item.description;
        action = item.action;
        dialogue = item.dialogue;
      } else {
        final m = _asStringDynamicMap(item);
        if (m == null) continue;
        sceneNum = (m['scene_num'] ?? 0).toString();
        location = m['location'] ?? '';
        description = m['description'] ?? '';
        action = m['action'] ?? '';
        dialogue = m['dialogue'] as List?;
      }

      buffer.writeln('场景 $sceneNum：');
      buffer.writeln('  地点：$location');
      buffer.writeln('  场景描述：$description');
      buffer.writeln('  角色动作：$action');
      if (dialogue != null && dialogue.isNotEmpty) {
        buffer.writeln('  台词：${dialogue.join('；')}');
      }
      buffer.writeln('');
    }
  }

  return buffer.toString();
}

/// Asset design agent - generates reference images for each character and
/// location asset. These canonical images serve as visual anchors throughout
/// the pipeline, ensuring character and scene consistency across all storyboards.
class AssetDesignAgent extends Agent {
  @override
  String get name => 'AssetDesignAgent';

  final DashscopeService _dashscope = DashscopeService();

  @override
  Future<AgentResult> run(AgentContext context) async {
    final scriptData = context.data['script'] as Map<String, dynamic>?;
    final rawAssets = scriptData?['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      return AgentResult.error('没有资产数据，无法设计参考图');
    }

    final assets = <Asset>[];
    for (final a in rawAssets) {
      if (a is Asset) {
        assets.add(a);
      } else if (a is Map<String, dynamic>) {
        assets.add(Asset.fromMap(a));
      }
    }

    if (assets.isEmpty) {
      return AgentResult.error('解析资产列表失败');
    }

    final feedback = context.data['feedback'] as String?;
    final feedbackText = feedback != null ? '。修改建议：$feedback' : '';
    final memoryText = _creativeMemoryInstruction(context);

    int successCount = 0;
    int failCount = 0;
    final updatedAssets = <Asset>[];
    final imageStore = PersistentImageStore();

    for (final asset in assets) {
      final prompt = asset.prompt ?? asset.description ?? '';
      if (prompt.isEmpty) {
        await AppLogger.warn(
          'Asset has no prompt/description, skipping image generation',
          data: {'assetId': asset.id, 'assetName': asset.name},
        );
        updatedAssets.add(asset);
        failCount++;
        continue;
      }

      // Enhance prompt with visual style context from brief
      final enhancedPrompt = _buildAssetPrompt(
        prompt,
        asset.type,
        scriptData,
        memoryText,
        feedbackText,
      );

      try {
        await AppLogger.info(
          'Generating reference image for asset',
          data: {
            'assetId': asset.id,
            'assetName': asset.name,
            'assetType': asset.type
          },
        );

        final imageUrl = await _dashscope.generateImage(enhancedPrompt);
        final localPath = await imageStore.persistRemoteImage(
          imageUrl,
          category: 'assets',
          entityId: asset.id,
        );

        updatedAssets.add(Asset(
          id: asset.id,
          projectId: asset.projectId,
          type: asset.type,
          name: asset.name,
          description: asset.description,
          prompt: asset.prompt,
          referenceImageUrl: imageUrl,
          referenceImageLocalPath: localPath,
          state: asset.state,
          createdAt: asset.createdAt,
        ));
        successCount++;
      } catch (e) {
        await AppLogger.warn(
          'Asset image generation failed',
          data: {'assetId': asset.id, 'assetName': asset.name},
          error: e,
        );
        updatedAssets.add(asset); // Keep original asset without image
        failCount++;
      }
    }

    await AppLogger.info(
      'Asset design completed',
      data: {
        'total': assets.length,
        'success': successCount,
        'failed': failCount,
      },
    );

    return AgentResult.success({
      'assets': updatedAssets,
      'total': assets.length,
      'success': successCount,
      'failed': failCount,
    });
  }

  /// Build enhanced image prompt for asset reference image generation.
  /// Injects visual style from the brief to ensure consistency with the
  /// overall project aesthetic.
  String _buildAssetPrompt(
    String basePrompt,
    String assetType,
    Map<String, dynamic>? scriptData,
    String memoryText,
    String feedbackText,
  ) {
    final buffer = StringBuffer();

    // Extract visual style from brief if available
    final brief = scriptData?['brief'] as Map<String, dynamic>?;
    if (brief != null) {
      final visualStyle = brief['visual_style']?.toString();
      if (visualStyle != null && visualStyle.isNotEmpty) {
        buffer.writeln('整体视觉风格：$visualStyle');
        buffer.writeln('');
      }
    }

    // Add type-specific framing with clear instructions
    if (assetType == 'character') {
      buffer.writeln('[角色设计参考图]');
      buffer.writeln('生成一张角色参考图，用于后续所有分镜和视频中该角色的外观一致性。');
      buffer.writeln('必须严格按照角色描述生成，不得自由发挥或替换为其他物体。');
      buffer.writeln('');
      buffer.writeln('角色描述：$basePrompt');
    } else if (assetType == 'location') {
      buffer.writeln('[场景设计参考图]');
      buffer.writeln('生成一张场景参考图，用于后续所有分镜和视频中该场景的环境一致性。');
      buffer.writeln('必须严格按照场景描述生成，不得自由发挥或替换为其他地点。');
      buffer.writeln('');
      buffer.writeln('场景描述：$basePrompt');
    } else if (assetType == 'prop') {
      buffer.writeln('[道具设计参考图]');
      buffer.writeln('生成一张道具参考图，用于后续所有分镜和视频中该道具的外观一致性。');
      buffer.writeln('必须严格按照道具描述生成，不得自由发挥或替换为其他物品。');
      buffer.writeln('');
      buffer.writeln('道具描述：$basePrompt');
    } else {
      buffer.writeln(basePrompt);
    }

    if (feedbackText.isNotEmpty) {
      buffer.write(feedbackText);
    }
    if (memoryText.isNotEmpty) {
      buffer.writeln();
      buffer.write(memoryText);
    }

    return buffer.toString();
  }
}

/// Video generation agent - generates reference images + videos for each storyboard
/// with character/scene consistency anchors and inter-shot continuity.
///
/// Key design:
/// 1. Extract character + scene descriptions from the script as "consistency anchors"
/// 2. Inject these anchors into every shot's first_frame_prompt and video_prompt
/// 3. Always generate reference images with enhanced prompts for visual consistency
/// 4. Use adjacent-frame passing for temporal continuity within each scene
class VideoAgent extends Agent {
  @override
  String get name => 'VideoAgent';

  final DashscopeService _dashscope = DashscopeService();

  @override
  Future<AgentResult> run(AgentContext context) async {
    final storyboards = context.data['storyboards'] as List?;
    if (storyboards == null || storyboards.isEmpty) {
      return AgentResult.error('没有分镜数据，无法生成视频');
    }

    // ============================================================
    // Step 1: Extract consistency anchors from the script
    // ============================================================
    final consistencyAnchors = _extractConsistencyAnchors(context);

    // Sort by scene_num then shot_num for correct sequential order
    final sorted = <Map<String, dynamic>>[];
    for (final item in storyboards) {
      final m = _asStringDynamicMap(item);
      if (m != null) sorted.add(m);
    }
    sorted.sort((a, b) {
      final sceneA = (a['scene_num'] as num?)?.toInt() ?? 0;
      final sceneB = (b['scene_num'] as num?)?.toInt() ?? 0;
      if (sceneA != sceneB) return sceneA - sceneB;
      final shotA = (a['shot_num'] as num?)?.toInt() ?? 0;
      final shotB = (b['shot_num'] as num?)?.toInt() ?? 0;
      return shotA - shotB;
    });

    final feedback = context.data['feedback'] as String?;
    final feedbackText = feedback != null ? '。修改建议：$feedback' : '';
    final memoryText = _creativeMemoryInstruction(context);

    // ============================================================
    // Step 2: Generate videos with consistency anchors + continuity
    // ============================================================
    final clips = <Map<String, dynamic>>[];
    int successCount = 0;
    int failCount = 0;

    // Continuity: track the reference image from the previous shot
    String? continuityRefImage;
    int? lastSceneNum;

    for (int i = 0; i < sorted.length; i++) {
      final sbMap = sorted[i];

      final storyboardId = sbMap['id'] as String?;
      final videoPrompt = sbMap['video_prompt'] as String? ?? '';
      final firstFramePrompt = sbMap['first_frame_prompt'] as String? ?? '';
      final duration = (sbMap['duration'] as num?)?.toInt() ?? 5;
      final sceneNum = (sbMap['scene_num'] as num?)?.toInt() ?? 0;
      final shotDescription = sbMap['description'] as String? ?? '';
      final isNewScene = lastSceneNum == null || sceneNum != lastSceneNum;

      // Detect scene change — reset continuity chain for new scenes
      if (isNewScene) {
        continuityRefImage = null;
      }

      // Build enhanced image prompt (always used for reference image generation)
      final enhancedImagePrompt = _enhanceImagePrompt(
            consistencyAnchors,
            sceneNum,
            firstFramePrompt,
            shotDescription,
          ) +
          memoryText;

      // Build enhanced video prompt (injects visual context for video generation)
      final enhancedVideoPrompt = _enhanceVideoPrompt(
            consistencyAnchors,
            sceneNum,
            videoPrompt,
            shotDescription,
          ) +
          memoryText +
          feedbackText;

      // ============================================================
      // Generate reference image with consistency anchors
      // Always regenerate to ensure consistency (skip only if already
      // has a URL, to save API calls for resume scenarios)
      // ============================================================
      // Generate reference image with consistency anchors and canonical images
      String? refImageUrl = sbMap['reference_image_url'] as String?;
      String? refImageLocalPath =
          sbMap['reference_image_local_path'] as String?;
      if ((refImageUrl == null || refImageUrl.isEmpty) &&
          enhancedImagePrompt.isNotEmpty) {
        final refUrls = _getReferenceImageUrls(consistencyAnchors, sceneNum);
        await AppLogger.info(
          'Generating reference image with canonical reference images',
          data: {
            'storyboard_id': storyboardId,
            'scene': sceneNum,
            'shot': '${i + 1}/${sorted.length}',
            'refImageCount': refUrls.length
          },
        );
        refImageUrl = await _dashscope.generateImage(
          enhancedImagePrompt,
          referenceImageUrls: refUrls.isNotEmpty ? refUrls : null,
        );
      }

      if (refImageLocalPath == null &&
          refImageUrl != null &&
          refImageUrl.isNotEmpty) {
        refImageLocalPath = await PersistentImageStore().persistRemoteImage(
          refImageUrl,
          category: 'storyboards',
          entityId: storyboardId ?? 'storyboard_${i + 1}',
        );
      }

      // ============================================================
      // Choose first frame for video generation
      // - New scene first shot: use own reference image
      // - Same scene subsequent shot: use previous shot's reference
      //   (adjacent-frame passing for temporal continuity)
      // ============================================================
      final videoFirstFrame =
          isNewScene ? refImageUrl : (continuityRefImage ?? refImageUrl);

      // ============================================================
      // Generate video
      // ============================================================
      try {
        if (videoFirstFrame == null || videoFirstFrame.isEmpty) {
          clips.add({
            'storyboard_id': storyboardId,
            'state': 'failed',
            'error_reason': '缺少参考图片，无法生成视频',
          });
          failCount++;
        } else {
          final videoRefUrls =
              _getReferenceImageUrls(consistencyAnchors, sceneNum);
          final videoUrl = await _dashscope.generateVideo(
            prompt: enhancedVideoPrompt,
            firstFrameUrl: videoFirstFrame,
            duration: duration,
            referenceImageUrls: videoRefUrls.isNotEmpty ? videoRefUrls : null,
          );

          clips.add({
            'storyboard_id': storyboardId,
            'reference_image_url': refImageUrl,
            'reference_image_local_path': refImageLocalPath,
            'continuity_ref_image_url': isNewScene ? null : continuityRefImage,
            'video_url': videoUrl,
            'state': 'completed',
          });
          successCount++;
        }

        // Update continuity anchor for next shot in same scene
        continuityRefImage = refImageUrl;
      } catch (e) {
        await AppLogger.warn(
          'Video clip generation failed',
          data: {'storyboard_id': storyboardId},
          error: e,
        );
        clips.add({
          'storyboard_id': storyboardId,
          'state': 'failed',
          'error_reason': e.toString(),
        });
        failCount++;
      }

      lastSceneNum = sceneNum;
    }

    await AppLogger.info(
      'Video generation completed',
      data: {
        'total': sorted.length,
        'success': successCount,
        'failed': failCount,
      },
    );

    return AgentResult.success({
      'clips': clips,
      'total': sorted.length,
      'success': successCount,
      'failed': failCount,
    });
  }

  // ============================================================
  // Consistency anchor extraction and injection
  // ============================================================

  /// Extracts character and scene consistency anchors from the script assets.
  /// Includes both text descriptions (for prompt enhancement) and canonical
  /// image URLs (from the asset design stage, if available).
  Map<String, dynamic> _extractConsistencyAnchors(AgentContext context) {
    final scriptData = context.data['script'];

    final characterDescs = <String>[];
    final characterImages = <String>[];
    final sceneLocations = <int, String>{};
    final sceneImages = <int, String>{};
    final propDescs = <String>[];
    final propImages = <String>[];

    if (scriptData != null) {
      Map<String, dynamic>? scriptMap;
      if (scriptData is Map<String, dynamic>) {
        scriptMap = scriptData;
      } else if (scriptData is Map) {
        scriptMap = Map<String, dynamic>.from(scriptData);
      }

      if (scriptMap != null) {
        // Extract character/location descriptions and canonical images from assets
        final rawAssets = scriptMap['assets'];
        if (rawAssets is List) {
          for (final a in rawAssets) {
            final m = _asStringDynamicMap(a);
            if (m == null) continue;
            final type = m['type']?.toString() ?? '';
            final name = m['name']?.toString() ?? '';
            final desc = m['description']?.toString() ?? '';
            final refImage = m['reference_image_url']?.toString();

            if (type == 'character' && desc.isNotEmpty) {
              characterDescs.add('$name: $desc');
              if (refImage != null && refImage.isNotEmpty) {
                characterImages.add('$name: $refImage');
              }
            }
            if (type == 'location' && desc.isNotEmpty) {
              final sceneNum = m['scene_num'];
              if (sceneNum is int) {
                sceneLocations[sceneNum] = desc;
                if (refImage != null && refImage.isNotEmpty) {
                  sceneImages[sceneNum] = refImage;
                }
              }
              if (refImage != null && refImage.isNotEmpty) {
                // Location assets are usually not tied to a scene number in the
                // DB, so include them as global visual references.
                propImages.add('$name: $refImage');
              }
            }
            if (type == 'prop' && desc.isNotEmpty) {
              propDescs.add('$name: $desc');
              if (refImage != null && refImage.isNotEmpty) {
                propImages.add('$name: $refImage');
              }
            }
          }
        }

        // Also map scene_num to location from scenes array
        final rawScenes = scriptMap['scenes'];
        if (rawScenes is List) {
          for (int i = 0; i < rawScenes.length; i++) {
            final s = rawScenes[i];
            Map<String, dynamic>? sm;
            if (s is Map<String, dynamic>) {
              sm = s;
            } else if (s is Map) {
              sm = Map<String, dynamic>.from(s);
            }
            if (sm != null) {
              final sceneNum = (sm['scene_num'] as num?)?.toInt() ?? (i + 1);
              final loc = sm['location']?.toString() ?? '';
              final desc = sm['description']?.toString() ?? '';
              if (!sceneLocations.containsKey(sceneNum) &&
                  (loc.isNotEmpty || desc.isNotEmpty)) {
                sceneLocations[sceneNum] = '$loc. $desc'.trim();
              }
            }
          }
        }
      }
    }

    return {
      'characterDescs': characterDescs.join('\n'),
      'characterImages': characterImages.join('\n'),
      'sceneLocations': sceneLocations,
      'sceneImages': sceneImages,
      'propDescs': propDescs.join('\n'),
      'propImages': propImages.join('\n'),
    };
  }

  /// Extract reference image URLs from anchors for a given scene.
  /// Returns a list of URLs to pass to generateImage as reference images.
  List<String> _getReferenceImageUrls(
    Map<String, dynamic> anchors,
    int sceneNum,
  ) {
    final urls = <String>[];

    // Add all character canonical images
    final charImages = anchors['characterImages'] as String?;
    if (charImages != null && charImages.isNotEmpty) {
      for (final line in charImages.split('\n')) {
        final idx = line.indexOf(':');
        if (idx > 0) {
          final url = line.substring(idx + 1).trim();
          if (url.isNotEmpty &&
              (url.startsWith('http://') || url.startsWith('https://'))) {
            urls.add(url);
          }
        }
      }
    }

    // Add scene canonical image for this scene number
    final sceneImages = anchors['sceneImages'] as Map<int, String>?;
    if (sceneImages != null && sceneImages.containsKey(sceneNum)) {
      final sceneUrl = sceneImages[sceneNum];
      if (sceneUrl != null && sceneUrl.isNotEmpty) {
        urls.add(sceneUrl);
      }
    }

    // Add prop canonical images
    final propImages = anchors['propImages'] as String?;
    if (propImages != null && propImages.isNotEmpty) {
      for (final line in propImages.split('\n')) {
        final idx = line.indexOf(':');
        if (idx > 0) {
          final url = line.substring(idx + 1).trim();
          if (url.isNotEmpty &&
              (url.startsWith('http://') || url.startsWith('https://'))) {
            urls.add(url);
          }
        }
      }
    }

    return urls;
  }

  /// Enhance the image generation prompt with consistency anchors.
  /// Prepends global character + scene descriptions so the AI image
  /// generator produces visually consistent reference images.
  String _enhanceImagePrompt(
    Map<String, dynamic> anchors,
    int sceneNum,
    String firstFramePrompt,
    String shotDescription,
  ) {
    if (firstFramePrompt.isEmpty) return '';

    final buffer = StringBuffer();

    // Global character consistency anchor
    final charDescs = anchors['characterDescs'] as String?;
    if (charDescs != null && charDescs.isNotEmpty) {
      buffer.writeln('[角色外观一致性参考]');
      buffer.writeln(charDescs);
      buffer.writeln('');
    }

    // Scene-specific location anchor
    final sceneLocations = anchors['sceneLocations'] as Map<int, String>?;
    if (sceneLocations != null && sceneLocations.containsKey(sceneNum)) {
      buffer.writeln('[场景环境参考]');
      buffer.writeln(sceneLocations[sceneNum]);
      buffer.writeln('');
    }

    // Prop anchor
    final propDescs = anchors['propDescs'] as String?;
    if (propDescs != null && propDescs.isNotEmpty) {
      buffer.writeln('[道具参考]');
      buffer.writeln(propDescs);
      buffer.writeln('');
    }

    // Shot-specific description
    if (shotDescription.isNotEmpty) {
      buffer.writeln('[当前镜头画面]');
      buffer.writeln(shotDescription);
      buffer.writeln('');
    }

    // Original detailed prompt
    buffer.writeln('[详细画面生成提示]');
    buffer.writeln(firstFramePrompt);

    return buffer.toString();
  }

  /// Enhance the video generation prompt with visual context from
  /// consistency anchors. The video model sees character/scene descriptions
  /// alongside the motion instructions for more coherent output.
  String _enhanceVideoPrompt(
    Map<String, dynamic> anchors,
    int sceneNum,
    String videoPrompt,
    String shotDescription,
  ) {
    if (videoPrompt.isEmpty) return shotDescription;

    final buffer = StringBuffer();

    // Character context for video
    final charDescs = anchors['characterDescs'] as String?;
    if (charDescs != null && charDescs.isNotEmpty) {
      buffer.writeln('角色外观参考：$charDescs');
    }

    // Scene context for video
    final sceneLocations = anchors['sceneLocations'] as Map<int, String>?;
    if (sceneLocations != null && sceneLocations.containsKey(sceneNum)) {
      buffer.writeln('场景环境参考：${sceneLocations[sceneNum]}');
    }

    // Prop context for video
    final propDescs = anchors['propDescs'] as String?;
    if (propDescs != null && propDescs.isNotEmpty) {
      buffer.writeln('道具参考：$propDescs');
    }

    // Shot description
    if (shotDescription.isNotEmpty) {
      buffer.writeln('镜头画面：$shotDescription');
    }

    // Original motion prompt
    buffer.writeln('动画要求：$videoPrompt');

    return buffer.toString();
  }
}
