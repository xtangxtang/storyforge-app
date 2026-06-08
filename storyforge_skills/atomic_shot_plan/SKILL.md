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

- One atomic shot carries one action intent.
- Adjacent shots must share state: previous `continuity_state_end` becomes next
  `continuity_state_start`.
- Use cutaways for collisions, falls, handoffs, complex bicycle motion, or other
  hard physics.
- Make movement direction and prop positions explicit.

## CLI

```bash
python -m storyforge.cli --project <project-id> run atomic_shot_plan
```
