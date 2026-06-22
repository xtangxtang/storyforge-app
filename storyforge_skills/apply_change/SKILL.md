# apply_change

## 目的

`apply_change` 是 Storyforge 的半自动修改入口。用户不要直接手改多个 stage，而是把修改请求交给这个 skill；它会调用 `change_propagator` 分析影响范围，并在确认后应用同步改写。

它是给 Codex / Claude Code / CLI 使用的统一入口：

```text
用户修改意图 -> apply_change -> change_propagator -> stage 备份/同步改写 -> 改动报告
```

## 输入

```json
{
  "change_request": "把 S1-02 的自行车方向锁定为朝学校大门内侧",
  "changed_stage": "03_storyboards.json",
  "scene_id": "S1",
  "item_id": "S1-02",
  "apply": false
}
```

字段：

- `change_request`：必填，用户想改什么。
- `changed_stage` / `changed_file`：修改从哪个 stage 或文件开始。
- `scene_id`：可选，收窄到某个大场景。
- `item_id`：可选，收窄到某个分镜、原子镜头、关键帧或资产。
- `target_stages`：可选，只允许检查/改写这些 stage。
- `apply`：默认 `false`，只生成计划；为 `true` 时才写文件。

## 输出

实际输出复用 `change_propagator`：

```text
stages/10_change_propagator.json
review/10_change_propagator.md
archive/change_propagator/<timestamp>/<stage>.json
```

## 使用规则

- 当用户说“改这个并同步后面”“前后都帮我改一致”“改完告诉我改了什么”时，优先使用 `apply_change`。
- 第一次默认 `apply:false`，让用户审阅计划。
- 用户确认或任务明确要求直接执行时，再用 `apply:true`。
- `apply:true` 前会由 `change_propagator` 备份被改写的 stage。
- 媒体结果 stage 不直接改写，只标记为需要重跑或复查。

## CLI

计划模式：

```bash
python -m storyforge.cli --project <project-id> apply-change --changed-stage 03_storyboards.json --item-id S1-02 --change-request "把自行车方向锁定为朝学校大门内侧"
```

应用模式：

```bash
python -m storyforge.cli --project <project-id> apply-change --changed-stage 03_storyboards.json --item-id S1-02 --change-request "把自行车方向锁定为朝学校大门内侧" --apply
```
