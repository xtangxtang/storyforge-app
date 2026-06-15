# review_decision

记录用户对某个 stage 的审阅决策，并把修改意见和重跑建议写入项目文件。

## Reads

```text
review/index.json
review/decisions.json
stages/*.json
```

## Writes

```text
review/decisions.json
wiki/decisions.md
stages/09_review_decision.json
review/09_review_decision.md
review/index.json
review/index.md
```

## Rules

- `decision` 必须是 `approve`、`revise`、`changes_requested`、`block` 或 `reject`。
- `approve` 表示该阶段可继续；不生成重跑建议。
- `revise` / `changes_requested` / `block` / `reject` 会根据 `changed_stage` 和依赖图生成下游重跑建议。
- 可选填写 `scene_id`、`item_id`、`note`、`requested_changes`，用于精确记录用户修改意见。
- 决策追加写入，不覆盖历史。

## CLI

```bash
python -m storyforge.cli --project <project-id> review-decision --skill-id storyboard_plan --decision approve
python -m storyforge.cli --project <project-id> review-decision --skill-id atomic_shot_plan --decision revise --changed-stage 04_atomic_shots.json --scene-id SCENE_001 --item-id AS002 --note "骑车方向反了，车头必须朝校门"
```
