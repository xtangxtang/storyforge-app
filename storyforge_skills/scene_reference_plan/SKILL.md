# scene_reference_plan

把 Scene Bible 中的场景参考图计划编译成可由 Codex 或 Ark 生成的图片任务。

这些图片不是最终分镜，而是大场景的共享视觉锚点：场地总览、固定机位、道具摆放。后续多个分镜和关键帧都应引用它们，以保持场景、光线、轴线和道具状态一致。

## Reads

```text
stages/00c_scene_bible.json
wiki/style.md
wiki/scene_bible.md
```

## Writes

```text
stages/00d_scene_reference_plan.json
review/00d_scene_reference_plan.md
```

## Rules

- 每个大场景至少规划：
  - `location_master_plate`：场地总览，锁定空间结构、光线方向和人群规则。
  - `camera_angle_plate_*`：主要机位参考，锁定可复用取景方向。
  - `prop_placement_plate`：关键道具摆放、朝向、持有人和物理状态。
- 每个任务包含 `reference_id`、`scene_id`、`reference_role`、`prompt`、`local_path`、`must_show`、`must_not_show`。
- 输出路径固定在 `assets/scene_refs/`。
- 所有字段值使用简体中文。

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_reference_plan
```
