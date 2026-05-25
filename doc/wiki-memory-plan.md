# Storyforge Wiki Memory Plan

本文记录 Storyforge 的 wiki-first 创作记忆方案、已经完成的修改动作，以及后续演进计划。后续修改 Agent、创作流程、项目状态恢复、上下文传递时，应优先参考本文。

## 背景判断

原有流程主要依赖 SQLite 表和 `AgentContext.data` 在阶段间传递信息：

```text
Creative Input -> Planning -> Scripting -> Asseting -> Storyboarding -> Generating
```

这个方式的问题是：

- 用户在 DirectorAgent 问诊中补全的信息只会强约束前置阶段，后续编剧、角色道具设计、分镜和视频生成容易丢上下文。
- 数据库表按阶段横向切分，角色关系、故事约束、视觉锚点、道具设定散落在不同对象里，后续 Agent 很难获得同一份稳定事实源。
- LLM 每一步都可能重新解释上一阶段结果，导致人物关系、剧情作用、道具和视觉风格漂移。

因此采用 Karpathy `llm-wiki` 思路：每个创意项目都生成一套 Markdown wiki，把它作为项目级创作记忆。数据库短期保留为运行缓存和 UI 查询缓存，wiki 逐步成为事实源。

## 设计原则

- `raw/` 保存用户原始输入和用户答案，Agent 不应擅自改写。
- `wiki/` 保存 Agent 持续维护的创作记忆，包括约束、故事圣经、Brief、剧本、资产、分镜和视频提示词。
- 每个阶段完成后都要更新 wiki。
- 每个阶段调用 LLM 或生成服务前，都要从 wiki 编译当前阶段需要的上下文。
- 用户确认的约束优先级高于 LLM 自动生成内容。
- wiki-first 不等于立即删除数据库。SQLite 暂时保留，后续可降级为缓存、索引或任务队列。
- self-growing wiki 是项目记忆的默认演进机制：每次阶段产物、用户答案、资产、分镜、视频或本地文件发生变化后，都应经过统一 mutation 服务写入结构化 wiki，再由 LLM 抽取可长期保留的新知识、去重、归档，并更新 `wiki/knowledge.md`。
- 新增代码时不要绕过 `WikiMutationService` 直接维护创作记忆；确实只做底层文件初始化或无 LLM 的本地下载时，应在上层流程补一次 mutation，让后续阶段能读到同一份上下文。

## 项目 Wiki 目录

运行时项目 wiki 存放在：

```text
%LOCALAPPDATA%\Storyforge\projects\<projectId>\
```

当前目录结构：

```text
raw/
  creative_input.md
  user_answers.md
wiki/
  index.md
  open_questions.md
  constraints.md
  story_bible.md
  brief.md
  script.md
  asset_manifest.md
  storyboards.md
  video_prompt_pack.md
  video_results.md
  knowledge.md
  decisions.md
  log.md
archive/
outputs/
  images/
  videos/
```

## Self-Growing Wiki 机制

核心目标：每个项目都有一份会随创作流程自动生长的 Markdown 记忆。它不只是保存阶段输出，而是把“对后续有用的事实、约束、连续性要求、开放问题和决策”沉淀成长期上下文。

统一入口：

- `lib/services/wiki_mutation_service.dart`
- `WikiMutationService` 包装 `ProjectWikiStore` 和 `LlmService`。
- 外层 UI 或 Agent 流程在用户答案、Brief、剧本、资产、分镜、视频片段、视频文件发生变化后，应优先调用 `WikiMutationService` 的 mutation 方法，而不是各自手写 wiki 更新逻辑。

当前 mutation 类型：

- `updateUserAnswers`
- `updateBrief`
- `updateScript`
- `updateAssets`
- `updateStoryboards`
- `updateVideoClips`
- `persistVideoFile`
- `appendLog`
- `compileContextPack`

每次 mutation 的默认流程：

