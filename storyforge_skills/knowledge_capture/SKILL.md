# knowledge_capture

Capture an approved storyboard, atomic shot, keyframe prompt, video result, or
free-form user note into reusable Storyforge knowledge cards.

Use this when the user says a result is good and should become local memory,
style memory, or a future reusable pattern.

## Inputs

At least one source is required:

```json
{
  "source_stage": "storyboards",
  "item_id": "sb_001",
  "source_file": "review/03_storyboards.md",
  "source_text": "A manually approved shot pattern...",
  "title": "Campus collision opening style",
  "tags": ["campus", "collision", "soft-comedy"],
  "user_note": "This pacing and direction logic worked well.",
  "scope": "project"
}
```

`scope` can be:

- `project`: write to `projects/<project-id>/wiki/cards/`
- `global`: write to repository-level `knowledge/cards/`
- `both`: write to both

## Reads

```text
stages/*.json
review/*.md
free-form source_text
```

## Writes

```text
projects/<project-id>/wiki/cards/*.md
knowledge/cards/*.md
stages/07_knowledge_capture.json
review/07_knowledge_capture.md
```

## Rules

- Capture durable patterns, not one-off praise.
- Include when to use the pattern, what to do, and what to avoid.
- Preserve concrete camera, action, direction, continuity, and prompt rules.
- Avoid copying long source text.
- Prefer project scope for story-specific knowledge and global scope for reusable style or production techniques.

## CLI

```bash
python -m storyforge.cli --project <project-id> run knowledge_capture --input-json "{\"source_stage\":\"storyboards\",\"item_id\":\"sb_001\",\"scope\":\"both\",\"tags\":[\"campus\",\"collision\"]}"
```
