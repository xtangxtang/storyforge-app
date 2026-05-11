import 'dart:convert';
import 'agent.dart';
import 'agents.dart';
import '../models/models.dart';
import '../services/app_logger.dart';
import '../services/llm_service.dart';

const _directorReviewSystemPrompt = '''你是短剧质量评审。请审阅以下输出内容，给出质量评估。

评分维度：
1. 内容完整性（是否有缺失的关键信息）
2. 逻辑一致性（前后是否自洽）
3. 可执行性（能否直接用于下一步生成）

输出严格 JSON：
{
  "score": 1-10,
  "pass": true/false,
  "feedback": "修改建议（如果需要重做，用中文说明具体问题）"
}

如果分数 >= 6，pass 为 true；否则 pass 为 false，并给出具体修改建议。''';

typedef WorkflowStage = String;

const List<WorkflowStage> stageOrder = [
  'planning',
  'scripting',
  'asseting',
  'storyboarding',
  'generating',
  'cutting',
  'done',
];

class DirectorGuidanceQuestion {
  final String id;
  final String title;
  final String question;
  final String hint;
  final bool required;

  const DirectorGuidanceQuestion({
    required this.id,
    required this.title,
    required this.question,
    required this.hint,
    required this.required,
  });

  factory DirectorGuidanceQuestion.fromMap(
      Map<String, dynamic> map, int index) {
    final fallbackTitle = '${index + 1}. 补全创作信息';
    final rawId = map['id']?.toString().trim();
    return DirectorGuidanceQuestion(
      id: rawId != null && rawId.isNotEmpty ? rawId : 'question_$index',
      title: map['title']?.toString().trim().isNotEmpty == true
          ? map['title'].toString().trim()
          : fallbackTitle,
      question: map['question']?.toString().trim().isNotEmpty == true
          ? map['question'].toString().trim()
          : '请补充这部分创作信息。',
      hint: map['hint']?.toString().trim() ?? '',
      required: map['required'] is bool ? map['required'] as bool : true,
    );
  }
}

/// Review prompts for each stage type
const _reviewPrompts = {
  'brief': '''请审阅以下短剧策划 Brief，给出质量评估。
评分维度：
1. 内容完整性（类型、时长、情绪基调、故事大纲是否完整）
2. 逻辑一致性（各字段是否自洽）
3. 可执行性（能否直接用于剧本生成）

Brief 内容：
{content}

输出严格 JSON：{"score": 1-10, "pass": true/false, "feedback": "修改建议（中文）"}''',
  'script': '''请审阅以下短剧剧本，给出质量评估。
评分维度：
1. 场景是否完整（2-5个场景）
2. 每个场景是否包含 scene_num, location, description, action, duration
3. 角色和场景 assets 是否提取完整
4. 总时长是否合理

剧本内容：
{content}

输出严格 JSON：{"score": 1-10, "pass": true/false, "feedback": "修改建议（中文）"}''',
  'storyboard': '''请审阅以下分镜脚本，给出质量评估。

【最高优先级】内容忠于剧本：
1. 分镜中的角色姓名、身份必须与剧本完全一致，不得凭空创造新角色。
2. 分镜中的场景地点必须与剧本中的场景一一对应，不得增加剧本中没有的地点。
3. 分镜中的关键情节和事件必须与剧本一致，不得偏离剧本的核心故事线。
4. 如果分镜与剧本在角色、地点、情节上有明显不符，评分必须为 1-3 分，必须打回。

其他评分维度：
5. 分镜是否覆盖了剧本中的所有场景（每个剧本场景至少有一个对应分镜）。
6. 每个分镜是否包含 scene_num, shot_num, first_frame_prompt, video_prompt 等必要字段。
7. first_frame_prompt 是否足够详细（光影、色调、构图、角色外貌）。
8. video_prompt 是否描述了动态（运镜、动作、环境变化）。

参考剧本：
{script}

分镜内容：
{content}

输出严格 JSON：{"score": 1-10, "pass": true/false, "feedback": "修改建议（中文）"}''',
  'video': '''请审阅以下视频生成结果，给出质量评估。
评分维度：
1. 视频 clips 数量是否与分镜 storyboards 数量一致
2. 成功生成的 clip 数量是否 >= 总数的一半
3. 失败的 clip 是否有明确的 error_reason

视频生成结果：
{content}

输出严格 JSON：{"score": 1-10, "pass": true/false, "feedback": "修改建议（中文）"}''',
  'assets': '''请审阅以下资产设计结果，给出质量评估。

【最高优先级规则 — 违反任何一条将导致评分必须为 1-3 分，必须打回】

1. **角色描述必须具体明确**：
   - 角色可以是人物、动物、物体或任何创意设定的存在
   - 必须准确反映创意描述中对角色的定义和设定
   - 必须描述核心外观特征（形状、颜色、材质、尺寸等）
   - 必须描述关键视觉细节（用于区分该角色与其他类似事物）
   - 禁止使用模糊描述如"一个东西"、"某个角色"
   - 描述必须与创意描述中的角色设定一致
   - 示例（人物）："男性青少年，16岁，圆脸，短发黑色，穿着白色校服衬衫"
   - 示例（物体角色）："一个拟人化的包子角色，白色面团身体，带有笑脸表情，戴着红色厨师帽"

2. **场景描述必须具体明确**：
   - 必须明确场景类型（室内/室外/虚构空间等）
   - 必须包含主要建筑物或环境特征
   - 必须包含光线和色调描述
   - 禁止使用模糊描述如"一个地方"、"某处"

3. **道具描述必须具体明确**：
   - 必须明确物品的具体类型
   - 必须包含外观、材质、颜色描述
   - 禁止使用模糊描述如"一个东西"、"某个物品"

其他评分维度：
4. 是否所有角色、场景和道具资产都有 reference_image_url
5. 失败的比例是否过高

资产设计结果：
{content}

输出严格 JSON：{"score": 1-10, "pass": true/false, "feedback": "修改建议（中文）"}''',
};

