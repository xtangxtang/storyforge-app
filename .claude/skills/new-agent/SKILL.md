---
name: new-agent
description: 在 Storyforge 流水线中新建一个继承 Agent 的 AI 阶段代理,并接入 DirectorAgent。当用户要求"加一个新 agent / 新增一个生成阶段 / 新建一个流水线代理"时使用。
---

# 新建 Storyforge Agent

按本项目既有约定创建一个新的 `Agent` 子类,并把它接入流水线。**严格复用现有模式**,不要引入新的依赖注入框架或状态管理。

## 1. 先读现有实现

动手前先看 `lib/core/agents.dart` 里 `PlanningAgent` / `ScriptAgent` 的写法,以及 `lib/core/agent.dart` 的基类定义,确保命名、注入、返回值风格一致。

## 2. Agent 子类模板

在 `lib/core/agents.dart` 中新增(把 `Xxx` 换成实际名字):

```dart
class XxxAgent extends Agent {
  @override
  String get name => 'XxxAgent';

  final LlmService llm;
  XxxAgent({required this.llm});

  @override
  Future<AgentResult> run(AgentContext context) async {
    // 1) 从 data bag 读输入(上一阶段的产物)
    final prompt = context.data['prompt'] as String?;
    if (prompt == null || prompt.isEmpty) {
      return AgentResult.error('No prompt provided for Xxx');
    }

    // 2) 拼接重试反馈 + 导演约束 + 创作记忆(与其他 agent 保持一致)
    final feedback = context.data['feedback'] as String?;
    final feedbackText =
        feedback != null ? '\n修改建议（请根据以下建议调整）：$feedback' : '';
    final directorGuidance = context.data['director_guidance'] as String?;
    final guidanceText =
        directorGuidance != null && directorGuidance.trim().isNotEmpty
            ? '\n\nDirectorAgent 已确认的创作约束,必须优先遵守：\n$directorGuidance'
            : '';
    final memoryText = _creativeMemoryInstruction(context);

    // 3) 调 LLM(系统提示词放在文件顶部的 const _xxxSystemPrompt)
    final messages = [
      ChatMessage(role: 'system', content: _xxxSystemPrompt),
      ChatMessage(
          role: 'user',
          content: '$prompt$guidanceText$memoryText$feedbackText'),
    ];

    try {
      final reply = await llm.chat(messages);
      // 4) 解析(若是 JSON,用 jsonDecode 并做容错),写回 data bag 供下一阶段
      context.data['xxx_result'] = reply;
      AppLogger.instance.info('XxxAgent 完成');
      return AgentResult.success(reply);
    } catch (e) {
      AppLogger.instance.error('XxxAgent 失败: $e');
      return AgentResult.error('Xxx 生成失败: $e');
    }
  }
}
```

约定要点:
- `name` 用 `'XxxAgent'`,与类名一致。
- 依赖通过构造函数注入(`LlmService` / `DashscopeService`),**不要** new 服务实例。
- 所有面向 LLM 的提示词、给用户的日志/错误信息一律**中文**。
- 系统提示词写成文件顶部的 `const _xxxSystemPrompt = '''...''';`,要求 LLM 严格输出 JSON 的话,沿用现有"不要任何多余文字 + 给出 JSON 结构"的写法。
- 输入/输出都走 `context.data` 这个 `Map<String, dynamic>` data bag,key 用 snake_case。

## 3. 接入流水线

1. 如果它是一个新的工作流阶段,在 `lib/core/director_agent.dart` 的 `stageOrder` 列表里按顺序插入阶段名。
2. 在 `DirectorAgent` 中实例化并通过 `runStageWithReview()` 调用(沿用 generate → LLM 评分(1-10) → 分数 < 6 带 feedback 重试 → 最多 3 次 的回路)。
3. 若需要评审,在 `_reviewPrompts` 里加一条对应该阶段的中文评审提示词(输出 `{"score","pass","feedback"}`)。
4. 若产物要落库,在 `lib/db/dao/` 加/复用对应 DAO(一表一类),并在 `lib/models/` 定义数据模型。

## 4. 收尾

- 运行 `dart format lib/core/agents.dart` 和 `dart analyze`。
- 若可能,在 `test/` 加一个最小单测覆盖新 agent 的输入校验与错误分支。
