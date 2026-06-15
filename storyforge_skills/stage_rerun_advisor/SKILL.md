# stage_rerun_advisor

在用户修改某个阶段或大场景后，提示后续哪些阶段需要重跑或复查。

## Reads

```text
stages/*.json
manifest.json
```

## Writes

```text
stages/08_stage_rerun_advisor.json
review/08_stage_rerun_advisor.md
```

## Rules

- 可传 `changed_stage`，例如 `03_storyboards.json`。
- 可传 `changed_file`，自动映射到对应 stage。
- 可传 `scene_id`，把建议聚焦到某个大场景。
- 如果某个 stage 的依赖文件比它更新，标记为 stale。
- 对受影响的下游 stage 给出 `rerun` 或 `review_only` 建议。

## CLI

```bash
python -m storyforge.cli --project <project-id> advise-rerun --changed-stage 03_storyboards.json --scene-id SCENE_001
```
