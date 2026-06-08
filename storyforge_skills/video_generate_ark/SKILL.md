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
- Pass previous clip as a reference when possible to improve continuity.
- Preserve each atomic shot's start/end state and physical intent.
- Failed clips are recorded in `stages/06_videos.json` instead of aborting the
  entire batch.

## CLI

```bash
python -m storyforge.cli --project <project-id> run video_generate_ark
```
