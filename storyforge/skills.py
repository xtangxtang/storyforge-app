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


def write_review_markdown(path: Path, title: str, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"# {title}\n\n```json\n{json.dumps(payload, ensure_ascii=False, indent=2)}\n```\n",
        encoding="utf-8",
    )
