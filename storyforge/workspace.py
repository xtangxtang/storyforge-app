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
    def scene_refs_dir(self) -> Path:
        return self.assets_dir / "scene_refs"

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
    def decisions_path(self) -> Path:
        return self.review_dir / "decisions.json"

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
            self.scene_refs_dir,
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
        if not self.decisions_path.exists():
            self.write_json(
                self.decisions_path,
                {
                    "schema": "storyforge-review-decisions-v1",
                    "project_id": self.project_id,
                    "decisions": [],
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

    def refresh_review_index(self) -> dict[str, Any]:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        decisions_doc = self.read_decisions()
        decisions = list(decisions_doc.get("decisions") or [])
        decision_summary = summarize_decisions(decisions)
        runs = list(manifest.get("runs") or [])
        latest_run = runs[-1] if runs else {}
        latest_result = latest_run.get("result") if isinstance(latest_run.get("result"), dict) else {}
        pending_reviews = [
            review_entry(run)
            for run in reversed(runs)
            if isinstance(run.get("result"), dict) and run["result"].get("awaiting_user_review")
        ]
        stage_files = file_entries(self.stages_dir, "*.json", self.root)
        review_files = file_entries(self.review_dir, "*.md", self.root)
        media_files = (
            file_entries(self.assets_dir, "*.png", self.root)
            + file_entries(self.keyframes_dir, "*.png", self.root)
            + file_entries(self.clips_dir, "*.mp4", self.root)
        )
        index = {
            "schema": "storyforge-review-index-v1",
            "project_id": self.project_id,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "current_stage": manifest.get("state", {}).get("current_stage"),
            "latest_run": latest_run,
            "pending_reviews": pending_reviews,
            "next_action": review_next_action(latest_run, latest_result),
            "decisions": decision_summary,
            "recent_decisions": decisions[-12:],
            "stage_files": stage_files,
            "review_files": review_files,
            "media_files": media_files,
            "commands": review_index_commands(self.project_id, latest_run),
        }
        self.write_json(self.review_dir / "index.json", index)
        (self.review_dir / "index.md").write_text(format_review_index_markdown(index), encoding="utf-8")
        return index

    def read_decisions(self) -> dict[str, Any]:
        if not self.decisions_path.exists():
            return {"schema": "storyforge-review-decisions-v1", "project_id": self.project_id, "decisions": []}
        data = json.loads(self.decisions_path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {"schema": "storyforge-review-decisions-v1", "project_id": self.project_id, "decisions": []}

    def append_decision(self, decision: dict[str, Any]) -> dict[str, Any]:
        doc = self.read_decisions()
        decisions = list(doc.get("decisions") or [])
        record = {
            "id": f"decision_{time.strftime('%Y%m%d_%H%M%S')}_{len(decisions) + 1:04d}",
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            **decision,
        }
        decisions.append(record)
        doc = {
            "schema": "storyforge-review-decisions-v1",
            "project_id": self.project_id,
            "updated_at": record["created_at"],
            "decisions": decisions,
        }
        self.write_json(self.decisions_path, doc)
        (self.wiki_dir / "decisions.md").write_text(format_decisions_markdown(doc), encoding="utf-8")
        return record

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
            self.wiki_dir / "scene_bible.md",
            self.wiki_dir / "cross_scene_continuity.md",
            self.wiki_dir / "knowledge.md",
            self.wiki_dir / "continuity.md",
            self.wiki_dir / "decisions.md",
            self.decisions_path,
            self.stage_path("00_style.json"),
            self.stage_path("00b_consistency.json"),
            self.stage_path("00c_scene_bible.json"),
            self.stage_path("00d_scene_reference_plan.json"),
            self.stage_path("00d_scene_references.json"),
            self.stage_path("00e_cross_scene_continuity.json"),
            self.stage_path("01_script.json"),
            self.stage_path("02_assets.json"),
            self.stage_path("03_storyboards.json"),
            self.stage_path("04_atomic_shots.json"),
            self.stage_path("04b_continuity_validation.json"),
            self.stage_path("05_keyframe_plan.json"),
            self.stage_path("05_keyframes.json"),
            self.stage_path("06_videos.json"),
            self.stage_path("06b_scene_transition_plan.json"),
            self.stage_path("06b_scene_transitions.json"),
            self.stage_path("08_stage_rerun_advisor.json"),
            self.stage_path("09_review_decision.json"),
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
    if isinstance(value, dict):
        return "\n".join(f"- {key}: {val}" for key, val in value.items())
    return str(value).strip()


def review_entry(run: dict[str, Any]) -> dict[str, Any]:
    result = run.get("result") if isinstance(run.get("result"), dict) else {}
    return {
        "skill_id": run.get("skill_id"),
        "finished_at": run.get("finished_at"),
        "message": result.get("message"),
        "artifact": result.get("file"),
        "agent_review_file": result.get("agent_review_file"),
        "user_review_file": result.get("user_review_file"),
        "agent_verdict": result.get("agent_verdict"),
        "agent_score": result.get("agent_score"),
        "review_gate_message": result.get("review_gate_message"),
    }


def summarize_decisions(decisions: list[dict[str, Any]]) -> dict[str, Any]:
    latest_by_skill: dict[str, dict[str, Any]] = {}
    pending_revisions = []
    approved = []
    blocked = []
    for decision in decisions:
        skill_id = str(decision.get("skill_id") or "")
        if skill_id:
            latest_by_skill[skill_id] = decision
        status = str(decision.get("decision") or "").lower()
        if status == "approve":
            approved.append(decision)
        elif status in {"revise", "changes_requested"}:
            pending_revisions.append(decision)
        elif status in {"block", "reject"}:
            blocked.append(decision)
    return {
        "total": len(decisions),
        "approved_count": len(approved),
        "pending_revision_count": len(pending_revisions),
        "blocked_count": len(blocked),
        "latest_by_skill": latest_by_skill,
        "pending_revisions": pending_revisions[-12:],
        "blocked": blocked[-12:],
    }


def review_next_action(latest_run: dict[str, Any], latest_result: dict[str, Any]) -> dict[str, Any]:
    if not latest_run:
        return {"type": "start", "message": "还没有运行记录，请先运行 document_ingest 或 script_ingest。"}
    if latest_result.get("awaiting_user_selection"):
        return {"type": "select_style", "message": "等待用户选择风格。", "stage": latest_result.get("file")}
    if latest_result.get("awaiting_user_review"):
        return {
            "type": "review",
            "message": "等待用户审阅当前阶段材料。",
            "skill_id": latest_run.get("skill_id"),
            "user_review_file": latest_result.get("user_review_file"),
            "agent_review_file": latest_result.get("agent_review_file"),
            "artifact": latest_result.get("file"),
        }
    if latest_result.get("validation_blocked"):
        return {"type": "fix_continuity", "message": "连续性验证阻塞，请先修改相关分镜/原子镜头。", "artifact": latest_result.get("file")}
    if latest_result.get("ok") is False:
        return {"type": "fix_failed_stage", "message": "最近阶段失败，请查看 result 和 review 文件。", "skill_id": latest_run.get("skill_id")}
    return {"type": "continue", "message": "最近阶段已完成，可根据 pipeline 继续下一阶段。", "skill_id": latest_run.get("skill_id")}


def file_entries(base: Path, pattern: str, root: Path) -> list[dict[str, Any]]:
    if not base.exists():
        return []
    entries = []
    for path in sorted(base.rglob(pattern), key=lambda p: p.stat().st_mtime, reverse=True):
        if path.is_file():
            entries.append(
                {
                    "path": path.relative_to(root).as_posix(),
                    "name": path.name,
                    "size": path.stat().st_size,
                    "modified_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(path.stat().st_mtime)),
                }
            )
    return entries


def review_index_commands(project_id: str, latest_run: dict[str, Any]) -> dict[str, str]:
    skill_id = str(latest_run.get("skill_id") or "")
    return {
        "list_skills": "python -m storyforge.cli list-skills",
        "rerun_advisor": f"python -m storyforge.cli --project {project_id} advise-rerun --changed-stage <stage.json>",
        "continue_hint": f"python -m storyforge.cli --project {project_id} run <next_skill>",
        "rerun_current": f"python -m storyforge.cli --project {project_id} run {skill_id}" if skill_id else "",
    }


def format_review_index_markdown(index: dict[str, Any]) -> str:
    latest = index.get("latest_run") if isinstance(index.get("latest_run"), dict) else {}
    pending = index.get("pending_reviews") or []
    next_action = index.get("next_action") or {}
    lines = [
        f"# Review Index：{index.get('project_id', '')}",
        "",
        f"- updated_at: {index.get('updated_at', '')}",
        f"- current_stage: {index.get('current_stage', '')}",
        f"- latest_skill: {latest.get('skill_id', '')}",
        "",
        "## 下一步",
        "",
        f"- 类型：{next_action.get('type', '')}",
        f"- 提示：{next_action.get('message', '')}",
        f"- 用户审阅文件：{next_action.get('user_review_file', '')}",
        f"- 阶段产物：{next_action.get('artifact', '')}",
        "",
        "## 待审阅阶段",
        "",
    ]
    if pending:
        for item in pending[:12]:
            lines.extend(
                [
                    f"### {item.get('skill_id', '')}",
                    "",
                    f"- finished_at: {item.get('finished_at', '')}",
                    f"- artifact: {item.get('artifact', '')}",
                    f"- agent_review: {item.get('agent_review_file', '')}",
                    f"- user_review: {item.get('user_review_file', '')}",
                    f"- verdict: {item.get('agent_verdict', '')}",
                    "",
                ]
            )
    else:
        lines.extend(["- 暂无待审阅阶段。", ""])
    lines.extend(
        [
            "## 用户决策",
            "",
            f"- 总数：{(index.get('decisions') or {}).get('total', 0)}",
            f"- 已批准：{(index.get('decisions') or {}).get('approved_count', 0)}",
            f"- 待修改：{(index.get('decisions') or {}).get('pending_revision_count', 0)}",
            f"- 阻塞：{(index.get('decisions') or {}).get('blocked_count', 0)}",
            "",
            "### 最近决策",
            "",
            *[
                f"- {item.get('created_at', '')} {item.get('skill_id', '')}: {item.get('decision', '')} {item.get('scene_id', '')} {item.get('item_id', '')} {item.get('note', '')}"
                for item in (index.get("recent_decisions") or [])[-10:]
            ],
            "",
            "## 最近 Stage 文件",
            "",
            *[f"- {entry['path']} ({entry['modified_at']})" for entry in (index.get("stage_files") or [])[:20]],
            "",
            "## 最近媒体文件",
            "",
            *[f"- {entry['path']} ({entry['modified_at']})" for entry in (index.get("media_files") or [])[:24]],
            "",
            "## 常用命令",
            "",
            bullet_lines(index.get("commands")),
            "",
        ]
    )
    return "\n".join(lines)


def format_decisions_markdown(doc: dict[str, Any]) -> str:
    lines = [
        f"# Review Decisions：{doc.get('project_id', '')}",
        "",
        f"- updated_at: {doc.get('updated_at', '')}",
        "",
    ]
    for item in doc.get("decisions") or []:
        lines.extend(
            [
                f"## {item.get('id', '')}",
                "",
                f"- created_at: {item.get('created_at', '')}",
                f"- skill_id: {item.get('skill_id', '')}",
                f"- decision: {item.get('decision', '')}",
                f"- scene_id: {item.get('scene_id', '')}",
                f"- item_id: {item.get('item_id', '')}",
                f"- changed_stage: {item.get('changed_stage', '')}",
                "",
                "### Note",
                "",
                str(item.get("note", "")).strip(),
                "",
                "### Requested Changes",
                "",
                bullet_lines(item.get("requested_changes")),
                "",
                "### Rerun Recommendations",
                "",
                bullet_lines(item.get("rerun_recommendations")),
                "",
            ]
        )
    return "\n".join(lines)


def safe_slug(value: str) -> str:
    cleaned = re.sub(r"\s+", "_", value.strip().lower())
    cleaned = re.sub(r"[^a-z0-9_\-\u4e00-\u9fff]+", "", cleaned)
    cleaned = cleaned.strip("_-")
    return cleaned[:80] or "knowledge"
