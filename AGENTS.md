# AGENTS.md

本文件给 Codex / LLM agent 在本仓库中工作时使用。

## 项目定位

Storyforge 已转为 **LLM-native 短视频生成工作区**。它不再以 Flutter App 为中心，也不再依赖 Dart、SQLite 或桌面 UI 来编排流程。

当前核心模型是：

```text
剧本文档 -> 文档导入 -> 风格选择 -> 场景制作包 -> skill -> 可审阅 stage 文件 -> 视觉锚点 -> 关键帧 -> Ark 图生视频
```

LLM、人工操作者或 CLI 都可以直接调用 skill。项目状态以文件形式保存在 `projects/<project-id>/` 下，便于暂停、审阅、修改和继续。

## 常用命令

```bash
python -m compileall storyforge
python -m storyforge.cli list-skills
python -m storyforge.cli pipeline-from-document --document path/to/script.docx
python -m storyforge.cli --project demo advise-rerun --changed-stage 03_storyboards.json --scene-id SCENE_001
python -m storyforge.cli --project demo review-decision --skill-id storyboard_plan --decision approve
python -m storyforge.cli --project demo run script_ingest --input-json "{\"script_path\":\"script.md\"}"
python -m storyforge.cli --project demo pipeline-from-script --script path/to/script.md
python -m storyforge.cli --project demo pipeline-from-script --script path/to/script.md --with-media
```

如果以包方式安装：

```bash
pip install -e .
storyforge list-skills
```

## 目录结构

| 路径 | 用途 |
| --- | --- |
| `storyforge/` | Python 运行时代码：CLI、配置、workspace、skill runner、外部服务客户端 |
| `storyforge_skills/*/SKILL.md` | 每个 skill 的人类/LLM 可读契约 |
| `projects/<project-id>/` | 运行时项目工作区，默认不提交 |
| `generated/` | 早期/实验生成产物，可作为参考素材，不是新架构源代码 |
| `doc/` | 架构与操作文档 |
| `config.local.example.json` | 本地密钥配置模板 |
| `config.local.json` | 本地密钥，必须保持未提交 |

## 默认 Skill

- `document_ingest`：把 `.txt`、`.md`、`.docx`、`.pdf` 剧本文档抽取成 `raw/script.md`。
- `script_ingest`：接收已有剧本，规范化场景、角色、地点、道具。
- `style_select`：剧本进入后立刻询问电影/短剧/漫剧/动画/纪实等生产风格，并写入风格档案。
- `consistency_bible`：锁定全片共享的校服、配色、地点布局、复用道具和世界规则。
- `scene_bible`：为每个大场景建立共享的空间、光线、轴线、人物状态、道具状态、物理规则和参考图计划。
- `scene_reference_plan`：把场景制作包编译成可生成的场地总览、机位参考和道具摆放参考图任务。
- `scene_reference_import`：导入 Codex 已生成的本地场景参考图。
- `scene_reference_generate_ark`：可选备用路径，通过 Ark 生成场景参考图。
- `cross_scene_continuity`：建立跨大场景的人物、道具、服装、情绪、物理状态和剧情接力规则。
- `asset_design`：设计角色、地点、道具的视觉锚点提示词。
- `storyboard_plan`：按剧本规划分镜，不直接生成九宫格。
- `atomic_shot_plan`：把复杂动作拆成物理上更可信的原子镜头。
- `continuity_validator`：在关键帧计划前检查场景连续性、轴线方向、道具状态和物理逻辑。
- `keyframe_plan`：为 Codex 图片生成准备首帧/尾帧任务清单。
- `keyframe_import`：导入 Codex 已生成的本地关键帧图片。
- `keyframe_generate_ark`：可选备用路径，通过 Ark 生成关键帧图片。
- `video_generate_ark`：使用 Ark Seedance 从关键帧生成视频片段。
- `scene_transition_plan`：根据上一大场景视频和下一大场景参考图，规划大场景之间的连贯转场参考视频。
- `scene_transition_generate_ark`：可选备用路径，通过 Ark 生成大场景转场参考视频。
- `stage_rerun_advisor`：用户修改某个 stage 或大场景后，提示后续哪些阶段需要重跑或复查。
- `review_decision`：记录用户对 stage 的 approve/revise/block 决策，并把修改意见和重跑建议写入 review/decisions。
- `knowledge_capture`：把用户认可的分镜、动作拆解、提示词或风格提炼成项目级/全局知识卡。

新增能力时优先新增一个 skill，并在 `storyforge_skills/<skill_id>/SKILL.md` 写清输入、输出、约束和人工确认点。

## 工作区契约

每个项目默认保存为：

```text
projects/<project-id>/
  raw/
    source/
  wiki/
    cards/
  stages/
    00_document.json
    00_style.json
    00b_consistency.json
    00c_scene_bible.json
    00d_scene_reference_plan.json
    00d_scene_references.json
    00e_cross_scene_continuity.json
    01_script.json
    02_assets.json
    03_storyboards.json
    04_atomic_shots.json
    04b_continuity_validation.json
    05_keyframe_plan.json
    05_keyframes.json
    06_videos.json
    06b_scene_transition_plan.json
    06b_scene_transitions.json
    08_stage_rerun_advisor.json
  assets/
    scene_refs/
  keyframes/
  clips/
  review/
    index.json
    index.md
    decisions.json
  archive/
  manifest.json
```

`stages/*.json` 是机器可读的阶段产物；`review/*.md` 是给用户或 LLM 审阅修改的摘要；`manifest.json` 记录 skill 运行历史。

