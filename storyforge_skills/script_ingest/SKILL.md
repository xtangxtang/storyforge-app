# script_ingest

Normalize a user-provided script into `stages/01_script.json`.

## Input

```json
{
  "script_text": "script content",
  "script_path": "optional/path/to/script.md"
}
```

## Output

```text
stages/01_script.json
review/01_script.md
```

## Rules

- Do not rewrite story, character identities, dialogue, or event order.
- Extract all named characters, primary locations, and important props.
- Use this skill before all downstream skills.

## CLI

```bash
python -m storyforge.cli --project <project-id> run script_ingest --input-json "{\"script_path\":\"script.md\"}"
```
