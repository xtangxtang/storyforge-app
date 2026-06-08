# Storyforge LLM-Native Architecture

Storyforge 的中心不再是 App，而是一个可以被 LLM 直接操作的项目工作区。

```text
project workspace + skill contract -> skill runner -> reviewable outputs
```

## 设计目标

- 给定一个已有剧本，可以从头推进到视频片段。
- 每个阶段都产出可审阅、可修改、可恢复的文件。
- LLM 可以直接调用 skill，不需要点击 UI。
- 角色、地点、动作连续性通过结构化状态和关键帧控制，而不是靠随机多图猜测。
- 图片生成默认由 Codex 在对话环境中完成；视频生成暂时只走 Ark Seedance。

## 运行时模块

| 模块 | 责任 |
| --- | --- |
| `storyforge.cli` | 命令行入口，负责项目选择、skill 调用和 pipeline 快捷命令 |
| `storyforge.config` | 从本地 JSON 或环境变量读取 LLM/Ark 配置 |
| `storyforge.workspace` | 创建项目目录、读写 stage、记录 manifest、编译上下文 |
| `storyforge.skills` | Skill 协议、SkillRunner、review markdown 写入 |
| `storyforge.default_skills` | 默认视频生产 skill 实现 |
| `storyforge.services` | OpenAI-compatible LLM client 与 Ark media client |

## 项目工作区

```text
projects/<project-id>/
  raw/
    script.md
  wiki/
    cards/
  stages/
    01_script.json
    02_assets.json
    03_storyboards.json
    04_atomic_shots.json
    05_keyframe_plan.json
    05_keyframes.json
    06_videos.json
  assets/
  keyframes/
  clips/
  review/
  archive/
  manifest.json
```

`stages/*.json` 是后续 skill 的正式输入；`review/*.md` 是人工确认和 LLM 复核入口；`manifest.json` 记录每次 skill 运行，便于追踪和恢复。

每个 stage 成功产出后，`SkillRunner` 会自动生成两类审阅文件：

```text
review/agent_<skill_id>.md
review/user_<skill_id>.md
```

`agent_<skill_id>.md` 是 `stage_review_agent` 的先行审阅，检查故事保真、连续性、物理逻辑、字段完整性、下一阶段可用性和可沉淀知识。

`user_<skill_id>.md` 是交给用户审阅的材料包，包含 agent 结论、用户重点检查项、修改请求、风险和 stage 原文。

全局知识库位于仓库根目录：

```text
knowledge/
  README.md
  cards/
```

项目级知识适合当前故事的角色、地点和连续性；全局知识适合可跨项目复用的镜头风格、动作拆解方法、提示词模式和反例。

## Skill 契约

每个 skill 至少包含两层契约：

- Python 实现：注册在 `storyforge.default_skills.default_registry()`。
- 文档契约：位于 `storyforge_skills/<skill_id>/SKILL.md`。

默认 skill：

- `script_ingest`
- `asset_design`
- `storyboard_plan`
- `atomic_shot_plan`
- `keyframe_plan`
- `keyframe_import`
- `keyframe_generate_ark`
- `video_generate_ark`
- `knowledge_capture`

新增 skill 时应明确：

- 输入字段；
- 读取哪些 stage；
- 输出哪些 stage/review/assets；
- 是否会调用 LLM 或媒体生成；
- 用户应该在哪个节点确认或修改。

## Pipeline

默认无媒体生成路径：

```text
script_ingest -> asset_design -> storyboard_plan -> atomic_shot_plan -> keyframe_plan
```

Codex 图片生成路径：

```text
script_ingest -> asset_design -> storyboard_plan -> atomic_shot_plan -> keyframe_plan -> Codex image generation -> keyframe_import -> video_generate_ark
```

`keyframe_generate_ark` 是备用路径，只在用户明确要求 Ark 自动生成图片时使用。

知识增长路径：

```text
approved stage/review/user note -> knowledge_capture -> wiki/cards + knowledge/cards -> future context_pack
```

当用户确认“这个分镜不错”时，可以调用：

```bash
python -m storyforge.cli --project demo run knowledge_capture --input-json "{\"source_stage\":\"storyboards\",\"item_id\":\"sb_001\",\"scope\":\"both\",\"tags\":[\"campus\",\"collision\"]}"
```

之后 `context_pack()` 会自动检索项目级和全局知识卡，并把相关内容注入后续 LLM 调用。

## 审阅与确认

Storyforge 的 stage 不应该直接“静默进入下一步”。每个 stage 的可审阅材料分三层：

- `stages/*.json`：机器可读产物。
- `review/agent_<skill_id>.md`：agent 先行审阅。
- `review/user_<skill_id>.md`：用户确认材料包。

CLI 批量 pipeline 会为每个 stage 留下这些文件；更严格的人工确认流程应逐个运行 skill，用户确认 `user_<skill_id>.md` 后再运行下一步。

## 连续性策略

旧的“每个分镜九宫格”会造成三类问题：

- 多张图是随机候选，不是同一动作的连续状态；
- 角色衣服、方向、位置容易漂移；
- 图生视频拿到不一致参考时反而更难稳定。

新的默认策略：

- `storyboard_plan` 只负责叙事和镜头节奏；
- `atomic_shot_plan` 把复杂动作拆成短镜头，并写清开始/结束状态；
- `asset_design` 只设计角色、地点、道具的视觉锚点提示词；
- `keyframe_plan` 为每个原子镜头规划首帧和尾帧任务；
- Codex 在对话环境中生成图片，并把图片放到计划指定路径；
- `keyframe_import` 把本地图片登记为 `stages/05_keyframes.json`；
- `video_generate_ark` 用首帧驱动视频，并在可用时传入前序片段作为参考；
- 碰撞、急刹、转向、遮挡等困难动作优先切成多个短镜头。

## 本地配置

配置读取顺序：

1. `config.local.json`
2. `~/.storyforge/config.local.json`
3. 环境变量

主要字段：

- `llmBaseUrl`
- `llmApiKey`
- `llmModel`
- `arkBaseUrl`
- `arkApiKey`
- `arkImageModel`
- `arkVideoModel`
- `httpsProxy`
