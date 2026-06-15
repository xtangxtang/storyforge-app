# keyframe_generate_ark

通过 Ark 图片生成控制首帧的备用路径。

这不是 Storyforge 默认图片路径。默认仍由 Codex 根据 `keyframe_plan` 生成图片；只有用户明确要求自动走 Ark 文生图时才使用本 skill。

## Reads

```text
stages/02_assets.json
stages/04_atomic_shots.json
stages/04b_continuity_validation.json
stages/00d_scene_references.json
stages/00e_cross_scene_continuity.json
```

## Writes

```text
stages/05_keyframes.json
keyframes/*.png
review/05_keyframes.md
```

## Rules

- 默认每个原子镜头只生成 first-frame-only 控制首帧。
- 首帧必须遵守 `control_frame_role`、`frame_must_show`、`frame_must_not_show`、资产锚点和 Consistency Bible。
- 首帧必须继承 `scene_id`、`continuity_state_start/end`、`wiki/scene_bible.md` 和 `wiki/continuity.md` 的场景连续性约束。
- 首帧必须继承 `wiki/cross_scene_continuity.md` 的跨场景角色/道具状态，不能让服装、携带物、道具归属无解释重置。
- 如果存在同场景参考图，Ark 生成首帧时应把 `scene_reference_local_paths` 作为参考图优先注入，用来稳定地点结构、光线、机位和道具状态。
- 生成结果标记 `image_provider: ark`，并写入 `stages/05_keyframes.json`。
- 关键帧要保持角色身份、统一校服、地点布局、道具状态、光线方向和运动方向连续。
- 不依赖可读中文招牌、字幕、标题字、水印或 logo。
- 生成失败要记录到 stage，不中断整个批次。

## CLI

```bash
python -m storyforge.cli --project <project-id> run keyframe_generate_ark
```
