# document_ingest

Extract a script document into the project workspace as normalized Markdown
text.

## Inputs

```json
{
  "document_path": "path/to/script.docx"
}
```

Supported formats:

- `.txt`
- `.md`
- `.markdown`
- `.docx`
- `.pdf`

Legacy `.doc` files are not supported directly. Convert them to `.docx` or
`.pdf` first.

## Reads

```text
source document path
```

## Writes

```text
raw/source/<original-file>
raw/script.md
stages/00_document.json
review/00_document_ingest.md
review/agent_document_ingest.md
review/user_document_ingest.md
```

## Rules

- Preserve the source text order.
- Do not rewrite the story.
- Copy the original source document into `raw/source/`.
- Write extracted script text to `raw/script.md`.
- Let `script_ingest` structure `raw/script.md` into scenes and assets.

## CLI

```bash
python -m storyforge.cli pipeline-from-document --document path/to/script.docx
```

If `--project` is omitted, Storyforge derives a project id from the document
title/content and stores everything under `projects/<project-id>/`.
