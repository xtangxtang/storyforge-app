# continuity_validator

对分镜和原子镜头做场景连续性、轴线方向、道具状态和物理逻辑验证。

这个 skill 不生成新镜头。它作为进入关键帧计划前的质量门，专门检查大场景多个分镜是否真的共享同一个人物、场景、道具和物理世界。

## Reads

```text
stages/00c_scene_bible.json
stages/00e_cross_scene_continuity.json
stages/03_storyboards.json
stages/04_atomic_shots.json
wiki/*
```

## Writes

```text
stages/04b_continuity_validation.json
wiki/continuity.md
review/04b_continuity_validation.md
```

## Rules

- 检查地点结构、入口出口、轴线、运动方向、光线方向和人群规则是否违反 Scene Bible。
- 检查角色服装、携带物、身体/情绪状态、道具归属和损坏/丢失/转移是否违反 Cross Scene Continuity。
- 检查角色服装、发型、携带物、情绪、站位和朝向是否跳变。
- 检查道具位置、持有人、朝向、运动状态是否跳变。
- 检查物理动作是否可信：不能瞬移、穿模、速度突变、碰撞不合理或把过多动作塞进短时长。
- 检查 `first_frame_prompt`、`video_prompt`、`continuity_state_start/end` 是否足够支撑图生视频连续生成。
- 检查可读文字、字幕、水印、logo、中文招牌依赖和审核风险。
- 输出 `verdict`：`approve`、`revise` 或 `block`。`block` 会阻止 pipeline 继续进入关键帧计划。
- 所有字段值使用简体中文。

## CLI

```bash
python -m storyforge.cli --project <project-id> run continuity_validator
```
