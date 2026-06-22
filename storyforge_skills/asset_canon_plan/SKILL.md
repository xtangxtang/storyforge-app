# asset_canon_plan

把 `asset_design` 与 Consistency Bible 编译成**项目级共用 canon 基准图任务**：大门、校服/各角色、复用道具的唯一外观锚点。

这是修复"每个场景各自发明大门/校服/道具"的关键前置步骤。canon 是项目级、跨场景共享的唯一图源，不是场景参考图，也不是分镜。

## 何时运行

- 在 `asset_design` 之后、`scene_reference_plan` / `scene_reference_generate_ark` 之前。
- 更换风格、Consistency Bible 或资产设计后应重跑。

## Reads

```text
stages/02_assets.json
stages/00b_consistency.json
wiki/style.md
wiki/consistency.md
```

## Writes

```text
stages/00f_asset_canon_plan.json
review/00f_asset_canon_plan.md
```

## Rules

- 对每个 `character` / `location` / `prop` 资产各生成**一条** canon 任务（`canon_id` 形如 `canon_char_<名>`、`canon_loc_<名>`、`canon_prop_<名>`）。
- 角色 canon 必须锁定 Consistency Bible 的统一校服；地点 canon 必须锁定 `location_layouts`；道具 canon 必须锁定 `recurring_props`。
- prompt 自动清洗资产字段里混入的 dict/JSON 转储片段，避免污染出图。
- canon 是唯一外观锚点：下游 `scene_reference`、`keyframe`、`video` 都必须继承，不得各自重新发明。
- 输出只是任务清单（prompt + 目标路径），不出图。出图走 `asset_canon_generate_ark` 或 Codex。

## CLI

```bash
python -m storyforge.cli --project <project-id> run asset_canon_plan
```