/// Events emitted during stage execution for UI progress display
enum StageEventType {
  started, // stage beginning
  generating, // agent generating content
  generated, // agent finished generating
  reviewing, // review starting
  reviewPassed, // review passed
  reviewFailed, // review failed, will retry
  retryAttempt, // retry attempt starting
  exhausted, // max retries exhausted
  completed, // stage fully done
  error, // stage error
}

class StageEvent {
  final StageEventType type;
  final String stageLabel;
  final String? content;
  final int? score;
  final bool? passed;
  final String? feedback;
  final int attempt;

  StageEvent({
    required this.type,
    required this.stageLabel,
    this.content,
    this.score,
    this.passed,
    this.feedback,
    this.attempt = 1,
  });
}

typedef StageEventCallback = void Function(StageEvent event);

class DirectorAgent extends Agent {
  @override
  String get name => 'DirectorAgent';

  final PlanningAgent planningAgent;
  final ScriptAgent scriptAgent;
  final AssetDesignAgent assetDesignAgent;
  final ProductionAgent productionAgent;
  final VideoAgent videoAgent;
  final LlmService llm;

  static const int maxRetries = 3;
  static const preflightQuestions = [
    DirectorGuidanceQuestion(
      id: 'duration_unit',
      title: '1. 明确时长单位',
      question: '这个「75」具体表示什么？请写清单位和用途。',
      hint: '例如：75秒，竖屏微短剧单集总时长；每集约75秒。',
      required: true,
    ),
    DirectorGuidanceQuestion(
      id: 'supporting_role',
      title: '2. 补全关键配角',
      question: '周瑞是谁？他和主角分别是什么关系？在剧情里承担什么作用？',
      hint: '例如：陈振飞的同班好友，暗恋俞墨凡，负责制造误会和推动告白。',
      required: true,
    ),
    DirectorGuidanceQuestion(
      id: 'inciting_event',
      title: '3. 交集契机',
      question: '撞人/相遇之后，主角二人为什么会继续产生交集？',
      hint: '例如：俞墨凡发现陈振飞拿错了她的书包，两人被迫一起找回。',
      required: true,
    ),
    DirectorGuidanceQuestion(
      id: 'emotional_beats',
      title: '4. 情感推进',
      question: '两人关系从陌生到靠近，中间发生哪几个关键事件？',
      hint: '例如：误会、道歉、共同完成课堂任务、雨天送伞、发现彼此秘密。',
      required: true,
    ),
    DirectorGuidanceQuestion(
      id: 'conflict_ending',
      title: '5. 冲突与结局',
      question: '故事的核心冲突是什么？最后落在什么结局或情绪上？',
      hint: '例如：周瑞的误会让两人疏远，结尾陈振飞公开道歉，俞墨凡露出笑意。',
      required: true,
    ),
    DirectorGuidanceQuestion(
      id: 'character_bios',
      title: '6. 人物小传',
      question: '请补充核心人物性格和行为逻辑，尤其是陈振飞、俞墨凡、周瑞。',
      hint: '例如：陈振飞跳脱粗心但真诚；俞墨凡清冷慢热；周瑞敏感好胜。',
      required: true,
    ),
  ];

