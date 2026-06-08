# AGENTS.md

本文件给 Codex / LLM agent 在本仓库中工作时使用。

## 项目定位

Storyforge 已转为 **LLM-native 短视频生成工作区**。它不再以 Flutter App 为中心，也不再依赖 Dart、SQLite 或桌面 UI 来编排流程。

当前核心模型是：

```text
剧本 -> skill -> 可审阅 stage 文件 -> 视觉锚点 -> 关键帧 -> Ark 图生视频
```

LLM、人工操作者或 CLI 都可以直接调用 skill。项目状态以文件形式保存在 `projects/<project-id>/` 下，便于暂停、审阅、修改和继续。

## 常用命令

```bash
python -m compileall storyforge
python -m storyforge.cli list-skills
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

- `script_ingest`：接收已有剧本，规范化场景、角色、地点、道具。
- `asset_design`：设计角色、地点、道具的视觉锚点提示词。
- `storyboard_plan`：按剧本规划分镜，不直接生成九宫格。
- `atomic_shot_plan`：把复杂动作拆成物理上更可信的原子镜头。
- `keyframe_generate`：为每个原子镜头生成首帧/尾帧控制图。
- `video_generate_ark`：使用 Ark Seedance 从关键帧生成视频片段。
- `knowledge_capture`：把用户认可的分镜、动作拆解、提示词或风格提炼成项目级/全局知识卡。

新增能力时优先新增一个 skill，并在 `storyforge_skills/<skill_id>/SKILL.md` 写清输入、输出、约束和人工确认点。

## 工作区契约

每个项目默认保存为：

```text
projects/<project-id>/
  raw/
  wiki/
    cards/
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

`stages/*.json` 是机器可读的阶段产物；`review/*.md` 是给用户或 LLM 审阅修改的摘要；`manifest.json` 记录 skill 运行历史。

全局可复用知识放在仓库根目录的 `knowledge/cards/`。当用户确认某个分镜、镜头语言、动作拆分或提示词很好时，先调用 `knowledge_capture` 沉淀成知识卡；只有当这个模式需要稳定执行步骤时，才升级成新的 skill。

## 连续性原则

不要把一个动作简单拆成多张互不关联的图来赌视频会连贯。默认策略是：

- 每个分镜先拆成原子镜头；
- 每个原子镜头写清 `continuity_state_start` 和 `continuity_state_end`；
- 用首帧/尾帧控制图约束图生视频；
- 对碰撞、转身、突然加速等困难动作使用切镜或反应镜头；
- 生成后把前一段视频、角色视觉锚点提示词和地点锚点提示词作为后续参考。

## 开发约定

- 永远用中文回复用户。
- 这是 Python 项目，不要恢复 Flutter/Dart 入口，除非用户明确要求重新做 App。
- 不要提交 `config.local.json`、`projects/`、大体积生成媒体或缓存文件。
- 读写 stage 文件优先使用 `ProjectWorkspace`。
- 调用 LLM 或媒体服务前，尽量从 workspace 读取已有上下文，避免每个阶段孤立生成。
- 旧的 `generated/` 内容可以参考，但新流程的源状态应落在 `projects/<project-id>/`。
