# keyframe_generate

Generate first and last control frames for each atomic shot.

## Reads

```text
stages/02_assets.json
stages/04_atomic_shots.json
```

## Writes

```text
stages/05_keyframes.json
keyframes/*.png
review/05_keyframes.md
```

## Rules

- Generate a first frame and last frame per atomic shot.
- Last frame should reference the first frame to reduce drift.
- Keep identity, clothing, prop state, and movement direction consistent.
- Stop here for human review before video generation.

## CLI

```bash
python -m storyforge.cli --project <project-id> run keyframe_generate
```
