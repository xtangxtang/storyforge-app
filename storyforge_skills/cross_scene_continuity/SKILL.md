# cross_scene_continuity

建立跨大场景的人物、道具、服装、情绪、物理状态和剧情接力规则。

`scene_bible` 负责一个大场景内部一致；本 skill 负责多个大场景之间的一致。它会记录哪些角色/道具/状态必须从上一场传到下一场，哪些变化需要剧情解释，哪些跳变禁止出现。

## Reads

```text
stages/01_script.json
stages/00c_scene_bible.json
wiki/style.md
wiki/consistency.md
wiki/scene_bible.md
```

## Writes

```text
stages/00e_cross_scene_continuity.json
wiki/cross_scene_continuity.md
review/00e_cross_scene_continuity.md
```

## Rules

- `entities` 列所有跨场景复用的角色、道具和地点。
- `scene_states` 按 `scene_id` 记录该大场景开始和结束时的角色/道具状态。
- `transitions` 记录相邻大场景之间必须承接、允许变化、禁止跳变的内容。
- 重点检查：
  - 同一天内服装、发型、书包、球拍、自行车等是否连续。
  - 道具是否丢失、转移、损坏、留在上一场或重新出现。
  - 角色上一场产生的汗水、疼痛、尴尬、着急、受伤、情绪变化是否传递。
  - 时间跳转是否足以解释换装、道具重置或状态恢复。
- 所有字段值使用简体中文。

## CLI

```bash
python -m storyforge.cli --project <project-id> run cross_scene_continuity
```
