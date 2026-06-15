# storyboard_plan

从结构化剧本和项目记忆生成可审阅的导演分镜节拍。

## Reads

```text
stages/01_script.json
stages/00c_scene_bible.json
stages/00e_cross_scene_continuity.json
wiki/*
```

## Writes

```text
stages/03_storyboards.json
review/03_storyboards.md
```

## Rules

- 保留原剧本的事件顺序、人物关系、对白信息和情绪转折。
- 每个分镜节拍必须包含 `scene_id`、`coverage_role`、`scene_bible_refs`、`dramatic_intent`、`camera_design`、`blocking`、`screen_direction`、`edit_value`、`continuity_risks`。
- `coverage_role` 从建立镜头、主动作镜头、插入特写、反应镜头、过肩关系镜头、转场镜头中选择。
- `scene_bible_refs` 写清继承的光线、轴线、人群、道具状态和物理规则。
- 分镜必须继承跨场景接力：服装、携带物、道具持有人、身体/情绪状态不能无解释重置。
- `dramatic_intent` 写清镜头承担的信息、情绪或冲突功能。
- `camera_design` 写机位、景别、焦段感和镜头运动动机；不要只写“好看”或“电影感”。
- `blocking` 写人物、道具和地点在空间中的调度关系。
- `screen_direction` 写入画方向、视线方向、运动方向，以及与前后镜头如何接续。
- 动作连续、中间没有时间/空间/机位断点的段落保持为一个节拍；只在真实断点切镜。
- 方向、进入、相撞类镜头的 `first_frame_prompt` 优先用无清晰真人脸的控制画面锁方向，例如背影、过肩、场地空镜或物件特写。
- 所有字段值使用简体中文，并遵守 `wiki/style.md`、`wiki/consistency.md`、`wiki/scene_bible.md`、`wiki/cross_scene_continuity.md` 和 `stages/02_assets.json`。

## CLI

```bash
python -m storyforge.cli --project <project-id> run storyboard_plan
```
