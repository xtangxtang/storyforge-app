# Storyforge

Storyforge 是一个 **LLM-native 短视频生成工作区**。

它不再是 Flutter 桌面应用，而是围绕 skill、项目文件和可审阅阶段产物构建。目标是：给定一个剧本，LLM 可以按阶段调用 skill，设计角色/场景视觉锚点，生成分镜、原子镜头、关键帧，并通过 Ark Seedance 生成视频片段。

```text
script -> assets -> storyboards -> atomic shots -> keyframes -> Ark videos
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

这个命令会运行到 `atomic_shot_plan`，先停在图片/视频生成前，方便人工或 LLM 审阅。

确认后继续生成关键帧和视频：

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
- `keyframe_generate`：为原子镜头生成首帧/尾帧。
- `video_generate_ark`：使用 Ark Seedance 生成视频片段。

## 连续性策略

Storyforge 不再默认给每个分镜生成随机九宫格。九宫格容易变成同一个提示词下的随机变体，角色、服装、方向和动作连续性都不稳定。

现在的默认策略是：

- 先把复杂动作拆成短的原子镜头；
- 每个原子镜头明确开始状态和结束状态；
- 通过角色/地点视觉锚点提示词保持身份一致；
- 通过首帧/尾帧控制图约束图生视频；
- 对碰撞、急刹、转向等困难动作使用切镜、反应镜头或特写来保持物理可信；
- 只在确实需要探索构图时生成多候选图。

## 配置

本地配置读取顺序：

1. `config.local.json`
2. `~/.storyforge/config.local.json`
3. 环境变量

可用字段见 `config.local.example.json`。
