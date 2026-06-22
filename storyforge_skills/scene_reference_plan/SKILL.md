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

## Shared Asset Order

同一 `scene_id` 的场景参考图必须先有共同资产，再生成派生参考图：

1. 先规划并生成/import `location_master_plate`。
2. 后续 `character_back`、`prop_placement_plate`、`camera_angle_plate_*`、`collision_point_plate`、`post_collision_state_plate` 必须继承同一个 `location_master_plate`。
3. 非 master 任务必须写入：

```json
{
  "depends_on_reference_ids": ["<scene_id>_location_master_plate"],
  "shared_asset_policy": "必须继承同一 scene_id 的 location_master_plate，不得重新发明场地共同资产、入口出口、光线方向或轴线。"
}
```

如果用户或审阅 agent 发现同一场景的校门、教室、楼梯、食堂、球馆等共同资产不一致，应先重生/确认 `location_master_plate`，再重生依赖它的派生参考图，不要继续生成关键帧。

## Scene Asset Pack

进入某个大场景的正式分镜、关键帧或图生视频之前，必须先为该大场景生成一整套共同资产包，而不是只生成一张校门或一张角色图。

每个 `scene_id` 的共同资产包至少应包含：

- `location_master_plate`：场地总览，锁定共同地点资产、入口出口、纵深、光线方向、人流/队列/球台/课桌等布局。
- 必要 `character_back` / `character_canon`：该场景中主要人物的无脸背影、服装、书包、携带物和初始状态。
- `prop_placement_plate`：关键道具的位置、朝向、归属、运动约束和碰撞/落点关系。
- `camera_angle_plate_*`：该场景可复用的主要机位，尤其是动作方向、低机位、过肩、反应镜头等。
- 动作/状态参考图：例如 `collision_point_plate`、`post_collision_state_plate`、训练前/赛后状态等，仅在该大场景需要时生成。

`scene_reference_plan` 产物应把这些任务归到同一个 `scene_asset_pack_id`，并标记 `pack_required_before_keyframes: true`。后续 `keyframe_plan` 必须读取这一层状态。
