# storyboard_plan

Create reviewable storyboard beats from the structured script and project memory.

## Reads

```text
stages/01_script.json
wiki/*
```

## Writes

```text
stages/03_storyboards.json
review/03_storyboards.md
```

## Rules

- Preserve the script.
- Keep each beat short enough for video generation.
- Write clear first-frame, video prompt, and continuity notes.
- Split difficult physical action into smaller beats or cutaways.

## CLI

```bash
python -m storyforge.cli --project <project-id> run storyboard_plan
```
