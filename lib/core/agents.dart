import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'agent.dart';
import '../services/llm_service.dart';
import '../models/models.dart';

const _briefSystemPrompt = '''你是专业的影视策划人。根据用户的创意描述，生成一个短剧项目的 Brief。

要求输出严格的 JSON 格式，不要任何多余的文字：
{
  "genre": "类型（romance/thriller/sci-fi/daily/comedy）",
  "duration": 目标时长（秒，30-120之间）,
  "aspect_ratio": "画面比例（9:16 或 16:9）",
  "mood": "情绪基调",
  "visual_style": "视觉风格描述（英文，用于图像/视频生成）",
  "story_outline": "故事大纲（200字以内，中文）"
}

默认：竖屏 9:16，时长 60-90 秒，面向手机短视频。''';

const _scriptSystemPrompt = '''你是专业影视编剧。根据创意编写短剧剧本，必须输出严格 JSON 格式，不要任何多余文字。

JSON 结构必须完全匹配：
{
  "scenes": [
    {
      "scene_num": 1,
      "location": "场景英文名",
      "description": "场景描述（中文）",
      "action": "角色动作（中文）",
      "dialogue": ["台词1", "台词2"],
      "duration": 15
    }
  ],
  "assets": [
    {"type": "character", "name": "角色英文名", "description": "Detailed English visual description for AI image generation"},
    {"type": "location", "name": "场景英文名", "description": "Detailed English visual description for AI image generation"}
  ]
}

要求：
- 2-5 个场景，总时长匹配目标时长
- 每个场景必须有 scene_num, location, description, action, dialogue, duration
- 提取所有角色(character)和场景(location)作为 assets
- 所有 description 必须用英文，详细用于 AI 图像生成
- dialogue 可以是空数组''';

const _storyboardSystemPrompt = '''你是专业分镜师。根据剧本制作分镜脚本，必须输出严格 JSON 格式，不要任何多余文字。

JSON 结构必须完全匹配：
{
  "storyboards": [
    {
      "scene_num": 1,
      "shot_num": 1,
      "shot_type": "close-up",
      "camera_move": "static",
      "description": "分镜画面描述（中文）",
      "first_frame_prompt": "首帧图生成提示词（中文，详细描述画面内容、光影、色调、构图）",
      "video_prompt": "视频生成提示词（中文，描述运镜方式、角色动作、环境变化）",
      "duration": 8
    }
  ]
}

要求：
- 每个场景拆成 1-3 个镜头
- shot_type 用: close-up/medium/wide/extreme-close-up
- camera_move 用: static/pan/zoom/tilt/dolly
- first_frame_prompt 和 video_prompt 必须用中文，详细描述用于 wan2.7 模型
- first_frame_prompt 侧重画面内容：光影、色调、构图、角色位置
- video_prompt 侧重动态：运镜、角色动作、环境变化
- 总时长与剧本一致''';

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

    final messages = [
      ChatMessage(role: 'system', content: _briefSystemPrompt),
      ChatMessage(role: 'user', content: '请为以下创意生成 Brief：$prompt'),
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
      );

      final brief = jsonDecode(response.content) as Map<String, dynamic>;
      if (!brief.containsKey('genre') ||
          !brief.containsKey('duration') ||
          !brief.containsKey('story_outline')) {
        return AgentResult.error('LLM returned invalid brief format');
      }

      return AgentResult.success({
        'genre': brief['genre'],
        'duration': (brief['duration'] as num).toInt().clamp(30, 120),
        'aspect_ratio': brief['aspect_ratio'] ?? '9:16',
        'mood': brief['mood'] ?? 'neutral',
        'visual_style': brief['visual_style'] ?? '',
        'story_outline': brief['story_outline'],
      });
    } catch (e) {
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

    final briefText = brief != null
        ? 'Brief: genre=${brief['genre']}, mood=${brief['mood']}, story=${brief['story_outline']}, style=${brief['visual_style']}'
        : '';
    final feedbackText =
        feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';

    final messages = [
      ChatMessage(role: 'system', content: _scriptSystemPrompt),
      ChatMessage(
        role: 'user',
        content: '根据以下创意编写剧本：$prompt${briefText.isNotEmpty ? '\n$briefText' : ''}$feedbackText',
      ),
    ];

    try {
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: 0.8,
      );

      final result = jsonDecode(response.content) as Map<String, dynamic>;
      if (result['scenes'] == null || result['scenes'] is! List) {
        return AgentResult.error('Invalid script format from LLM');
      }

      final scenes = (result['scenes'] as List)
          .map((s) => Scene.fromMap(s as Map<String, dynamic>))
          .toList();
      final assets = result['assets'] as List? ?? [];
      final assetList = assets
          .map((a) => Asset(
                id: 'asset_${a['name']?.replaceAll(' ', '_').toLowerCase() ?? ''}',
                projectId: context.projectId,
                type: a['type'] as String? ?? 'character',
                name: a['name'] as String? ?? '',
                description: a['description'] as String? ?? '',
                prompt: a['description'] as String? ?? '',
                createdAt: DateTime.now().millisecondsSinceEpoch,
              ))
          .toList();

      return AgentResult.success({
        'scenes': scenes,
        'assets': assetList,
        'raw': result,
      });
    } catch (e) {
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

    final scriptText = script != null
        ? 'Script: ${jsonEncode(script)}'
        : '';
    final briefText = brief != null
        ? 'Brief: mood=${brief['mood']}, visual_style=${brief['visual_style']}'
        : '';
    final feedbackText =
        feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';

    final messages = [
      ChatMessage(role: 'system', content: _storyboardSystemPrompt),
      ChatMessage(
        role: 'user',
        content:
            '根据以下剧本和策划生成分镜：\n$scriptText$briefText$feedbackText',
      ),
    ];

    try {
      final response = await llm.chatCompletion(
        messages: messages,
        jsonMode: true,
        temperature: 0.7,
      );

      final result = jsonDecode(response.content) as Map<String, dynamic>;
      if (result['storyboards'] == null || result['storyboards'] is! List) {
        return AgentResult.error('Invalid storyboard format from LLM');
      }

      final storyboards =
          (result['storyboards'] as List).map((sb) {
        final m = sb as Map<String, dynamic>;
        return Storyboard(
          id: 'shot_${const Uuid().v4().substring(0, 8)}',
          projectId: context.projectId,
          sceneNum: m['scene_num'] as int? ?? 0,
          shotNum: m['shot_num'] as int? ?? 0,
          shotType: m['shot_type'] as String? ?? 'medium',
          cameraMove: m['camera_move'] as String? ?? 'static',
          description: m['description'] as String? ?? '',
          firstFramePrompt: m['first_frame_prompt'] as String? ?? '',
          videoPrompt: m['video_prompt'] as String? ?? '',
          duration: m['duration'] as int? ?? 5,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
      }).toList();

      return AgentResult.success({'storyboards': storyboards});
    } catch (e) {
      return AgentResult.error('Storyboard generation failed: $e');
    }
  }
}
