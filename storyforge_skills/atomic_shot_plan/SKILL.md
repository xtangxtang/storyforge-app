# atomic_shot_plan

Split storyboard beats into physically plausible atomic shots with explicit
start and end states.

## Reads

```text
stages/03_storyboards.json
wiki/*
```

## Writes

```text
stages/04_atomic_shots.json
review/04_atomic_shots.md
```

## Rules

- Keep continuous action (no time/space/angle break) as ONE shot — e.g. ride →
  collision → apology in a single continuous clip. Do NOT split continuous action
  into separate clips that need stitching (jarring cuts, mismatched poses). Only
  cut at real breaks: time jump, new location, new camera, or a shot over 10s.
- Each shot gets `render_mode` (`i2v` default / `t2v`):
  - `i2v` when a strictly faceless back/behind first frame is possible — locks
    direction and passes moderation (output may still show faces).
  - `t2v` only when the shot must open on a face (dialogue/emotion close-up); its
    `video_prompt` must then be self-contained.
- `first_frame_prompt`: strictly faceless back/behind view with the destination in
  deep background to lock direction; add identity anchors (uniform colors,
  glasses/backpack, hair/build) to distinguish characters.
- Hard contact (collision/brake) lives inside a continuous shot — the exact contact
  frame is unattainable, so hide it in motion + aftermath; stage entrants merging
  from a side path (not standing in the road); end on a medium-close aftermath.
- duration 5–10s; a continuous micro-scene can use 8–10s.
- Adjacent shots share state: previous `continuity_state_end` becomes next
  `continuity_state_start`. `reference_asset_names` lists present characters +
  location (location canon first).

## CLI

```bash
python -m storyforge.cli --project <project-id> run atomic_shot_plan
```