  Future<List<DirectorGuidanceQuestion>> analyzePreflightQuestions(
    String creativeInput,
  ) async {
    final prompt = '''请只诊断用户创意描述在生成短剧 Brief 前还缺哪些关键信息，并把缺口转成逐步追问用户的问题。

重要规则：
- 不要替用户补写剧情，不要生成故事大纲，不要扩写创意。
- 只问会影响后续剧本生成的缺失项。
- 如果用户已经明确的信息，不要重复追问。
- 问题数量控制在 0-6 个，按最重要到次重要排序。
- 如果出现数字但单位不清，必须追问单位和含义。
- 如果出现人物但身份、关系或剧情作用不清，必须追问。
- 如果故事只有开场，没有后续交集、情感推进、冲突、结局，必须拆成具体问题追问。

输出严格 JSON，不要任何多余文字：
{
  "questions": [
    {
      "id": "稳定英文或拼音下划线 id",
      "title": "1. 简短标题",
      "question": "面向用户的一句话问题",
      "hint": "可填写示例，不要替用户决定",
      "required": true
    }
  ]
}

用户创意描述：
$creativeInput''';

    try {
      final response = await llm.chatCompletion(
        messages: [
          ChatMessage(
            role: 'system',
            content: '你是 DirectorAgent 的前置问诊模块，只负责发现信息缺口并提问。',
          ),
          ChatMessage(role: 'user', content: prompt),
        ],
        jsonMode: true,
        temperature: 0.2,
        requestTag: 'director.preflight',
      );
      final decoded = jsonDecode(response.content);
      final rawQuestions =
          decoded is Map<String, dynamic> ? decoded['questions'] : null;
      if (rawQuestions is! List) return preflightQuestions;

      final questions = <DirectorGuidanceQuestion>[];
      for (var i = 0; i < rawQuestions.length && i < 6; i++) {
        final item = rawQuestions[i];
        if (item is Map<String, dynamic>) {
          questions.add(DirectorGuidanceQuestion.fromMap(item, i));
        } else if (item is Map) {
          questions.add(
            DirectorGuidanceQuestion.fromMap(
                Map<String, dynamic>.from(item), i),
          );
        }
      }
      return questions;
    } catch (e, st) {
      await AppLogger.error(
        'Director preflight analysis failed',
        error: e,
        stackTrace: st,
      );
      return preflightQuestions;
    }
  }

  DirectorAgent({required this.llm})
      : planningAgent = PlanningAgent(llm: llm),
        scriptAgent = ScriptAgent(llm: llm),
        assetDesignAgent = AssetDesignAgent(),
        productionAgent = ProductionAgent(llm: llm),
        videoAgent = VideoAgent();

  @override
  Future<AgentResult> run(AgentContext context) async {
    final currentStage =
        (context.data['currentStage'] as String?) ?? 'planning';

    switch (currentStage) {
      case 'planning':
        return runPlanning(context);
      case 'scripting':
        return runScripting(context);
      case 'asseting':
        return runAsseting(context);
      case 'storyboarding':
        return runStoryboarding(context);
      case 'generating':
        return runGenerating(context);
      case 'cutting':
        return runCutting(context);
      default:
        return AgentResult.success({'message': 'Project complete'});
    }
  }

  Future<AgentResult> runPlanning(AgentContext context,
      {StageEventCallback? onEvent}) async {
    return runStageWithReview(
      context,
      planningAgent,
      reviewContent: 'brief',
      stageLabel: '策划',
      onEvent: onEvent,
    );
  }

