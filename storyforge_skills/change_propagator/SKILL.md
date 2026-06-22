# change_propagator

## 目的

当用户修改某个 stage、人物设定、分镜、原子镜头、关键帧提示词或场景规则后，分析这个修改会影响哪些前后 stage，并在需要时同步改写相关机器可读 stage，最后输出清晰的改动报告。

它补足 `stage_rerun_advisor` 的执行能力：

- `stage_rerun_advisor`：告诉你哪些阶段需要重跑或复查。
- `change_propagator`：在用户明确要求时，尝试把局部修改传播到相关 stage，并报告实际做了哪些改动。

## 输入

```json
{
  "change_request": "把 S1-02A 改成低机位先拍自行车双轮，再抬到陈振飞焦急的脸",
  "changed_stage": "04_atomic_shots.json",
  "scene_id": "S1",
  "item_id": "S1-02A",
  "apply": false
}
```

字段：

- `change_request`：必填，用户修改意图。
- `changed_stage` / `stage`：可选，修改源 stage。
- `changed_file` / `file`：可选，修改源文件；未传 `changed_stage` 时会尝试从路径推断。
- `scene_id`：可选，用于收窄影响范围。
- `item_id`：可选，用于定位分镜、原子镜头、关键帧任务或资产。
- `target_stages` / `stages`：可选，显式指定允许分析/改写的 stage。
- `apply` / `apply_changes`：默认 `false`。为 `true` 时才会实际改写 stage。

## 输出

```text
stages/10_change_propagator.json
review/10_change_propagator.md
projects/<project-id>/archive/change_propagator/<timestamp>/<stage>.json
```

报告必须包含：

- 修改请求原文；
- 受影响的上游/下游 stage；
- 每个 stage 是 `update`、`review_only` 还是 `skip`；
- 实际改写的文件；
- 每个改写文件的备份路径；
- 每个文件的改动摘要；
- 后续需要重跑或复查的阶段。

## 行为规则

- 默认只做计划，不改写文件。
- 只有 `apply: true` 时才允许改写 stage。
- 改写前必须备份原 stage。
- 只能做最小同步修订，不要重写整部片。
- 保持原有 id、scene_id、storyboard_id、atomic_shot_id、媒体路径和未受影响条目。
- 不要直接改写媒体结果 stage：
  - `00d_scene_references.json`
  - `05_keyframes.json`
  - `06_videos.json`
  - `06b_scene_transitions.json`
- 对媒体结果只给出重跑或复查建议。
- 所有面向用户的内容必须使用简体中文。

## 推荐调用

先看计划：

```bash
python -m storyforge.cli --project <project-id> run change_propagator --input-json "{\"changed_stage\":\"03_storyboards.json\",\"item_id\":\"S1-02\",\"change_request\":\"把碰撞前的自行车方向锁定为朝学校大门内侧\",\"apply\":false}"
```

确认后应用：

```bash
python -m storyforge.cli --project <project-id> run change_propagator --input-json "{\"changed_stage\":\"03_storyboards.json\",\"item_id\":\"S1-02\",\"change_request\":\"把碰撞前的自行车方向锁定为朝学校大门内侧\",\"apply\":true}"
```

应用后继续运行：

```bash
python -m storyforge.cli --project <project-id> run continuity_validator
python -m storyforge.cli --project <project-id> run keyframe_plan
```
