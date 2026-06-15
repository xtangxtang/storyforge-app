# scene_transition_plan

根据已生成视频和跨场景连续性，规划大场景之间的连贯转场参考视频。

这个 skill 不直接生成视频。它找出上一大场景最后一个可用视频、下一大场景的场景参考图，以及 `cross_scene_continuity` 中的状态接力要求，形成可审阅的转场参考任务。

## Reads

```text
stages/06_videos.json
stages/00c_scene_bible.json
stages/00d_scene_references.json
stages/00e_cross_scene_continuity.json
```

## Writes

```text
stages/06b_scene_transition_plan.json
review/06b_scene_transition_plan.md
```

## Rules

- 每个相邻大场景生成一个 `transition_task`。
- 优先使用上一大场景最后一个 `ready` 视频作为 `previous_scene_video_url`。
- 优先使用下一大场景的 `location_master_plate` 作为参考图。
- `transition_prompt` 必须写清必须承接、允许变化和禁止跳变。
- 转场参考视频只用于审阅两个大场景之间是否连贯，不替代正式剧情分镜。

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_transition_plan
```
