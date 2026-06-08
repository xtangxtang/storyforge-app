# keyframe_import

Import Codex-created local keyframe images into the machine-readable keyframe
stage used by Ark video generation.

## Reads

```text
stages/05_keyframe_plan.json
keyframes/*.png
```

You can also pass explicit paths:

```json
{
  "images": [
    {
      "atomic_shot_id": "atom_001",
      "first_frame_local_path": "keyframes/atom_001_first.png",
      "last_frame_local_path": "keyframes/atom_001_last.png"
    }
  ]
}
```

## Writes

```text
stages/05_keyframes.json
review/05_keyframes.md
```

## Rules

- Do not generate images.
- Verify first and last frame files exist before marking a shot imported.
- Preserve `video_prompt`, duration, and storyboard linkage from the plan.
- Imported keyframes use `image_provider: codex`.

## CLI

```bash
python -m storyforge.cli --project <project-id> run keyframe_import
```
