from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from .services import ArkClient, LLMClient
from .workspace import ProjectWorkspace


@dataclass
class SkillContext:
    workspace: ProjectWorkspace
    llm: LLMClient
    ark: ArkClient


@dataclass
class SkillResult:
    ok: bool
    message: str
    data: dict[str, Any]


class Skill(Protocol):
    id: str
    description: str

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        ...


class SkillRegistry:
    def __init__(self, skills: list[Skill]):
        self.skills = {skill.id: skill for skill in skills}

    def get(self, skill_id: str) -> Skill:
        if skill_id not in self.skills:
            raise KeyError(f"Unknown skill: {skill_id}")
        return self.skills[skill_id]

    def describe(self) -> dict[str, Any]:
        return {
            "skills": [
                {"id": skill.id, "description": skill.description}
                for skill in self.skills.values()
            ]
        }


class SkillRunner:
    def __init__(self, registry: SkillRegistry, ctx: SkillContext):
        self.registry = registry
        self.ctx = ctx

    def run(self, skill_id: str, input_data: dict[str, Any] | None = None) -> SkillResult:
        input_data = input_data or {}
        started = time.strftime("%Y-%m-%dT%H:%M:%S")
        skill = self.registry.get(skill_id)
        result = skill.run(self.ctx, input_data)
        if result.ok and not input_data.get("skip_agent_review"):
            review = review_stage_output(self.ctx, skill_id, skill.description, result)
            result.data.update(review)
        finished = time.strftime("%Y-%m-%dT%H:%M:%S")
        self.ctx.workspace.add_run(
            {
                "skill_id": skill_id,
                "started_at": started,
                "finished_at": finished,
                "input": input_data,
                "result": {"ok": result.ok, "message": result.message, **result.data},
            }
        )
        return result


def review_stage_output(ctx: SkillContext, skill_id: str, description: str, result: SkillResult) -> dict[str, Any]:
    artifact_ref = str(result.data.get("file") or "")
    artifact_text = read_artifact_text(ctx.workspace, artifact_ref)
    if not artifact_text:
        artifact_text = json.dumps({"message": result.message, **result.data}, ensure_ascii=False, indent=2)

    agent_review_path = ctx.workspace.review_dir / f"agent_{skill_id}.md"
    user_review_path = ctx.workspace.review_dir / f"user_{skill_id}.md"
    try:
        review = ctx.llm.chat_json(
            "You are Storyforge stage_review_agent. Review one completed production stage before the user sees it. Output strict JSON with score 1-10, verdict approve|revise|block, strengths, risks, continuity_checks, concrete_revision_requests, user_review_focus, and knowledge_capture_candidates. Be direct and production-minded. Check story preservation, continuity, physical plausibility, prompt usefulness, missing fields, and whether the next stage has enough information.",
            (
                f"Skill id: {skill_id}\n"
                f"Skill description: {description}\n"
                f"Result message: {result.message}\n"
                f"Artifact ref: {artifact_ref}\n\n"
                f"Artifact content:\n{artifact_text[:24000]}"
            ),
            temperature=0.1,
            tag=f"stage_review:{skill_id}",
        )
        write_agent_review_markdown(agent_review_path, skill_id, artifact_ref, review)
        write_user_review_package(user_review_path, skill_id, artifact_ref, artifact_text, review)
        return {
            "agent_review_file": agent_review_path.relative_to(ctx.workspace.root).as_posix(),
            "user_review_file": user_review_path.relative_to(ctx.workspace.root).as_posix(),
            "agent_verdict": review.get("verdict"),
            "agent_score": review.get("score"),
        }
    except Exception as exc:
        fallback = {
            "score": None,
            "verdict": "review_failed",
            "risks": [str(exc)],
            "user_review_focus": ["Agent review failed; inspect the stage artifact manually."],
        }
        write_agent_review_markdown(agent_review_path, skill_id, artifact_ref, fallback)
        write_user_review_package(user_review_path, skill_id, artifact_ref, artifact_text, fallback)
        return {
            "agent_review_file": agent_review_path.relative_to(ctx.workspace.root).as_posix(),
            "user_review_file": user_review_path.relative_to(ctx.workspace.root).as_posix(),
            "agent_verdict": "review_failed",
            "agent_review_error": str(exc),
        }


def read_artifact_text(workspace: ProjectWorkspace, artifact_ref: str) -> str:
    if not artifact_ref:
        return ""
    path = Path(artifact_ref)
    if not path.is_absolute():
        path = workspace.root / path
    if not path.exists() or not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return f"[binary artifact: {path}]"


def write_agent_review_markdown(path: Path, skill_id: str, artifact_ref: str, review: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                f"# Agent Review: {skill_id}",
                "",
                f"- artifact: {artifact_ref or 'n/a'}",
                f"- score: {review.get('score')}",
                f"- verdict: {review.get('verdict')}",
                "",
                "```json",
                json.dumps(review, ensure_ascii=False, indent=2),
                "```",
                "",
            ]
        ),
        encoding="utf-8",
    )


def write_user_review_package(path: Path, skill_id: str, artifact_ref: str, artifact_text: str, review: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# User Review Package: {skill_id}",
        "",
        "## Agent Verdict",
        "",
        f"- score: {review.get('score')}",
        f"- verdict: {review.get('verdict')}",
        "",
        "## What To Check",
        "",
        bullet_lines(review.get("user_review_focus")),
        "",
        "## Revision Requests",
        "",
        bullet_lines(review.get("concrete_revision_requests")),
        "",
        "## Risks",
        "",
        bullet_lines(review.get("risks")),
        "",
        "## Continuity Checks",
        "",
        bullet_lines(review.get("continuity_checks")),
        "",
        "## Knowledge Candidates",
        "",
        bullet_lines(review.get("knowledge_capture_candidates")),
        "",
        "## Stage Artifact",
        "",
        f"- artifact: {artifact_ref or 'n/a'}",
        "",
        "```json",
        artifact_text[:30000],
        "```",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def write_review_markdown(path: Path, title: str, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"# {title}\n\n```json\n{json.dumps(payload, ensure_ascii=False, indent=2)}\n```\n",
        encoding="utf-8",
    )


def bullet_lines(value: Any) -> str:
    if not value:
        return ""
    if isinstance(value, list):
        return "\n".join(f"- {item}" for item in value)
    if isinstance(value, dict):
        return "\n".join(f"- {key}: {val}" for key, val in value.items())
    return f"- {value}"
