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
- `director_style_select`：在生产风格之后选择导演语言/流派风格（如日系治愈、青春校园写实、青春励志校园、运动热血写实），并写入导演语言档案。
- `consistency_bible`：锁定全片共享的校服、配色、地点布局、复用道具和世界规则。
- `scene_bible`：为每个大场景建立共享的空间、光线、轴线、人物状态、道具状态、物理规则和参考图计划。
- `scene_reference_plan`：把场景制作包编译成可生成的场地总览、机位参考和道具摆放参考图任务。
- `scene_reference_import`：导入 Codex 已生成的本地场景参考图。
- `scene_reference_generate_ark`：可选备用路径，通过 Ark 生成场景参考图。
- `cross_scene_continuity`：建立跨大场景的人物、道具、服装、情绪、物理状态和剧情接力规则。
- `asset_design`：设计角色、地点、道具的视觉锚点提示词。
- `asset_canon_plan`：把 `asset_design` 与 Consistency Bible 编译成项目级共用 canon 基准图任务（大门、校服/各角色、复用道具的唯一外观锚点）。
- `asset_canon_generate_ark`：可选备用路径，通过 Ark 生成项目级共用 canon 基准图，作为全片唯一外观锚点。
- `visual_consistency_review`：看图复核。用视觉 LLM 对比新生成图与项目级 canon 底图，抓大门/校服/书包颜色/人物身份的视觉漂移（补守门 agent 看不到图的缺口）。需配置支持视觉模型的端点+key（`llmVisionApiKey`/`llmVisionBaseUrl`），未配置时降级为 needs_human。
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
- `apply_change`：半自动修改入口。用户要求修改人物、场景、分镜、原子镜头或关键帧并同步前后阶段时，优先调用它；它会转调 `change_propagator`，默认先生成计划，传 `apply: true` 后才实际改写并报告变更。
- `change_propagator`：用户修改剧本、人物、场景、分镜、原子镜头或关键帧后，分析前后影响范围；默认只出同步计划，传 `apply: true` 时可同步改写相关 stage，并输出备份路径、改动摘要和后续重跑/复查建议。
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
    00a_director_style.json
    00b_consistency.json
    00c_scene_bible.json
    00d_scene_reference_plan.json
    00d_scene_references.json
    00e_cross_scene_continuity.json
    00f_asset_canon_plan.json
    00f_asset_canon.json
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
    10_change_propagator.json
  assets/
    canon/
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

`style_select` 是 `script_ingest` 之后的强制确认点。后续所有视觉锚点、场景制作包、分镜、原子镜头、关键帧 prompt、视频 prompt 都必须读取 `wiki/style.md` 和 `stages/00_style.json`，并按所选生产风格构建。更换风格后应重跑后续创作 stage。

`director_style_select` 是 `style_select` 之后的强制确认点。它选择导演语言/流派风格，例如日系治愈、青春校园写实、青春励志校园、运动热血写实、都市抒情留白或东方浓彩群像。后续所有视觉 stage、关键帧 prompt、视频 prompt 和 `director_guard_agent` 都必须读取 `wiki/director_style.md` 和 `stages/00a_director_style.json`。导演语言必须落成可执行的光线、机位、场面调度、表演、剪辑和 prompt 规则，而不是只写某个导演名或风格标签。更换导演语言后应重跑或复查后续创作 stage。

`scene_bible` 是大场景连续性的强制基础层。`storyboard_plan`、`atomic_shot_plan`、`keyframe_plan`、`keyframe_generate_ark` 和 `video_generate_ark` 必须读取 `wiki/scene_bible.md` 与 `stages/00c_scene_bible.json`，继承同一场景的空间地图、光线方向、轴线、人物状态、道具状态和物理规则。一个大场景的多个分镜不得各自发明地点结构、角色站位、道具朝向或运动方向。

`asset_canon_plan` / `asset_canon_generate_ark` 是跨场景一致性的项目级强制基础层，必须在 `asset_design` 之后、场景参考图生成之前完成。它为每个复用角色（统一校服）、地点（大门/教室/球馆等固定布局）和复用道具各生成并锁定**一张** canon 基准图，写入 `stages/00f_asset_canon.json` 和 `assets/canon/`。这是修复"每个场景各自发明大门/校服/道具导致漂移"的关键步骤：canon 是全片唯一外观图源，不是文字描述。`scene_reference_generate_ark`、`keyframe_generate_ark`、`video_generate_ark` 必须把对应 canon 作为 reference image 喂入生成；`scene_reference_generate_ark` 在缺必需 canon（显式 `canon_refs` 或按 `scene.location` 自动匹配的地点 canon）或缺同场景 master plate 时，会让该任务报错、拒绝纯文字生成（除非显式 `allow_missing_canon`）。不得只靠 prompt 文字重述校服/大门外观。