`review/index.json` 和 `review/index.md` 是 agent-native 审阅入口。每次 skill 运行后由 `SkillRunner` 自动刷新，包含当前 stage、最近运行、待用户审阅材料、stage 文件、媒体文件、下一步建议和常用命令。Codex/Claude Code 或未来轻量 Review Console 都应优先读取该索引，而不是自行遍历整个项目目录。

`review/decisions.json` 和 `wiki/decisions.md` 记录用户审阅决策。用户确认或要求修改某个 stage 后，应调用 `review_decision`；它会记录 approve/revise/block、scene_id、item_id、修改意见，并在需要时附带后续重跑建议。后续 agent 必须优先尊重这些决策。

全局可复用知识放在仓库根目录的 `knowledge/cards/`。当用户确认某个分镜、镜头语言、动作拆分或提示词很好时，先调用 `knowledge_capture` 沉淀成知识卡；只有当这个模式需要稳定执行步骤时，才升级成新的 skill。

`style_select` 是 `script_ingest` 之后的强制确认点。后续所有视觉锚点、场景制作包、分镜、原子镜头、关键帧 prompt、视频 prompt 都必须读取 `wiki/style.md` 和 `stages/00_style.json`，并按所选风格构建。更换风格后应重跑后续创作 stage。

`scene_bible` 是大场景连续性的强制基础层。`storyboard_plan`、`atomic_shot_plan`、`keyframe_plan`、`keyframe_generate_ark` 和 `video_generate_ark` 必须读取 `wiki/scene_bible.md` 与 `stages/00c_scene_bible.json`，继承同一场景的空间地图、光线方向、轴线、人物状态、道具状态和物理规则。一个大场景的多个分镜不得各自发明地点结构、角色站位、道具朝向或运动方向。

`scene_reference_plan` 默认跟随 `scene_bible` 运行，产出场地总览、主要机位和道具摆放参考图任务。后续 `keyframe_plan` 应按 `scene_id` 引用 `stages/00d_scene_references.json` 中的同场景参考图；如果还没有图片，也要保留 `scene_reference_ids` 和目标路径，方便 Codex 或 Ark 先补齐场景参考图。

`cross_scene_continuity` 默认跟随 `scene_reference_plan` 运行，产出跨大场景的人物/道具/状态接力表。后续所有视觉阶段必须读取 `wiki/cross_scene_continuity.md` 和 `stages/00e_cross_scene_continuity.json`，保持角色服装、携带物、道具归属、道具损坏/丢失/转移、身体/情绪状态在大场景之间合理承接。除非剧本给出时间跳转或明确原因，不得让这些状态无解释重置。

如果用户通过 `pipeline-from-document` 提交剧本文档且没有显式传 `--project`，Storyforge 应根据文档标题/内容自动生成项目 ID，并在 `projects/<project-id>/` 中运行完整流程。不要把多个剧本默认混进同一个 `default` 项目。

## Stage Review Rule

每个 stage 成功产出后，必须先由 `stage_review_agent` 审阅，再交给用户审阅。通用流程由 `SkillRunner` 执行：

```text
skill output -> review/agent_<skill_id>.md -> review/user_<skill_id>.md
```

- `agent_<skill_id>.md`：agent 的先行审阅，包含分数、结论、风险、连续性检查和修改建议。
- `user_<skill_id>.md`：交给用户确认的材料包，包含 agent 结论、用户重点检查项、修改请求和 stage 原文。
- 新增 skill 时返回的 `SkillResult.data` 应包含 `file`，指向主要 stage 产物，这样审阅 agent 能读到正确材料。
- 只有在明确需要跳过时才允许传 `skip_agent_review: true`。
- 每个阶段产出后都默认停在用户审阅门；只有显式 `--auto-continue` 或 `auto_continue_after_review` 才继续。
- 用户修改任意 stage、review 材料或大场景设定后，应运行 `stage_rerun_advisor`，由它提示后续哪些阶段需要重跑或复查。

## 连续性原则

不要把一个动作简单拆成多张互不关联的图来赌视频会连贯。默认策略是：

- 每个分镜先拆成原子镜头；
- 每个大场景先生成 `scene_bible`，锁定空间、光线、轴线、人物/道具状态和物理规则；
- 每个大场景再生成或导入 `scene_reference`，把场地总览、机位和道具摆放变成图片锚点；
- 多个大场景之间生成 `cross_scene_continuity`，锁定人物/道具/服装/身体情绪状态的接力规则；
- 每个分镜写清 `scene_id`、`coverage_role` 和 `scene_bible_refs`；
- 每个原子镜头写清结构化的 `continuity_state_start` 和 `continuity_state_end`；
- 进入关键帧前运行 `continuity_validator`，检查方向反转、地点冲突、道具跳变和物理不可信问题；
- 用首帧/尾帧控制图约束图生视频；
- 大场景之间先运行 `scene_transition_plan`，用上一大场景最后一个视频和下一场景参考图规划连贯转场参考；
- 对碰撞、转身、突然加速等困难动作使用切镜或反应镜头；
- 生成后把前一段视频、角色视觉锚点提示词和地点锚点提示词作为后续参考。

## 开发约定

- 永远用中文回复用户。
- 这是 Python 项目，不要恢复 Flutter/Dart 入口，除非用户明确要求重新做 App。
- 不要提交 `config.local.json`、`projects/`、大体积生成媒体或缓存文件。
- 读写 stage 文件优先使用 `ProjectWorkspace`。
- 调用 LLM 或媒体服务前，尽量从 workspace 读取已有上下文，避免每个阶段孤立生成。
- 旧的 `generated/` 内容可以参考，但新流程的源状态应落在 `projects/<project-id>/`。
