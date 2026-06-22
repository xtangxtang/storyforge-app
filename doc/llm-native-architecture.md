# Storyforge LLM-Native Architecture

Storyforge 的中心不再是 App，而是一个可以被 LLM 直接操作的项目工作区。

```text
project workspace + skill contract -> skill runner -> reviewable outputs
```

## 设计目标

- 给定一个已有剧本文档，可以从头推进到视频片段。
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
    source/
    script.md
  wiki/
    style.md
    cards/
  stages/
    00_document.json
    00_style.json
    00a_director_style.json
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

视觉生产阶段还会自动生成 `review/director_<skill_id>.md`。它来自 `director_guard_agent`，属于导演守门审查，按“整体布局 -> 大场景调度 -> 分镜/原子镜头”的顺序检查叙事重心、机位覆盖、人物调度、景别组合、镜头运动、剪辑节奏、表演动机和生成可执行性。

视觉生产阶段还会自动生成 `review/continuity_<skill_id>.md`。它来自 `continuity_guard_agent`，属于轻量一致性守门审查，固定检查人物身份/服装、道具归属、地点结构、光线方向、轴线、运动方向、动作物理、跨场景状态和生成可控性。

`director_guard_agent` 不替代 `stage_review_agent`：前者专注导演执行与镜头调度，后者负责通用 stage 质量审阅。

`continuity_guard_agent` 不替代 `continuity_validator`：前者负责每个 stage 后即时提醒，后者负责关键帧计划前的正式连续性总审。

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
- `document_ingest`
- `style_select`
- `director_style_select`
- `asset_design`
- `asset_canon_plan`
- `asset_canon_generate_ark`
- `visual_consistency_review`
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
document_ingest -> script_ingest -> style_select -> director_style_select -> asset_design -> storyboard_plan -> atomic_shot_plan -> keyframe_plan
```

Codex 图片生成路径：

```text
document_ingest -> script_ingest -> style_select -> director_style_select -> asset_design -> storyboard_plan -> atomic_shot_plan -> keyframe_plan -> Codex image generation -> keyframe_import -> video_generate_ark
```

`keyframe_generate_ark` 是备用路径，只在用户明确要求 Ark 自动生成图片时使用。

## 文档导入与项目创建

`document_ingest` 支持 `.txt`、`.md`、`.docx`、`.pdf`，会把原始文件复制到 `raw/source/`，把抽取文本写入 `raw/script.md`，并记录 `stages/00_document.json`。

通过 CLI 运行：

```bash
python -m storyforge.cli pipeline-from-document --document path/to/script.docx
```

如果没有传 `--project`，CLI 会从文档标题/内容自动派生项目 ID，并在独立目录中运行：

```text
projects/<auto-project-id>/
```

旧 `.doc` 二进制文件不直接支持，需要先转换成 `.docx` 或 `.pdf`。

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
- `review/director_<skill_id>.md`：视觉阶段的导演守门审查。
- `review/continuity_<skill_id>.md`：视觉阶段的一致性守门审查。
- `review/user_<skill_id>.md`：用户确认材料包。

CLI 批量 pipeline 会为每个 stage 留下这些文件；更严格的人工确认流程应逐个运行 skill，用户确认 `user_<skill_id>.md` 后再运行下一步。

## Change Propagation

`change_propagator` 用来处理用户在中途修改创作材料后的同步问题。它读取当前项目 workspace、stage dependency graph、recent decisions、wiki 风格/导演/连续性上下文，并输出：

```text
stages/10_change_propagator.json
review/10_change_propagator.md
archive/change_propagator/<timestamp>/<stage>.json
```

推荐流程：

1. 用户提出修改，例如“把 S1-02 的自行车方向锁定为朝学校大门内侧”。
2. 先运行 `change_propagator` 的计划模式：

```bash
python -m storyforge.cli --project <project-id> run change_propagator --input-json "{\"changed_stage\":\"03_storyboards.json\",\"item_id\":\"S1-02\",\"change_request\":\"把自行车方向锁定为朝学校大门内侧\",\"apply\":false}"
```

3. 用户确认计划后，再运行应用模式：

```bash
python -m storyforge.cli --project <project-id> run change_propagator --input-json "{\"changed_stage\":\"03_storyboards.json\",\"item_id\":\"S1-02\",\"change_request\":\"把自行车方向锁定为朝学校大门内侧\",\"apply\":true}"
```

4. 应用后读取 `review/10_change_propagator.md`，确认它改了哪些 stage、备份在哪里、哪些下游需要重跑或复查。

它只改写机器可读 stage，不直接改写生成媒体结果。`05_keyframes.json`、`06_videos.json`、`00d_scene_references.json` 和 `06b_scene_transitions.json` 只会被列为重跑或复查对象。

半自动修改入口是 `apply_change` / CLI `apply-change`：

```text
apply-change command -> apply_change skill -> change_propagator -> report + optional stage writes
```

默认不带 `--apply` 时只生成计划；带 `--apply` 时才写 stage。这样可以把“用户提出修改”和“同步前后阶段”收束到一个入口，避免 agent 手工散改多个文件后遗漏报告。

## 风格选择

`style_select` 是剧本之后的强制确认点。没有风格输入时，它会写出风格选择提示并暂停 pipeline；有风格输入时，它会写入：

```text
stages/00_style.json
wiki/style.md
```

内置风格包括：

- `film`
- `short_drama`
- `comic_drama`
- `anime`
- `documentary`

后续 `asset_design`、`storyboard_plan`、`atomic_shot_plan`、`keyframe_plan`、`keyframe_generate_ark` 和 `video_generate_ark` 都必须通过 `context_pack()` 或显式 style context 遵守该风格。更换风格后应重跑后续创作 stage。

## 导演语言选择

`director_style_select` 是生产风格后的第二层风格确认点。它会写入：

```text
stages/00a_director_style.json
wiki/director_style.md
```

内置导演语言/流派风格包括：
- `japanese_healing`
- `youth_campus_realism`
- `sports_hotblood_realism`
- `urban_lyrical_restraint`
- `eastern_color_ensemble`

后续视觉 stage 必须同时遵守 `style_select` 的生产类型和 `director_style_select` 的导演语言。更换导演语言后，应重跑或复查后续创作 stage。

## 连续性策略

旧的“每个分镜九宫格”会造成三类问题：

- 多张图是随机候选，不是同一动作的连续状态；
- 角色衣服、方向、位置容易漂移；
- 图生视频拿到不一致参考时反而更难稳定。

新的默认策略：

- `storyboard_plan` 只负责叙事和镜头节奏；
- `atomic_shot_plan` 把复杂动作拆成短镜头，并写清开始/结束状态；
- `asset_design` 只设计角色、地点、道具的视觉锚点提示词；
- `asset_canon_plan` / `asset_canon_generate_ark` 把校服、大门、复用道具各锁成一张项目级 canon 基准图，作为全片唯一外观图源；
- `scene_reference_generate_ark` 强制把对应 canon（角色/道具显式 `canon_refs` + 按 `scene.location` 自动匹配的地点 canon）和同场景 master plate 作为 reference image 喂入，缺底图即报错、拒绝纯文字生成，避免大门/校服各自重新发明；
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
