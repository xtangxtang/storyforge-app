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
- 视频生成暂时只走 Ark Seedance；DashScope/Seedance Web 不作为默认路径。

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
  stages/
    01_script.json
    02_assets.json
    03_storyboards.json
    04_atomic_shots.json
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

## Skill 契约

每个 skill 至少包含两层契约：

- Python 实现：注册在 `storyforge.default_skills.default_registry()`。
- 文档契约：位于 `storyforge_skills/<skill_id>/SKILL.md`。

默认 skill：

- `script_ingest`
- `asset_design`
- `storyboard_plan`
- `atomic_shot_plan`
- `keyframe_generate`
- `video_generate_ark`

新增 skill 时应明确：

- 输入字段；
- 读取哪些 stage；
- 输出哪些 stage/review/assets；
- 是否会调用 LLM 或媒体生成；
- 用户应该在哪个节点确认或修改。

## Pipeline

默认无媒体生成路径：

```text
script_ingest -> asset_design -> storyboard_plan -> atomic_shot_plan
```

带媒体生成路径：

```text
script_ingest -> asset_design -> storyboard_plan -> atomic_shot_plan -> keyframe_generate -> video_generate_ark
```

## 连续性策略

旧的“每个分镜九宫格”会造成三类问题：

- 多张图是随机候选，不是同一动作的连续状态；
- 角色衣服、方向、位置容易漂移；
- 图生视频拿到不一致参考时反而更难稳定。

新的默认策略：

- `storyboard_plan` 只负责叙事和镜头节奏；
- `atomic_shot_plan` 把复杂动作拆成短镜头，并写清开始/结束状态；
- `asset_design` 只设计角色、地点、道具的视觉锚点提示词；
- `keyframe_generate` 为每个原子镜头生成首帧和尾帧；
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
