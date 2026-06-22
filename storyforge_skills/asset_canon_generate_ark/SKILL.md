# asset_canon_generate_ark

通过 Ark 生成**项目级共用 canon 基准图**（大门、校服/各角色、复用道具），作为全片唯一外观锚点。

默认图片路径也可由 Codex 出图后放到 `assets/canon/` 指定路径再登记。本 skill 是 Ark 自动出图路径。

## 何时运行

- 在 `asset_canon_plan` 之后、`scene_reference_generate_ark` 之前。
- 用户确认 canon 外观后，后续所有场景参考图、关键帧、图生视频都继承它。

## Reads

```text
stages/00f_asset_canon_plan.json
stages/02_assets.json
stages/00b_consistency.json
```

## Writes

```text
stages/00f_asset_canon.json
assets/canon/*.png
review/00f_asset_canon.md
```

## Rules

- 按 `asset_canon_plan` 的任务逐张生成；canon 是底图本身，不再引用其它参考图。
- 已存在本地图片默认跳过，可用 `overwrite` 重生成。
- 支持过滤：`canon_ids`/`ids`、`asset_types`（character/location/prop）、`start_index`、`limit`，便于按需逐张生成、控制配额。
- 每个复用角色/地点/道具只锁定**一张** canon；角色 canon 清楚展示统一校服与书包颜色，地点 canon 清楚展示固定布局，道具 canon 单一道具中性背景。
- 所有图片必须无字幕、无水印、无 logo、无 UI、无拼贴。
- 失败记录到 stage，不中断整个批次。

## 下游继承

`scene_reference_generate_ark` 会把这里产出的 canon 作为**强制 reference image**喂给场景参考图：

- 显式 `canon_refs`（角色/道具）+ 按 `scene.location` 自动匹配的地点 canon + 同场景 master plate。
- 缺任一必需 canon 时，下游参考图任务会报错、拒绝纯文字生成。

## CLI

```bash
python -m storyforge.cli --project <project-id> run asset_canon_generate_ark
```
