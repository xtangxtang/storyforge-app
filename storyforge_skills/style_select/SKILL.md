# style_select

Ask the user to choose a production style immediately after script ingest, then
persist the selected style profile for all downstream prompts.

## Inputs

Without a style, this skill writes a style-selection prompt and pauses the
pipeline:

```json
{
  "force_prompt": true
}
```

With a style, it persists the selected profile:

```json
{
  "style": "film",
  "style_note": "Use warm morning campus light and restrained comedy."
}
```

Built-in style ids:

- `film`: 电影风格
- `short_drama`: 短剧风格
- `comic_drama`: 漫剧风格
- `anime`: 动画番剧风格
- `documentary`: 纪实风格

Any other `style` value becomes a custom style.

## Reads

```text
stages/01_script.json
```

## Writes

```text
stages/00_style.json
wiki/style.md
review/00_style_select.md
review/agent_style_select.md
review/user_style_select.md
```

## Rules

- This stage must run immediately after `script_ingest`.
- Do not continue to `asset_design`, `storyboard_plan`, `atomic_shot_plan`, or `keyframe_plan` until a style is selected.
- Downstream prompts must follow `wiki/style.md` and `stages/00_style.json`.
- Changing style later should rerun downstream creative stages.

## CLI

Prompt for style:

```bash
python -m storyforge.cli --project <project-id> run style_select --input-json "{\"force_prompt\":true}"
```

Select style:

```bash
python -m storyforge.cli --project <project-id> run style_select --input-json "{\"style\":\"film\"}"
```
