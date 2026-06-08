# CLAUDE.md

Storyforge 现在是 **LLM-native 短视频生成工作区**，不是 Flutter/Dart 桌面 App。

## 核心模型

```text
剧本文档 -> 文档导入 -> 风格选择 -> skill 编排 -> stage/review 文件 -> 视觉锚点 -> 关键帧 -> Ark 图生视频
```

项目状态保存在 `projects/<project-id>/`。LLM、CLI 或人工操作者都可以直接调用 skill，并在每个阶段审阅和修改产物。

## 常用命令

```bash
python -m compileall storyforge
python -m storyforge.cli list-skills
python -m storyforge.cli --project demo pipeline-from-script --script path/to/script.md
python -m storyforge.cli --project demo pipeline-from-script --script path/to/script.md --with-media
```

## 重要目录

- `storyforge/`：Python 运行时代码。
- `storyforge_skills/*/SKILL.md`：skill 契约。
- `projects/<project-id>/`：运行时项目工作区，默认不提交。
- `generated/`：历史/实验生成产物，可参考但不是新架构源状态。
- `config.local.example.json`：本地密钥模板。

## 默认 Skill

- `script_ingest`
- `document_ingest`
- `style_select`
- `asset_design`
- `storyboard_plan`
- `atomic_shot_plan`
- `keyframe_plan`
- `keyframe_import`
- `keyframe_generate_ark`
- `video_generate_ark`
- `knowledge_capture`

新增能力优先新增 skill，而不是新增 App screen 或 Dart service。

`style_select` 必须在 `script_ingest` 后运行，用于询问并记录电影风格、短剧风格、漫剧风格、动画番剧风格、纪实风格或自定义风格。后续所有创作 prompt 必须遵守 `wiki/style.md` 和 `stages/00_style.json`。

通过 `pipeline-from-document` 提交 `.txt`、`.md`、`.docx`、`.pdf` 时，如果没有显式传 `--project`，系统应从文档标题/内容自动派生项目 ID，并在独立 `projects/<project-id>/` 目录中运行。

当用户确认某个分镜、动作拆分、提示词或风格值得复用时，优先调用 `knowledge_capture`，把它写入项目级 `wiki/cards/` 或全局 `knowledge/cards/`。只有当知识卡变成稳定流程时，再升级成新的 skill。

## Stage Review

每个 stage 成功产出后，`SkillRunner` 会先调用 `stage_review_agent`，再生成给用户看的审阅材料包：

```text
review/agent_<skill_id>.md
review/user_<skill_id>.md
```

新增 skill 时应在 `SkillResult.data` 中返回主要 stage 文件路径 `file`，让审阅 agent 能读取正确材料。

## 约定

- 用中文与用户沟通。
- 不恢复 Flutter/Dart 文件，除非用户明确要求。
- 不提交 `config.local.json`、`projects/`、媒体产物或缓存。
- 分镜连续性依赖原子镜头、首尾关键帧、角色/地点锚点和前后镜头上下文，不依赖随机九宫格。
