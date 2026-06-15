# scene_reference_generate_ark

备用路径：通过 Ark 生成场景 master plate、机位参考和道具摆放参考图。

默认图片路径仍是 Codex 生成 + `scene_reference_import`。只有用户明确要求自动走 Ark 文生图时才使用本 skill。

## Reads

```text
stages/00d_scene_reference_plan.json
stages/00c_scene_bible.json
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

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_reference_generate_ark
```
