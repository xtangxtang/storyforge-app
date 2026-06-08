# Storyforge

Storyforge 是一个 **LLM-native 短视频生成工作区**。

它不再是 Flutter 桌面应用，而是围绕 skill、项目文件和可审阅阶段产物构建。目标是：给定一个剧本，LLM 可以按阶段调用 skill，设计角色/场景视觉锚点，生成分镜、原子镜头、关键帧任务，并通过 Ark Seedance 生成视频片段。

```text
script -> style -> assets -> storyboards -> atomic shots -> keyframe plan -> Codex images -> Ark videos
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

从已有剧本文档开始：

```bash
python -m storyforge.cli pipeline-from-document --document path/to/script.docx
```

支持 `.txt`、`.md`、`.docx`、`.pdf`。如果没有传 `--project`，Storyforge 会根据剧本文档标题/内容自动生成项目 ID，并把所有产物放在：

```text
projects/<auto-project-id>/
```

这个命令会先运行 `document_ingest`，再进入后续流程。如果项目还没有选择风格，会停在 `style_select`；选择风格后会继续运行到 `keyframe_plan`，产出给 Codex 生成图片用的首帧/尾帧任务清单。

如果项目还没有选择风格，命令会先停在 `style_select`，在 `review/user_style_select.md` 里给出风格选项。选好后继续：

```bash
python -m storyforge.cli --project demo run style_select --input-json "{\"style\":\"film\"}"
```

也可以在一开始就指定风格：

```bash
python -m storyforge.cli pipeline-from-document --document path/to/script.pdf --style film
```

当 Codex 生成的图片已经放到计划指定的 `keyframes/` 路径后，继续导入关键帧并生成视频：

```bash
python -m storyforge.cli --project demo run keyframe_import
python -m storyforge.cli --project demo run video_generate_ark
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
    00_document.json
    00_style.json
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
- `review/*.md`：阶段摘要和审阅材料。
- `review/agent_<skill>.md`：stage 完成后由审阅 agent 先检查风险、连续性和修改建议。
- `review/user_<skill>.md`：整理给用户最终确认的审阅材料包。
- `assets/`：可选的角色、地点、道具视觉锚点图。
- `keyframes/`：每个原子镜头的首帧/尾帧。
- `clips/`：Ark 图生视频生成的片段。
- `manifest.json`：skill 运行历史。

## Stage 审阅机制

每个 skill 成功产出 stage 后，`SkillRunner` 会自动触发 `stage_review_agent`：

```text
skill output -> agent review -> user review package
```

产物包括：

```text
review/agent_<skill_id>.md
review/user_<skill_id>.md
```

`agent_<skill_id>.md` 是 agent 的先行审阅，包含分数、结论、风险、连续性检查和修改建议。

`user_<skill_id>.md` 是交给你审阅的材料包，包含 agent 结论、你需要重点看的问题、修改请求和 stage 原文。

如果确实只想跑机器阶段、不做审阅，可以传：

```bash
python -m storyforge.cli --project demo run storyboard_plan --input-json "{\"skip_agent_review\":true}"
```

## 默认 Skill

Skill 契约位于 `storyforge_skills/*/SKILL.md`。

- `document_ingest`：把 `.txt`、`.md`、`.docx`、`.pdf` 剧本文档抽取成 `raw/script.md`。
- `script_ingest`：接收已有剧本，规范化场景、角色、地点、道具。
- `style_select`：在剧本进入后立刻询问并记录生产风格。
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

## 风格选择

`style_select` 是剧本之后的强制确认点。内置风格：

- `film`：电影风格
- `short_drama`：短剧风格
- `comic_drama`：漫剧风格
- `anime`：动画番剧风格
- `documentary`：纪实风格

风格会写入：

```text
stages/00_style.json
wiki/style.md
```

后续所有 asset、storyboard、atomic shot、keyframe prompt 和 video prompt 都会通过 `context_pack()` 读取并遵守这个风格。更换风格后，应重新运行后续创作 stage。

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
