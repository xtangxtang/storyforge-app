# Storyforge

Storyforge 是一个 **LLM-native 短视频生成工作区**。

它不再是 Flutter 桌面应用，而是围绕 skill、项目文件和可审阅阶段产物构建。目标是：给定一个剧本，LLM 可以按阶段调用 skill，设计角色/场景视觉锚点，生成分镜、原子镜头、关键帧，并通过 Ark Seedance 生成视频片段。

```text
script -> assets -> storyboards -> atomic shots -> keyframe plan -> Codex images -> Ark videos
```

## 快速开始

复制配置模板：

```bash
cp config.local.example.json config.local.json
```

填写 `llmApiKey` 和 `arkApiKey` 后，查看可用 skill：

```bash
python -m storyforge.cli list-skills
```

从已有剧本开始：

```bash
python -m storyforge.cli --project demo pipeline-from-script --script path/to/script.md
```

这个命令会运行到 `keyframe_plan`，产出给 Codex 生成图片用的首帧/尾帧任务清单，先停在真实图片/视频生成前，方便人工或 LLM 审阅。

当 Codex 生成的图片已经放到计划指定的 `keyframes/` 路径后，继续导入关键帧并生成视频：

```bash
python -m storyforge.cli --project demo pipeline-from-script --script path/to/script.md --with-media
```

也可以单独运行某个 skill：

```bash
python -m storyforge.cli --project demo run storyboard_plan
```

传入 JSON：

```bash
python -m storyforge.cli --project demo run script_ingest --input-json "{\"script_text\":\"第一场：清晨，校门外。\"}"
```

## 项目工作区

每个项目保存在：

```text
projects/<project-id>/
  raw/
  wiki/
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

- `stages/*.json`：机器可读阶段产物。
- `review/*.md`：给用户或 LLM 审阅修改的阶段摘要。
- `assets/`：可选的角色、地点、道具视觉锚点图。
- `keyframes/`：每个原子镜头的首帧/尾帧。
- `clips/`：Ark 图生视频生成的片段。
- `manifest.json`：skill 运行历史。

## 默认 Skill

Skill 契约位于 `storyforge_skills/*/SKILL.md`。

- `script_ingest`：接收已有剧本，规范化场景、角色、地点、道具。
- `asset_design`：设计角色、地点、道具的视觉锚点提示词。
- `storyboard_plan`：生成分镜计划。
- `atomic_shot_plan`：把分镜拆成物理逻辑更稳定的原子镜头。
- `keyframe_plan`：为 Codex 图片生成准备首帧/尾帧任务清单。
- `keyframe_import`：导入 Codex 已生成的本地关键帧图片。
- `keyframe_generate_ark`：可选备用路径，通过 Ark 生成关键帧图片。
- `video_generate_ark`：使用 Ark Seedance 生成视频片段。
- `knowledge_capture`：把用户认可的分镜、原子镜头、提示词或风格提炼成可复用知识卡。

## 自我增长知识库

当某个分镜、动作拆解、镜头风格或提示词效果不错时，可以把它沉淀为知识卡：

```bash
python -m storyforge.cli --project demo run knowledge_capture --input-json "{\"source_stage\":\"storyboards\",\"item_id\":\"sb_001\",\"scope\":\"both\",\"tags\":[\"campus\",\"collision\",\"soft-comedy\"],\"user_note\":\"这个校园相撞开场的节奏、方向和切镜方式后续可复用。\"}"
```

知识卡会写入：

```text
projects/<project-id>/wiki/cards/   # 项目级知识
knowledge/cards/                    # 全局可复用知识
```

后续 `asset_design`、`storyboard_plan`、`atomic_shot_plan` 会通过 `context_pack()` 自动读取这些知识。也就是说，好的结果可以变成之后生成时的本地经验。

## 连续性策略

Storyforge 不再默认给每个分镜生成随机九宫格。九宫格容易变成同一个提示词下的随机变体，角色、服装、方向和动作连续性都不稳定。

现在的默认策略是：

- 先把复杂动作拆成短的原子镜头；
- 每个原子镜头明确开始状态和结束状态；
- 通过角色/地点视觉锚点提示词保持身份一致；
- 通过 Codex 生成的首帧/尾帧控制图约束图生视频；
- 对碰撞、急刹、转向等困难动作使用切镜、反应镜头或特写来保持物理可信；
- 只在确实需要探索构图时生成多候选图。

## 配置

本地配置读取顺序：

1. `config.local.json`
2. `~/.storyforge/config.local.json`
3. 环境变量

可用字段见 `config.local.example.json`。