1. 先用 `ProjectWikiStore` 更新对应结构化页面，例如 `constraints.md`、`story_bible.md`、`script.md`、`asset_manifest.md`、`storyboards.md`、`video_prompt_pack.md`、`video_results.md`。
2. 再读取当前 wiki 上下文，把本次变化交给 LLM 总结。
3. LLM 只输出结构化 JSON，包括 `canon`、`characters`、`locations`、`props`、`continuity`、`open_questions`、`decisions`、`archive_notes`。
4. 服务端做去重合并，把长期有效内容写入 `wiki/knowledge.md`。
5. 不适合放入长期主记忆但值得追踪的内容写入 `archive/wiki_growth_<timestamp>_<mutationType>.md`。
6. 如果 LLM 总结失败，只记录日志，不阻断主流程。

`wiki/knowledge.md` 是后续阶段读取的核心长期记忆，当前固定章节包括：

- `Canon`
- `Characters`
- `Locations`
- `Props`
- `Continuity`
- `Open Questions`
- `Decisions`
- `Archive Index`

阶段调用 LLM 或生成服务前的规则：

- 先调用 `compileContextPack(stage)` 编译 wiki 上下文。
- 将上下文注入 `AgentContext.data['creative_memory']` 或等价字段。
- DirectorAgent 进入每个新阶段前，应基于 wiki 生成建议/询问列表，让用户确认或补充必要信息。
- 后续生成 Brief、剧本、角色/道具、分镜、视频 prompt 时都必须读取同一份 wiki memory。

视频与文件输出规则：

