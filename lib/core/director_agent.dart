import 'dart:convert';
import 'agent.dart';
import 'agents.dart';
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
评分维度：
1. 分镜是否覆盖所有场景
2. 每个分镜是否包含 scene_num, shot_num, first_frame_prompt, video_prompt
3. first_frame_prompt 是否足够详细（光影、色调、构图）
4. video_prompt 是否描述了动态（运镜、动作）

分镜内容：
{content}

输出严格 JSON：{"score": 1-10, "pass": true/false, "feedback": "修改建议（中文）"}''',
};

class DirectorAgent extends Agent {
  @override
  String get name => 'DirectorAgent';

  final PlanningAgent planningAgent;
  final ScriptAgent scriptAgent;
  final ProductionAgent productionAgent;
  final LlmService llm;

  static const int maxRetries = 3;

  DirectorAgent({required this.llm})
      : planningAgent = PlanningAgent(llm: llm),
        scriptAgent = ScriptAgent(llm: llm),
        productionAgent = ProductionAgent(llm: llm);

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

  Future<AgentResult> runPlanning(AgentContext context) async {
    return runStageWithReview(
      context,
      planningAgent,
      reviewContent: 'brief',
    );
  }

  Future<AgentResult> runScripting(AgentContext context) async {
    return runStageWithReview(
      context,
      scriptAgent,
      reviewContent: 'script',
    );
  }

  Future<AgentResult> runAsseting(AgentContext context) async {
    // Assets are extracted from script output
    return advanceIfOk(context, AgentResult.success({}), 'storyboarding');
  }

  Future<AgentResult> runStoryboarding(AgentContext context) async {
    return runStageWithReview(
      context,
      productionAgent,
      reviewContent: 'storyboard',
    );
  }

  Future<AgentResult> runGenerating(AgentContext context) async {
    // Video generation - handled separately by the UI/workflow
    return advanceIfOk(context, AgentResult.success({}), 'cutting');
  }

  Future<AgentResult> runCutting(AgentContext context) async {
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
  }) async {
    AgentResult? lastResult;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
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
      lastResult = await agent.run(context);
      if (!lastResult.success) {
        return lastResult;
      }

      // Review the output
      final reviewResult = await _review(
        reviewContent,
        lastResult.data,
      );

      final reviewData = reviewResult.data;
      if (reviewData is Map<String, dynamic>) {
        final passed = reviewData['pass'] as bool? ?? false;
        final score = reviewData['score'] as num? ?? 0;
        final feedback = reviewData['feedback'] as String? ?? '';

        if (passed) {
          final resultData = <String, dynamic>{
            'reviewScore': score,
            'nextStage': _getNextStage(context),
          };
          if (lastResult.data is Map<String, dynamic>) {
            resultData.addAll(lastResult.data as Map<String, dynamic>);
          }
          return AgentResult.success(resultData);
        }

        if (attempt >= maxRetries) {
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
      } else {
        // Review didn't parse correctly, assume pass
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

  Future<AgentResult> _review(String type, dynamic content) async {
    final promptTemplate = _reviewPrompts[type];
    if (promptTemplate == null) {
      return AgentResult.success({});
    }

    final prompt = promptTemplate.replaceFirst(
      '{content}',
      content is Map ? jsonEncode(content) : content.toString(),
    );

    try {
      final response = await llm.chatCompletion(
        messages: [
          ChatMessage(role: 'system', content: _directorReviewSystemPrompt),
          ChatMessage(role: 'user', content: prompt),
        ],
        jsonMode: true,
        temperature: 0.3,
      );

      final review = jsonDecode(response.content) as Map<String, dynamic>;
      return AgentResult.success(review);
    } catch (e) {
      // If review fails, assume pass
      return AgentResult.success({'pass': true, 'score': 5});
    }
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

  int getCurrentStageIndex(WorkflowStage state) =>
      stageOrder.indexOf(state);

  WorkflowStage? getNextStage(WorkflowStage state) {
    final idx = getCurrentStageIndex(state);
    return idx >= 0 && idx < stageOrder.length - 1 ? stageOrder[idx + 1] : null;
  }
}
