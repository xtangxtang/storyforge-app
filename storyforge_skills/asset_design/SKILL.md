# asset_design

为角色、地点和道具建立影视化视觉资产圣经。

这个 skill 不生成图片。它把剧本中的资产整理成后续分镜、关键帧和视频生成必须遵守的稳定身份规则。

## Reads

```text
stages/01_script.json
stages/00c_scene_bible.json
stages/00e_cross_scene_continuity.json
wiki/*
```

## Writes

```text
stages/02_assets.json
review/02_assets.md
```

## Rules

- 保留每个资产的 `type`、`name`、`description` 和叙事功能。
- 为每个资产补充 `asset_id`、`story_function`、`visual_identity`、`visual_anchor_prompt`、`negative_prompt`、`consistency_notes`。
- 资产设计必须能被 `scene_bible` 里的大场景复用：地点结构、角色携带物、道具朝向和物理状态不能与场景制作包冲突。
- 资产设计必须遵守 `cross_scene_continuity`：角色服装、携带物、道具归属、损坏/丢失/转移状态不能在不同大场景之间无解释跳变。
- 补充影视连续性字段：
  - `continuity_invariants`：跨镜头绝不能变的服装、身份、地点结构、道具形态、方向关系。
  - `allowed_variations`：可以随镜头变化的景别、光影、表演强弱、遮挡、距离。
  - `forbidden_variations`：会造成漂移或穿帮的变化。
  - `cinematic_usage`：推荐景别、光线、运动方式。
  - `generation_anchors`：给图片/视频生成使用的正向锚点、负向锚点和参考优先级。
- 避免海报、拼贴、设定集排版、UI 或文字说明页语言。
- 所有字段值使用简体中文，并遵守 `wiki/style.md` 与 Consistency Bible。

## CLI

```bash
python -m storyforge.cli --project <project-id> run asset_design
```
