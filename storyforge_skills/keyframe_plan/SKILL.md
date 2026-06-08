# keyframe_plan

Create first/last keyframe image tasks for Codex-assisted image generation.

This skill does not call an image model. It writes the prompts, continuity
constraints, and expected local file paths that Codex should use when creating
the images.

## Reads

```text
stages/02_assets.json
stages/04_atomic_shots.json
```

## Writes

```text
stages/05_keyframe_plan.json
review/05_keyframe_plan.md
```

## Rules

- Create a first-frame and last-frame task for every atomic shot.
- Include relevant character, prop, location, direction, and physical-state anchors.
- Use stable local target paths under `keyframes/`.
- Do not call Ark image generation.
- Stop here for Codex image generation and human review.

## CLI

```bash
python -m storyforge.cli --project <project-id> run keyframe_plan
```
