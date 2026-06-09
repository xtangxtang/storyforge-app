# video_generate_ark

Generate Ark Seedance clips from approved control frames.

## Reads

```text
stages/05_keyframes.json
```

## Writes

```text
stages/06_videos.json
clips/*.mp4
review/06_videos.md
```

## Rules

- Run only after keyframes are reviewed.
- Routes by each keyframe's `render_mode`:
  - `i2v` (default): drive from a strictly faceless back-view first frame — locks
    direction and passes moderation. Ark's PrivacyInformation check inspects ONLY
    the input first frame, not the output, so faces appear freely in the output clip.
  - `t2v`: text-to-video for face-forward shots that cannot open on a faceless
    frame. The `video_prompt` must be self-contained (subject + action + scene +
    causation). Direction/scene/identity are held by reference images, prioritized:
    faceless back-view frame + location canon + character sheets (cap 3).
- Do NOT feed the previous clip as `reference_video` by default — it fights action
  direction and risks moderation. Opt in with `chain_reference_video`.
- Local first-frame images are converted to data URLs before submitting to Ark.
- All prompts carry a no-subtitle / clean-frame constraint.
- Failed clips are recorded in `stages/06_videos.json` instead of aborting the
  entire batch.

## CLI

```bash
python -m storyforge.cli --project <project-id> run video_generate_ark
```
