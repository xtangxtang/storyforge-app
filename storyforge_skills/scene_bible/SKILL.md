# scene_bible

为每个大场景建立共享的场景制作包，供后续分镜、原子镜头、关键帧和视频生成继承。

这个 skill 不生成图片，也不拆分镜。它先锁定一个大场景的空间、光线、轴线、人物状态、道具状态和物理规则，避免后续多个分镜各自发明。

## Reads

```text
stages/01_script.json
stages/00_style.json
stages/00b_consistency.json
wiki/*
```

## Writes

```text
stages/00c_scene_bible.json
wiki/scene_bible.md
review/00c_scene_bible.md
```

## Rules

- 每个大场景必须包含 `scene_id`、`scene_nums`、`name`、`location`、`story_purpose`。
- 锁定 `time_weather_light`：时间、天气、主光方向、阴影方向、色温和是否允许变化。
- 锁定 `spatial_map`：入口、出口、道路、门、墙、桌椅、球台、固定陈设和前后左右关系。
- 锁定 `screen_direction_rules`：人物进入/离开方向、镜头左右关系、运动方向和禁止反向规则。
- 写出 `camera_coverage_plan`：建立镜头、主动作镜头、插入特写、反应镜头、过肩/关系镜头、转场镜头。
- 写出 `crowd_rules`、`character_state_rules`、`prop_state_rules` 和 `physics_rules`。
- 写出 `scene_reference_frames`：`location_master_plate`、`camera_angle_plates`、`prop_placement_plate`。
- 写出 `continuity_contract` 和可直接注入后续 prompt 的 `prompt_injection`。
- 所有字段值使用简体中文，并遵守 `wiki/style.md` 和 `wiki/consistency.md`。

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_bible
```