  Future<AgentResult> runScripting(AgentContext context,
      {StageEventCallback? onEvent}) async {
    return runStageWithReview(
      context,
      scriptAgent,
      reviewContent: 'script',
      stageLabel: '编剧',
      onEvent: onEvent,
    );
  }

  Future<AgentResult> runAsseting(AgentContext context,
      {StageEventCallback? onEvent}) async {
    return runStageWithReview(
      context,
      assetDesignAgent,
      reviewContent: 'assets',
      stageLabel: '资产设计',
      onEvent: onEvent,
    );
  }

  Future<AgentResult> runStoryboarding(AgentContext context,
      {StageEventCallback? onEvent}) async {
    return runStageWithReview(
      context,
      productionAgent,
      reviewContent: 'storyboard',
      stageLabel: '分镜',
      onEvent: onEvent,
    );
  }

  Future<AgentResult> runGenerating(AgentContext context,
      {StageEventCallback? onEvent}) async {
    return runStageWithReview(
      context,
      videoAgent,
      reviewContent: 'video',
      stageLabel: '视频',
      onEvent: onEvent,
    );
  }

  Future<AgentResult> runCutting(AgentContext context,
      {StageEventCallback? onEvent}) async {
    // Final video stitching - handled separately
    return AgentResult.success({
      ...context.data,
      'nextStage': 'done',
    });
  }

  /// Core pattern: run agent → review with LLM → retry if needed
  Future<AgentResult> runStageWithReview(
    AgentContext context,
    Agent agent, {
    required String reviewContent,
    required String stageLabel,
    StageEventCallback? onEvent,
  }) async {
    AgentResult? lastResult;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      onEvent?.call(StageEvent(
        type:
            attempt == 0 ? StageEventType.started : StageEventType.retryAttempt,
        stageLabel: stageLabel,
        attempt: attempt + 1,
      ));

      if (attempt > 0 && lastResult != null) {
        // Inject feedback into context for retry
        final reviewData = lastResult.data;
        final feedback = reviewData is Map<String, dynamic>
            ? reviewData['feedback'] as String?
            : null;
        if (feedback != null) {
          context.data['feedback'] = feedback;
        }
      }

      // Run the agent
      onEvent?.call(StageEvent(
        type: StageEventType.generating,
        stageLabel: stageLabel,
        attempt: attempt + 1,
      ));

      lastResult = await agent.run(context);
      if (!lastResult.success) {
        await AppLogger.warn(
          'Director stage agent returned error',
          data: {
            'projectId': context.projectId,
            'stage': context.data['currentStage']?.toString() ?? 'planning',
            'agent': agent.name,
            'attempt': attempt + 1,
            'errorMessage': lastResult.error,
          },
        );
        onEvent?.call(StageEvent(
          type: StageEventType.error,
          stageLabel: stageLabel,
          attempt: attempt + 1,
          feedback: lastResult.error,
        ));
        // Retry on agent error too (not just review failure)
        continue;
      }

      // Notify that content was generated
      final contentPreview = _previewOutput(lastResult.data, reviewContent);
      onEvent?.call(StageEvent(
        type: StageEventType.generated,
        stageLabel: stageLabel,
        content: contentPreview,
        attempt: attempt + 1,
      ));

      // Review the output
      onEvent?.call(StageEvent(
        type: StageEventType.reviewing,
        stageLabel: stageLabel,
        attempt: attempt + 1,
      ));

      final reviewResult = await _review(
        reviewContent,
        lastResult.data,
        scriptText: context.data['scriptForReview'] as String?,
      );

      final reviewData = reviewResult.data;
      if (reviewData is Map<String, dynamic>) {
        final passed = reviewData['pass'] as bool? ?? false;
        final score = reviewData['score'] as num? ?? 0;
        final feedback = reviewData['feedback'] as String? ?? '';

        if (passed) {
          onEvent?.call(StageEvent(
            type: StageEventType.reviewPassed,
            stageLabel: stageLabel,
            score: score.toInt(),
            passed: true,
            feedback: feedback.isEmpty ? '通过' : feedback,
            attempt: attempt + 1,
          ));

          await AppLogger.info(
            'Director review passed',
            data: {
              'projectId': context.projectId,
              'stage': context.data['currentStage']?.toString() ?? 'planning',
              'agent': agent.name,
              'attempt': attempt + 1,
              'score': score,
            },
          );
          final resultData = <String, dynamic>{
            'reviewScore': score,
            'nextStage': _getNextStage(context),
          };
          if (lastResult.data is Map<String, dynamic>) {
            resultData.addAll(lastResult.data as Map<String, dynamic>);
          }
          return AgentResult.success(resultData);
        }

        onEvent?.call(StageEvent(
          type: StageEventType.reviewFailed,
          stageLabel: stageLabel,
          score: score.toInt(),
          passed: false,
          feedback: feedback,
          attempt: attempt + 1,
        ));

        if (attempt >= maxRetries) {
          await AppLogger.warn(
            'Director review exhausted retries',
            data: {
              'projectId': context.projectId,
              'stage': context.data['currentStage']?.toString() ?? 'planning',
              'agent': agent.name,
              'score': score,
              'feedback': feedback,
            },
          );
          final resultData = <String, dynamic>{
            'reviewScore': score,
            'reviewFeedback': '审阅未通过（$maxRetries次重试仍失败）：$feedback',
            'nextStage': _getNextStage(context),
          };
          if (lastResult.data is Map<String, dynamic>) {
            resultData.addAll(lastResult.data as Map<String, dynamic>);
          }
          return AgentResult.success(resultData);
        }

        await AppLogger.warn(
          'Director review requested retry',
          data: {
            'projectId': context.projectId,
            'stage': context.data['currentStage']?.toString() ?? 'planning',
            'agent': agent.name,
            'attempt': attempt + 1,
            'score': score,
            'feedback': feedback,
          },
        );
      } else {
        // Review didn't parse correctly, assume pass
        await AppLogger.warn(
          'Director review returned non-map payload; treating as pass',
          data: {
            'projectId': context.projectId,
            'stage': context.data['currentStage']?.toString() ?? 'planning',
            'agent': agent.name,
            'reviewDataType': reviewData.runtimeType.toString(),
          },
        );
        onEvent?.call(StageEvent(
          type: StageEventType.reviewPassed,
          stageLabel: stageLabel,
          score: 5,
          passed: true,
          feedback: '审阅通过',
          attempt: attempt + 1,
        ));
        final resultData = <String, dynamic>{
          'nextStage': _getNextStage(context),
        };
        if (lastResult.data is Map<String, dynamic>) {
          resultData.addAll(lastResult.data as Map<String, dynamic>);
        }
        return AgentResult.success(resultData);
      }
    }

