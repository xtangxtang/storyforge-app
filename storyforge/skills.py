from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from .services import ArkClient, LLMClient
from .workspace import ProjectWorkspace

CHINESE_OUTPUT_RULE = "所有面向用户和创作内容必须使用简体中文；JSON 字段名、文件名、skill id 可以保持英文。"


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
            if not input_data.get("auto_continue_after_review"):
                result.data.setdefault("awaiting_user_review", True)
                result.data.setdefault(
                    "review_gate_message",
                    "阶段产物已生成并完成 agent 审阅，请先查看 user_review_file 后再继续下一阶段。",
                )
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
    review_artifact_text = review_text_window(artifact_text)

    agent_review_path = ctx.workspace.review_dir / f"agent_{skill_id}.md"
    user_review_path = ctx.workspace.review_dir / f"user_{skill_id}.md"
    try:
        review = ctx.llm.chat_json(
            "你是 Storyforge 的 stage_review_agent。你要在用户看到材料之前，先审阅一个已经完成的生产阶段。输出严格 JSON，字段包括 score(1-10), verdict(approve|revise|block), strengths, risks, continuity_checks, concrete_revision_requests, user_review_focus, knowledge_capture_candidates。判断要直接、面向制片执行，重点检查故事保真、连续性、物理逻辑、prompt 可用性、字段完整性、下一阶段是否有足够信息。所有字段值必须使用简体中文。",
            (
                f"输出语言规则：{CHINESE_OUTPUT_RULE}\n"
                f"Skill id: {skill_id}\n"
                f"Skill description: {description}\n"
                f"Result message: {result.message}\n"
                f"Artifact ref: {artifact_ref}\n\n"
                f"Artifact content:\n{review_artifact_text}"
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
            "risks": [f"审阅 agent 执行失败：{exc}"],
            "user_review_focus": ["agent 审阅失败，请人工检查该阶段产物。"],
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


def review_text_window(text: str, limit: int = 80000) -> str:
    if len(text) <= limit:
        return text
    half = limit // 2
    omitted = len(text) - limit
    return (
        text[:half]
        + f"\n\n[中间省略 {omitted} 个字符；以下为文件末尾，供审阅 agent 检查收束与截断问题]\n\n"
        + text[-half:]
    )


def write_agent_review_markdown(path: Path, skill_id: str, artifact_ref: str, review: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                f"# Agent 审阅：{skill_id}",
                "",
                f"- artifact: {artifact_ref or 'n/a'}",
                f"- 评分: {review.get('score')}",
                f"- 结论: {review.get('verdict')}",
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
        f"# 用户审阅材料包：{skill_id}",
        "",
        "## Agent 结论",
        "",
        f"- 评分: {review.get('score')}",
        f"- 结论: {review.get('verdict')}",
        "",
        "## 你需要重点确认",
        "",
        bullet_lines(review.get("user_review_focus")),
        "",
        "## 修改建议",
        "",
        bullet_lines(review.get("concrete_revision_requests")),
        "",
        "## 风险",
        "",
        bullet_lines(review.get("risks")),
        "",
        "## 连续性检查",
        "",
        bullet_lines(review.get("continuity_checks")),
        "",
        "## 可沉淀知识",
        "",
        bullet_lines(review.get("knowledge_capture_candidates")),
        "",
        "## 阶段产物",
        "",
        f"- artifact: {artifact_ref or 'n/a'}",
        "",
        "```json",
        review_text_window(artifact_text, limit=120000),
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
