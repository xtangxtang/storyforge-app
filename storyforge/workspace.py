from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class ProjectWorkspace:
    root: Path
    project_id: str

    @classmethod
    def open(cls, project_id: str, root: Path | None = None) -> "ProjectWorkspace":
        base = root or Path.cwd() / "projects"
        ws = cls(root=base / project_id, project_id=project_id)
        ws.ensure()
        return ws

    @property
    def raw_dir(self) -> Path:
        return self.root / "raw"

    @property
    def wiki_dir(self) -> Path:
        return self.root / "wiki"

    @property
    def stages_dir(self) -> Path:
        return self.root / "stages"

    @property
    def assets_dir(self) -> Path:
        return self.root / "assets"

    @property
    def keyframes_dir(self) -> Path:
        return self.root / "keyframes"

    @property
    def clips_dir(self) -> Path:
        return self.root / "clips"

    @property
    def review_dir(self) -> Path:
        return self.root / "review"

    @property
    def manifest_path(self) -> Path:
        return self.root / "manifest.json"

    @property
    def archive_dir(self) -> Path:
        return self.root / "archive"

    @property
    def project_cards_dir(self) -> Path:
        return self.wiki_dir / "cards"

    @property
    def global_knowledge_dir(self) -> Path:
        return self.root.parent.parent / "knowledge"

    @property
    def global_cards_dir(self) -> Path:
        return self.global_knowledge_dir / "cards"

    def ensure(self) -> None:
        for folder in [
            self.raw_dir,
            self.wiki_dir,
            self.project_cards_dir,
            self.stages_dir,
            self.assets_dir,
            self.keyframes_dir,
            self.clips_dir,
            self.review_dir,
            self.archive_dir,
            self.global_cards_dir,
        ]:
            folder.mkdir(parents=True, exist_ok=True)
        global_index = self.global_knowledge_dir / "README.md"
        if not global_index.exists():
            global_index.write_text(
                "# Storyforge Knowledge\n\n"
                "Local reusable production knowledge captured from approved project results.\n\n",
                encoding="utf-8",
            )
        if not self.manifest_path.exists():
            self.write_json(
                self.manifest_path,
                {
                    "schema": "storyforge-llm-native-v1",
                    "project_id": self.project_id,
                    "runs": [],
                    "state": {"current_stage": "created"},
                },
            )
        for name, title in [
            ("index.md", "Project Wiki"),
            ("style.md", "Style Profile"),
            ("knowledge.md", "Living Knowledge"),
            ("continuity.md", "Continuity"),
            ("decisions.md", "Decisions"),
            ("log.md", "Log"),
        ]:
            path = self.wiki_dir / name
            if not path.exists():
                path.write_text(f"# {title}\n\n", encoding="utf-8")

    def stage_path(self, name: str) -> Path:
        return self.stages_dir / name

    def read_stage(self, name: str) -> dict[str, Any]:
        path = self.stage_path(name)
        if not path.exists():
            return {}
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}

    def write_stage(self, name: str, data: dict[str, Any]) -> Path:
        path = self.stage_path(name)
        self.write_json(path, data)
        return path

    def write_json(self, path: Path, data: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def append_log(self, message: str, data: dict[str, Any] | None = None) -> None:
        lines = [f"## {time.strftime('%Y-%m-%d %H:%M:%S')}", "", message]
        if data:
            lines.append("")
            lines.extend(f"- {key}: {value}" for key, value in data.items())
        lines.append("")
        with (self.wiki_dir / "log.md").open("a", encoding="utf-8") as f:
            f.write("\n".join(lines))

    def add_run(self, record: dict[str, Any]) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest.setdefault("runs", []).append(record)
        manifest.setdefault("state", {})["current_stage"] = record.get("skill_id")
        manifest["state"]["updated_at"] = record.get("finished_at")
        self.write_json(self.manifest_path, manifest)

    def context_pack(self) -> str:
        parts: list[str] = []
        knowledge_cards = self.retrieve_knowledge_cards(limit=8)
        if knowledge_cards:
            cards = "\n\n".join(
                f"---\nsource: {card['source']}\n\n{card['text'][:4000]}"
                for card in knowledge_cards
            )
            parts.append(f"---\nsource: retrieved_knowledge_cards\n\n{cards}")
        for path in [
            self.raw_dir / "script.md",
            self.wiki_dir / "style.md",
            self.wiki_dir / "consistency.md",
            self.wiki_dir / "knowledge.md",
            self.wiki_dir / "continuity.md",
            self.stage_path("00_style.json"),
            self.stage_path("00b_consistency.json"),
            self.stage_path("01_script.json"),
            self.stage_path("02_assets.json"),
            self.stage_path("03_storyboards.json"),
        ]:
            if path.exists():
                parts.append(f"---\nsource: {path.relative_to(self.root).as_posix()}\n\n{path.read_text(encoding='utf-8')[:12000]}")
        return "\n\n".join(parts)

    def retrieve_knowledge_cards(self, tags: list[str] | None = None, limit: int = 12) -> list[dict[str, str]]:
        tag_set = {tag.lower() for tag in tags or [] if tag}
        candidates: list[dict[str, str]] = []
        for base, scope in [(self.project_cards_dir, "project"), (self.global_cards_dir, "global")]:
            if not base.exists():
                continue
            for path in sorted(base.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True):
                text = path.read_text(encoding="utf-8")
                score = 1
                lower = text.lower()
                if tag_set:
                    score += sum(3 for tag in tag_set if tag in lower)
                candidates.append({"source": f"{scope}:{path.name}", "text": text, "score": str(score)})
        candidates.sort(key=lambda item: int(item["score"]), reverse=True)
        return candidates[:limit]

    def write_knowledge_card(self, card: dict[str, Any], scope: str = "project") -> Path:
        title = str(card.get("title") or "untitled knowledge")
        slug = safe_slug(title)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        folder = self.global_cards_dir if scope == "global" else self.project_cards_dir
        path = folder / f"{stamp}_{slug}.md"
        tags = ", ".join(str(tag) for tag in card.get("tags", []) or [])
        lines = [
            f"# {title}",
            "",
            f"- scope: {scope}",
            f"- type: {card.get('type', 'style')}",
            f"- tags: {tags}",
            f"- captured_at: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            "",
            "## Summary",
            "",
            str(card.get("summary", "")).strip(),
            "",
            "## When To Use",
            "",
            bullet_lines(card.get("when_to_use")),
            "",
            "## Do",
            "",
            bullet_lines(card.get("do")),
            "",
            "## Avoid",
            "",
            bullet_lines(card.get("avoid")),
            "",
            "## Prompt Patterns",
            "",
            bullet_lines(card.get("prompt_patterns")),
            "",
            "## Examples",
            "",
            bullet_lines(card.get("examples")),
            "",
            "## Source Refs",
            "",
            bullet_lines(card.get("source_refs")),
            "",
        ]
        path.write_text("\n".join(lines), encoding="utf-8")
        return path


def bullet_lines(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        return "\n".join(f"- {item}" for item in value)
    return str(value).strip()


def safe_slug(value: str) -> str:
    cleaned = re.sub(r"\s+", "_", value.strip().lower())
    cleaned = re.sub(r"[^a-z0-9_\-\u4e00-\u9fff]+", "", cleaned)
    cleaned = cleaned.strip("_-")
    return cleaned[:80] or "knowledge"
