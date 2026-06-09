# consistency_bible

Extract and lock the cross-shot SHARED elements BEFORE any visual design, so the
whole film stays unified (uniform, location layouts, recurring props are not
re-invented per shot).

## Reads

```text
stages/01_script.json
stages/00_style.json
wiki/*
```

## Writes

```text
stages/00b_consistency.json
wiki/consistency.md
review/00b_consistency.md
```

## Output (JSON)

- `uniform`: exact spec of the standard school uniform (colors, collar, cut, bottoms, shoes)
- `fixed_outfits`: `{character: non-uniform fixed outfit}`
- `palette`: film-wide color / light key
- `location_layouts`: `{location: invariant structure & layout — blackboard / window /
  door / desk-rows / sign positions}` so a location looks identical across shots
- `recurring_props`: `{prop: unified appearance}`
- `world_rules`: rules that must hold film-wide (e.g. the morning crowd all flows
  toward the gate; summer short-sleeve uniform)

## Rules

- Runs after `style_select`, before `asset_design`.
- Only lock things genuinely reused across shots; be concrete and drawable.
- Downstream (`asset_design`, canon/sheet anchors, `storyboard_plan`,
  `atomic_shot_plan`, keyframe prompts) must honor the bible via `context_pack` and
  not re-describe uniform / layout / props. `ensure_asset_anchors` bakes the uniform
  and per-location layout into every generated anchor.

## CLI

```bash
python -m storyforge.cli --project <project-id> run consistency_bible
```
