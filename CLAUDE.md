# CLAUDE.md

Storyforge 现在是 **LLM-native 短视频生成工作区**，不是 Flutter/Dart 桌面 App。

## 核心模型

```text
已有剧本 -> skill 编排 -> stage/review 文件 -> 视觉锚点 -> 关键帧 -> Ark 图生视频
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
- `asset_design`
- `storyboard_plan`
- `atomic_shot_plan`
- `keyframe_generate`
- `video_generate_ark`

新增能力优先新增 skill，而不是新增 App screen 或 Dart service。

## 约定

- 用中文与用户沟通。
- 不恢复 Flutter/Dart 文件，除非用户明确要求。
- 不提交 `config.local.json`、`projects/`、媒体产物或缓存。
- 分镜连续性依赖原子镜头、首尾关键帧、角色/地点锚点和前后镜头上下文，不依赖随机九宫格。
