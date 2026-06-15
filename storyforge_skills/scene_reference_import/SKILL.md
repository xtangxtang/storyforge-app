# scene_reference_import

把 Codex 生成的本地场景参考图导入项目 stage。

## Reads

```text
stages/00d_scene_reference_plan.json
assets/scene_refs/*.png
```

## Writes

```text
stages/00d_scene_references.json
review/00d_scene_references.md
```

## Rules

- 按 `scene_reference_plan` 中的 `local_path` 查找图片。
- 导入后保留 `scene_id`、`reference_role`、`prompt`、`must_show`、`must_not_show`。
- 缺失图片写入 `missing`，不中断已有图片导入。
- 后续 `keyframe_plan` 会按 `scene_id` 引用这些图片。

## CLI

```bash
python -m storyforge.cli --project <project-id> run scene_reference_import
```
