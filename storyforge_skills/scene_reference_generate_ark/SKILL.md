# scene_reference_generate_ark

备用路径：通过 Ark 生成场景 master plate、机位参考和道具摆放参考图。

默认图片路径仍是 Codex 生成 + `scene_reference_import`。只有用户明确要求自动走 Ark 文生图时才使用本 skill。

## Reads

```text
stages/00d_scene_reference_plan.json
stages/00c_scene_bible.json
stages/00f_asset_canon.json
wiki/style.md
```

## Writes

```text
stages/00d_scene_references.json
assets/scene_refs/*.png
review/00d_scene_references.md
```

## Rules

- 按 `scene_reference_plan` 的任务逐张生成。
- 已存在本地图片默认跳过，可用 `overwrite` 重生成。
- 支持 `ids`/`reference_ids`、`start_index`、`limit` 做断点续跑。
- 所有图片必须无字幕、无水印、无 logo、无 UI、无拼贴。
- 失败记录到 stage，不中断整个批次。

## Canon 继承（强制底图，不得纯文字生成）

生成每张参考图前，必须把项目级共用 canon（`stages/00f_asset_canon.json`）和本场景 master plate 作为 reference image 一起喂进去：

- 显式 `canon_refs`（角色校服 canon、复用道具 canon）= 必须继承，缺图即报错。
- 按 `scene.location` 自动匹配的地点 canon（大门/教室/球馆等）在 canon 已建立时 = 必须继承，缺图即报错。
- `depends_on_reference_ids`（同场景 master plate）= 必须继承，缺图即报错。
- **缺任一必需底图时，该任务标记 `state: failed` 并拒绝纯文字生成**（避免大门/校服各自重新发明）。只有显式传 `allow_missing_canon: true` 才允许退回纯文字。
- 生成结果在 `reference_image_inputs` 记录实际喂进去的 canon_id / master plate id，便于追踪继承关系。

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_reference_generate_ark
```

## Shared Asset Generation Rule

Ark 生成场景参考图时必须按共同资产依赖顺序执行：

1. 每个 `scene_id` 先生成 `location_master_plate`。
2. 同一 `scene_id` 的非 master 参考图必须读取 `depends_on_reference_ids`。
3. 如果依赖的 `location_master_plate` 已经存在本地图片，生成非 master 图时必须把它作为 reference image 输入。
4. 如果依赖 master 缺失，不应批量继续生成派生图；应先补 master，避免同一场景的校门、教室、楼梯、食堂或球馆结构漂移。
5. 生成报告中应保留 `reference_image_inputs`，方便用户追踪派生参考图继承了哪张共同资产。

这个规则优先级高于“按任务列表自然顺序生成”。共同资产一致性比单张图的局部美观更重要。

## Scene Asset Pack Gate

进入某个大场景的正式分镜、关键帧或图生视频之前，必须先生成并审阅该 `scene_id` 的共同资产包：

- `location_master_plate`
- 必要角色背影 / canon 图
- `prop_placement_plate`
- 主要 `camera_angle_plate_*`
- 该场景需要的动作或状态参考图

`scene_reference_generate_ark` 可以分批生成，但分批不能破坏资产包逻辑：

- 可以先只生成 master plate 给用户确认。
- 但在生成该场景正式关键帧前，必须补齐并审阅整个场景资产包。
- 如果用户指出同一场景共同资产不一致，应优先重生派生参考图，而不是继续关键帧。
