# scene_transition_generate_ark

备用路径：通过 Ark 生成大场景之间的连贯转场参考视频。

## Reads

```text
stages/06b_scene_transition_plan.json
clips/*.mp4
assets/scene_refs/*.png
```

## Writes

```text
stages/06b_scene_transitions.json
clips/transitions/*.mp4
review/06b_scene_transitions.md
```

## Rules

- 只在 `scene_transition_plan` 经 agent 和用户审阅后运行。
- 必须有上一大场景的 `video_url`，因为 Ark 的 `reference_video` 只能使用 web URL。
- 可用下一大场景的场景参考图辅助稳定目标空间。
- 支持 `ids`/`transition_ids` 和 `overwrite`。
- 失败记录到 stage，不中断整个批次。

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_transition_generate_ark
```