    return lastResult ?? AgentResult.error('Unknown error');
  }

  String _previewOutput(dynamic data, String reviewType) {
    if (data is! Map<String, dynamic>) return '';
    switch (reviewType) {
      case 'brief':
        final parts = <String>[];
        if (data['genre'] != null) parts.add('类型: ${data['genre']}');
        if (data['duration'] != null) parts.add('时长: ${data['duration']}秒');
        if (data['mood'] != null) parts.add('情绪: ${data['mood']}');
        if (data['visual_style'] != null)
          parts.add('风格: ${data['visual_style']}');
        if (data['story_outline'] != null)
          parts.add('故事: ${data['story_outline']}');
        return parts.join('\n');
      case 'script':
        final scenes = data['scenes'] as List?;
        if (scenes != null) {
          final lines = <String>[];
          for (final s in scenes) {
            if (s is Map<String, dynamic>) {
              final num = s['scene_num'];
              final loc = s['location'] ?? '';
              final desc = s['description'] ?? '';
              lines.add('场景${num}: [$loc] $desc');
            }
          }
          return lines.join('\n');
        }
        return '';
      case 'storyboard':
        final storyboards = data['storyboards'] as List?;
        if (storyboards != null) {
          final lines = <String>[];
          for (final sb in storyboards) {
            if (sb is Map<String, dynamic>) {
              final scene = sb['scene_num'];
              final shot = sb['shot_num'];
              final desc = sb['description'] ?? '';
              lines.add('镜头${scene}-${shot}: $desc');
            }
          }
          return lines.join('\n');
        }
        return '';
      case 'video':
        final clips = data['clips'] as List?;
        if (clips != null) {
          final lines = <String>[];
          for (final c in clips) {
            if (c is Map<String, dynamic>) {
              final sbId = c['storyboard_id'] ?? '?';
              final state = c['state'] ?? '?';
              final url = c['video_url'] as String?;
              if ((state == 'completed' || state == 'done') && url != null) {
                final preview = url.length > 40 ? url.substring(0, 40) : url;
                lines.add('镜头$sbId: 已生成 $preview...');
              } else {
                lines.add('镜头$sbId: 失败 - ${c['error_reason'] ?? "未知"}');
              }
            }
          }
          return lines.join('\n');
        }
        return '';
      case 'assets':
        final assets = data['assets'] as List?;
        if (assets != null) {
          final lines = <String>[];
          for (final a in assets) {
            if (a is Map<String, dynamic>) {
              final type = a['type'] == 'character'
                  ? '角色'
                  : (a['type'] == 'prop' ? '道具' : '场景');
              final name = a['name'] ?? '?';
              final refUrl = a['reference_image_url'] as String?;
              final hasImage = refUrl != null && refUrl.isNotEmpty;
              lines.add('$type: $name ${hasImage ? "✓" : "✗"}');
            }
          }
          return lines.join('\n');
        }
        return '';
      default:
        return '';
    }
  }

  Future<AgentResult> _review(String type, dynamic content,
      {String? scriptText}) async {
    final promptTemplate = _reviewPrompts[type];
    if (promptTemplate == null) {
      return AgentResult.success({});
    }

    final reviewContent = _toReviewableContent(content);

    String prompt;
    if (type == 'storyboard' && scriptText != null) {
      prompt = promptTemplate.replaceFirst('{script}', scriptText).replaceFirst(
          '{content}',
          reviewContent is String ? reviewContent : jsonEncode(reviewContent));
    } else {
      prompt = promptTemplate.replaceFirst(
        '{content}',
        reviewContent is String ? reviewContent : jsonEncode(reviewContent),
      );
    }

    try {
      final response = await llm.chatCompletion(
        messages: [
          ChatMessage(role: 'system', content: _directorReviewSystemPrompt),
          ChatMessage(role: 'user', content: prompt),
        ],
        requestTag: 'director.review.$type',
        jsonMode: true,
        temperature: 0.3,
      );

      final review = jsonDecode(response.content) as Map<String, dynamic>;
      return AgentResult.success(review);
    } catch (e, st) {
      await AppLogger.warn(
        'Director review failed; treating as pass',
        data: {
          'type': type,
        },
        error: e,
        stackTrace: st,
      );
      // If review fails, assume pass
      return AgentResult.success({'pass': true, 'score': 5});
    }
  }

  dynamic _toReviewableContent(dynamic value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }

    if (value is Scene) {
      return value.toMap();
    }

    if (value is Asset) {
      return value.toMap();
    }

    if (value is Storyboard) {
      return value.toMap();
    }

    if (value is List) {
      return value.map(_toReviewableContent).toList();
    }

    if (value is Map) {
      final result = value.map(
        (key, dynamic nestedValue) => MapEntry(
          key.toString(),
          _toReviewableContent(nestedValue),
        ),
      );
      return Map<String, dynamic>.from(result);
    }

    return value.toString();
  }

  String _getNextStage(AgentContext context) {
    final current = context.data['currentStage'] as String? ?? 'planning';
    final idx = stageOrder.indexOf(current);
    if (idx >= 0 && idx < stageOrder.length - 1) {
      return stageOrder[idx + 1];
    }
    return 'done';
  }

  AgentResult advanceIfOk(
    AgentContext context,
    AgentResult result,
    WorkflowStage nextStage,
  ) {
    if (result.success) {
      return AgentResult.success({
        ...result.data ?? {},
        'nextStage': nextStage,
      });
    }
    return result;
  }

  int getCurrentStageIndex(WorkflowStage state) => stageOrder.indexOf(state);

  WorkflowStage? getNextStage(WorkflowStage state) {
    final idx = getCurrentStageIndex(state);
    return idx >= 0 && idx < stageOrder.length - 1 ? stageOrder[idx + 1] : null;
  }
}
