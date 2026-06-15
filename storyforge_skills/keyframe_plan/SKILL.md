# keyframe_plan

为 Codex 图片生成规划每个原子镜头的控制首帧任务。

这个 skill 不调用图片模型。它写出 Codex 需要生成的关键帧提示词、连续性约束、控制帧角色和本地目标路径。

## Reads

```text
stages/02_assets.json
stages/04_atomic_shots.json
stages/04b_continuity_validation.json
stages/00d_scene_reference_plan.json
stages/00d_scene_references.json
stages/00e_cross_scene_continuity.json
wiki/scene_bible.md
wiki/cross_scene_continuity.md
wiki/continuity.md
```

## Writes

```text
stages/05_keyframe_plan.json
review/05_keyframe_plan.md
```

## Rules

- 默认只为每个原子镜头创建 `first_frame_only` 控制首帧；只有困难接触、到达状态或明确需要落点控制时才规划 `last_frame_prompt`。
- 首帧不是分镜插画，而是图生视频控制帧：负责锁定空间、方向、身份、物理初态或动作触发点。
- 每个任务应包含 `control_frame_role`、`frame_must_show`、`frame_must_not_show`、`motion_to_generate`、`shot_design`、`generation_strategy`。
- 每个任务应保留 `scene_id`、`continuity_state_start`、`continuity_state_end`，让图片生成明确继承大场景状态。
- 每个任务必须保留跨场景连续性约束，尤其是服装、携带物、道具归属和身体/情绪状态。
- 如果存在场景参考图，每个任务应包含 `scene_reference_ids` 和 `scene_reference_local_paths`，优先引用同一 `scene_id` 的 `location_master_plate`、`prop_placement_plate` 和主要机位参考。
- `first_frame_prompt` 要合并风格摘要和相关资产锚点，但保持在 prompt budget 内。
- 使用 `keyframes/<atomic_shot_id>_first.png` 这类稳定路径。
- 不调用 Ark 图片生成；这里停下来给 Codex 生成图片并交给用户审阅。
- 所有字段值使用简体中文，并遵守 `wiki/style.md`、`wiki/consistency.md`、`wiki/scene_bible.md`、`wiki/cross_scene_continuity.md`、`wiki/continuity.md`、`stages/00d_scene_references.json` 和 `stages/02_assets.json`。

## CLI

```bash
python -m storyforge.cli --project <project-id> run keyframe_plan
```
