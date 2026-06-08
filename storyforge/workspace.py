from __future__ import annotations

import json
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

    def ensure(self) -> None:
        for folder in [
            self.raw_dir,
            self.wiki_dir,
            self.stages_dir,
            self.assets_dir,
            self.keyframes_dir,
            self.clips_dir,
            self.review_dir,
            self.root / "archive",
        ]:
            folder.mkdir(parents=True, exist_ok=True)
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
        for path in [
            self.raw_dir / "script.md",
            self.wiki_dir / "knowledge.md",
            self.wiki_dir / "continuity.md",
            self.stage_path("01_script.json"),
            self.stage_path("02_assets.json"),
            self.stage_path("03_storyboards.json"),
        ]:
            if path.exists():
                parts.append(f"---\nsource: {path.relative_to(self.root)}\n\n{path.read_text(encoding='utf-8')[:12000]}")
        return "\n\n".join(parts)