- 生成或提取的视频应默认保存到 `%LOCALAPPDATA%\Storyforge\projects\<projectId>\outputs\videos\`。
- 成功保存后应写入 `wiki/video_results.md`，并通过 self-growing 流程提炼对后续剪辑、连续性或重生成有用的信息。

连续性规则：

- 分镜与视频 prompt 必须把上一镜头的结束状态、当前镜头的起始状态、人物朝向、运动方向、场景地理关系、服装道具一致性写清楚。
- 这些内容应进入 `wiki/knowledge.md` 的 `Continuity` 或对应分镜页，供下一镜头生成时读取。

当前边界：

- SQLite 仍是运行/UI 缓存，不是长期创作事实源。
- 允许 DAO 继续负责 UI 状态和数据库兼容，但凡会影响创作语义或后续生成的更新，都要同步经过 `WikiMutationService`。
- `ProjectWikiStore` 负责底层文件读写；`WikiMutationService` 负责“写入 + 总结 + 去重 + 归档 + 长期知识更新”。

## 已完成修改动作

### 1. 动态 DirectorAgent 问诊

文件：

- `lib/core/director_agent.dart`
- `lib/screens/create_project_screen.dart`

已实现：

- `DirectorAgent.analyzePreflightQuestions()` 会先分析用户创意描述缺哪些关键信息。
- LLM 只负责生成问题，不允许替用户扩写剧情。
- 创建页按动态问题一步步引导用户补全。
- 未完成必填问题时，不进入 Planning。

### 2. 项目 Wiki 存储层

文件：

- `lib/services/project_wiki_store.dart`

已实现：

- `ProjectWikiStore.initializeProject()` 创建项目 wiki 目录和基础页面。
- `updateOpenQuestions()` 写入前置问诊问题。
- `updateUserAnswers()` 写入用户答案，并更新 `constraints.md` 和 `story_bible.md`。
- `updateBrief()` 写入 `brief.md`，并合并到 `story_bible.md`。
- `updateScript()` 写入 `script.md`，并合并剧本摘要。
- `updateAssets()` 写入 `asset_manifest.md`，记录角色、场景、道具视觉锚点和参考图。
- `updateStoryboards()` 写入 `storyboards.md` 和 `video_prompt_pack.md`。
- `updateVideoClips()` 写入 `video_results.md`。
- `appendLog()` 在 `wiki/log.md` 记录阶段更新动作。
- `compileContextPack(stage)` 按阶段编译 wiki 上下文。

### 3. 创建流程同步 Wiki

文件：

- `lib/screens/create_project_screen.dart`

已实现：

- 新项目创建时写入 `raw/creative_input.md`。
- 动态问诊结果写入 `wiki/open_questions.md`。
- 用户答案写入 `raw/user_answers.md` 和 `wiki/constraints.md`。
- 每个阶段成功后同步对应 wiki 页面。
- 恢复项目时，会根据数据库已有内容重建/补齐 wiki。
- `_refreshCreativeMemory(stage)` 会把 `ProjectWikiStore.compileContextPack()` 的结果写入 `AgentContext.data['creative_memory']`。

### 4. Agent 注入 Wiki Memory

文件：

- `lib/core/agents.dart`

已实现：

- `_creativeMemoryInstruction()` 把 `creative_memory` 包装成高优先级项目 wiki 记忆。
- `PlanningAgent` 调用 LLM 时注入 wiki memory。
- `ScriptAgent` 调用 LLM 时注入 wiki memory。
- `ProductionAgent` 生成分镜时注入 wiki memory。
- `AssetDesignAgent` 生成资产参考图 prompt 时注入 wiki memory。
- `VideoAgent` 生成首帧图和视频 prompt 时注入 wiki memory。

## 当前策略

短期采用：

```text
SQLite = 运行缓存 / UI 查询缓存 / 兼容旧流程
Wiki = 项目创作记忆 / 跨阶段事实源 / LLM 上下文源
```

不要在下一步立即删除数据库。先让 wiki 稳定承载上下文和状态，再逐步迁移读取逻辑。

## 下一步计划

### 1. WikiLintAgent

新增 `WikiLintAgent`，每个阶段结束后检查：

- 用户确认约束是否被后续内容覆盖。
- 人物身份和关系是否漂移。
- 周瑞等配角的剧情作用是否持续存在。
- 时长单位和总时长是否一致。
- 场景、道具、视觉锚点是否被遗漏或替换。
- 分镜和视频提示词是否引用了正确角色、道具、场景。

如果 lint 失败：

- 写入 `wiki/open_questions.md` 或 `wiki/decisions.md`。
- UI 暂停当前流程。
- 让用户确认、补充或允许自动修复。

### 2. 细粒度页面拆分

当前先使用聚合页面。稳定后拆成：

```text
wiki/characters/<name>.md
wiki/locations/<name>.md
wiki/props/<name>.md
wiki/scenes/scene-001.md
wiki/shots/shot-001-001.md
wiki/visual_continuity.md
```

拆分后 `ContextCompiler` 应只读取当前阶段和当前镜头相关页面，避免 token 过大。

### 3. UI Wiki 视图

项目详情页增加 wiki 入口：

- 查看 `story_bible.md`
- 查看角色/场景/道具
- 查看分镜和视频提示词包
- 查看 log
- 对关键页面发起用户修订

### 4. Wiki Patch 写入机制

未来 Agent 不应自由覆盖 Markdown 文件，而应输出结构化 patch：

```json
{
  "page": "wiki/story_bible.md",
  "operation": "replace_section",
  "section": "Visual Anchors",
  "content": "..."
}
```

这样可以审计、回滚、避免误删用户确认信息。

### 5. 数据库降级

当 wiki 能稳定恢复项目状态后，再逐步让数据库只保留：

- 项目列表索引
- 阶段状态
- 后台任务队列
- 输出文件索引

最终可考虑从 wiki 重建数据库缓存。

## 开发注意事项

- 新增阶段产物时，必须同时考虑是否需要写入 wiki。
- 新增 Agent 调用 LLM 时，必须考虑是否需要注入 `creative_memory`。
- 不要让 LLM 改写 `raw/creative_input.md` 和 `raw/user_answers.md`。
- 用户答案和用户确认约束优先级最高。
- 如果 wiki 与数据库冲突，短期以数据库保证 UI 兼容，但应记录到 `wiki/log.md`，长期迁移到 wiki 优先。
