# asset_design

Design stable visual anchors and reusable image prompts for script assets.

This skill does not generate images. It prepares character, location, and prop
identity rules that later image-generation work must follow.

## Reads

```text
stages/01_script.json
```

## Writes

```text
stages/02_assets.json
review/02_assets.md
```

## Rules

- Preserve every asset's type, name, and story role.
- Add a concrete `visual_anchor_prompt` for each character/location/prop.
- Add `negative_prompt` and `consistency_notes`.
- Avoid poster, collage, mood-board, UI, or text-sheet language.
- Make clothing, age, body language, object state, and location geography reusable across later keyframes.

## CLI

```bash
python -m storyforge.cli --project <project-id> run asset_design
```
