# atomic_shot_plan

把导演分镜节拍拆成物理可信、可生成的原子镜头，并写清起止状态。

## Reads

```text
stages/03_storyboards.json
wiki/*
```

## Writes

```text
stages/04_atomic_shots.json
review/04_atomic_shots.md
```

## Rules

- 保留连续动作：没有时间、空间、全新机位断点的动作尽量作为一条连续镜处理；只在真实断点或超过 10 秒时切镜。
- 每个原子镜头必须包含：
  - `shot_design`：`camera`、`movement`、`blocking`、`performance`、`edit_intent`，给导演/剪辑看的拍摄逻辑。
  - `generation_strategy`：`render_mode`、`first_frame_type`、`control_frame_role`、`reference_assets`、`failure_modes`、`moderation_notes`，给图片/视频生成看的执行策略。
- `render_mode`：
  - 默认 `i2v`：能用无清晰真人脸的背影、过肩、场地空镜或物件特写作为首帧时使用。
  - 只有必须从正脸情绪/对白特写开始、无法合理做无脸首帧时才使用 `t2v`。
- `first_frame_prompt` 是图生视频控制帧，不是分镜插画。它要锁定空间、方向、身份、物理初态或动作触发点。
- 硬接触动作（相撞、急刹、摔倒）不要赌模型精确生成接触帧；用连续镜、运动模糊、遮挡、反应和余波解决。
- `duration` 默认 5-10 秒；动作节拍要与时长匹配，不能把过多动作塞进短镜头。
- 相邻镜头共享状态：前一镜的 `continuity_state_end` 应自然成为后一镜的 `continuity_state_start`。
- `reference_asset_names` 只列首帧画面里真正出现的资产；地点 canon 优先，避免无关角色触发提示词审核或身份漂移。
- 所有字段值使用简体中文，并遵守 `wiki/style.md`、`wiki/consistency.md` 和 `stages/02_assets.json`。

## CLI

```bash
python -m storyforge.cli --project <project-id> run atomic_shot_plan
```