`scene_reference_plan` 默认跟随 `scene_bible` 运行，产出每个大场景的共同资产包任务。进入某个大场景的正式分镜、关键帧或图生视频之前，必须先为该 `scene_id` 生成并审阅一整套共同资产包，而不是只生成单张校门或单张角色图。共同资产包至少包含 `location_master_plate`、必要角色背影/canon、`prop_placement_plate`、主要 `camera_angle_plate_*`，以及该场景需要的动作/状态参考图（例如碰撞点、碰撞后状态、赛后状态）。后续 `keyframe_plan` 应按 `scene_id` 引用 `stages/00d_scene_references.json` 中的同场景参考图；如果还没有图片，也要保留 `scene_reference_ids`、`scene_asset_pack_id`、`scene_asset_pack_status` 和目标路径，方便 Codex 或 Ark 先补齐场景参考图。若同一场景的共同资产不一致，应先修复/重生场景资产包，不得继续关键帧。

`cross_scene_continuity` 默认跟随 `scene_reference_plan` 运行，产出跨大场景的人物/道具/状态接力表。后续所有视觉阶段必须读取 `wiki/cross_scene_continuity.md` 和 `stages/00e_cross_scene_continuity.json`，保持角色服装、携带物、道具归属、道具损坏/丢失/转移、身体/情绪状态在大场景之间合理承接。除非剧本给出时间跳转或明确原因，不得让这些状态无解释重置。

如果用户通过 `pipeline-from-document` 提交剧本文档且没有显式传 `--project`，Storyforge 应根据文档标题/内容自动生成项目 ID，并在 `projects/<project-id>/` 中运行完整流程。不要把多个剧本默认混进同一个 `default` 项目。

## Stage Review Rule

每个 stage 成功产出后，必须先由 `stage_review_agent` 审阅，再交给用户审阅。通用流程由 `SkillRunner` 执行：

```text
skill output -> review/agent_<skill_id>.md -> review/user_<skill_id>.md
```

- `agent_<skill_id>.md`：agent 的先行审阅，包含分数、结论、风险、连续性检查和修改建议。
- 对视觉生产阶段，`SkillRunner` 还会自动运行 `director_guard_agent`，额外生成 `review/director_<skill_id>.md`。这是导演守门审查，按“整体布局 -> 大场景调度 -> 分镜/原子镜头”的顺序检查叙事重心、机位覆盖、人物调度、景别组合、镜头运动、剪辑节奏、表演动机和生成可执行性。
- 对视觉生产阶段，`SkillRunner` 还会自动运行 `continuity_guard_agent`，额外生成 `review/continuity_<skill_id>.md`。这是轻量一致性守门审查，固定检查人物身份/服装、道具归属、地点结构、光线方向、轴线、运动方向、动作物理、跨场景状态和生成可控性。
- `director_guard_agent` 不替代 `stage_review_agent`。前者专注导演执行与镜头调度，后者负责通用 stage 质量审阅。
- `continuity_guard_agent` 不替代 `continuity_validator`。前者是每个视觉 stage 后的即时风险提醒；后者是在关键帧计划前的正式连续性总审，可以阻止继续进入后续视觉生成。
- `user_<skill_id>.md`：交给用户确认的材料包，包含 agent 结论、用户重点检查项、修改请求和 stage 原文。
- 新增 skill 时返回的 `SkillResult.data` 应包含 `file`，指向主要 stage 产物，这样审阅 agent 能读到正确材料。
- 只有在明确需要跳过时才允许传 `skip_agent_review: true`。
- 每个阶段产出后都默认停在用户审阅门；只有显式 `--auto-continue` 或 `auto_continue_after_review` 才继续。
- 任一守门（director_guard/continuity_guard/stage_review）verdict 为 `block` 时，`SkillRunner` 置 `guard_blocked` 并强制停在用户审阅门，CLI pipeline 即使带 `--auto-continue` 也会硬停（与 `validation_blocked` 同级）。守门 verdict 不再形同虚设。
- 视觉生成阶段（asset_canon/scene_reference/keyframe/video）后应运行 `visual_consistency_review` 做看图复核：守门 agent 只读文字/JSON、看不到图，像素级一致性（大门/校服/书包颜色）必须靠看图复核或人工确认。
- 用户修改任意 stage、review 材料或大场景设定后，应运行 `stage_rerun_advisor`，由它提示后续哪些阶段需要重跑或复查。
- 如果用户要求“把这个修改同步到前后相关阶段”或“改完后告诉我改了什么”，应运行 `change_propagator`。默认先用 `apply:false` 生成同步计划；只有用户明确确认或当前任务明确要求执行同步时，才用 `apply:true`。它会在改写前备份 stage，并把报告写入 `review/10_change_propagator.md`。
- 半自动修改入口优先使用 `apply_change` 或 CLI `apply-change`，不要让 agent 手工散改多个 stage 后才补报告。推荐流程是：`apply_change apply:false` 生成计划 -> 用户确认 -> `apply_change apply:true` 应用 -> 查看 `review/10_change_propagator.md` -> 根据报告重跑或复查下游阶段。

## 连续性原则

不要把一个动作简单拆成多张互不关联的图来赌视频会连贯。默认策略是：

- 每个分镜先拆成原子镜头；
- 每个大场景先生成 `scene_bible`，锁定空间、光线、轴线、人物/道具状态和物理规则；
- 每个大场景再生成或导入完整 `scene_asset_pack` / `scene_reference`，把场地总览、角色背影、机位、道具摆放和必要动作/状态参考变成图片锚点；
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
