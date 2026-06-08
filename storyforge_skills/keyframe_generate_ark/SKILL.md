# keyframe_generate_ark

Optional fallback for generating first/last control frames through Ark image
generation.

This is not the default Storyforge image path. Use it only when the user
explicitly wants automated Ark image generation instead of Codex-created images.

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

- Generate a first frame and last frame per atomic shot through Ark.
- Mark outputs with `image_provider: ark`.
- Last frame should reference the first frame to reduce drift.
- Keep identity, clothing, prop state, and movement direction consistent.

## CLI

```bash
python -m storyforge.cli --project <project-id> run keyframe_generate_ark
```
