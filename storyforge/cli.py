from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .config import load_config
from .default_skills import default_registry
from .document import derive_project_id, extract_document_text
from .services import ArkClient, LLMClient
from .skills import SkillContext, SkillRunner
from .workspace import ProjectWorkspace


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="storyforge")
    parser.add_argument("--project", help="Project id. If omitted for document/script pipelines, Storyforge derives one from the document.")
    parser.add_argument("--projects-root", default="projects", help="Projects root directory")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list-skills")

    run = sub.add_parser("run")
    run.add_argument("skill_id")
    run.add_argument("--input-json", default="{}", help="JSON object passed to the skill")

    pipe = sub.add_parser("pipeline-from-script")
    pipe.add_argument("--script", required=True, help="Path to script text/markdown")
    pipe.add_argument("--style", help="Production style id, for example film, short_drama, comic_drama, anime, documentary")
    pipe.add_argument("--style-note", default="", help="Optional custom style note")
    pipe.add_argument("--with-media", action="store_true", help="Import existing Codex keyframes and run Ark video generation")
    pipe.add_argument("--auto-continue", action="store_true", help="Run every stage without stopping at user review gates")

    doc_pipe = sub.add_parser("pipeline-from-document")
    doc_pipe.add_argument("--document", required=True, help="Path to txt, md, docx, or pdf script document")
    doc_pipe.add_argument("--style", help="Production style id, for example film, short_drama, comic_drama, anime, documentary")
    doc_pipe.add_argument("--style-note", default="", help="Optional custom style note")
    doc_pipe.add_argument("--with-media", action="store_true", help="Import existing Codex keyframes and run Ark video generation")
    doc_pipe.add_argument("--auto-continue", action="store_true", help="Run every stage without stopping at user review gates")

    args = parser.parse_args(argv)
    registry = default_registry()

    if args.cmd == "list-skills":
        print(json.dumps(registry.describe(), ensure_ascii=False, indent=2))
        return 0

    if args.cmd == "run" and not args.project:
        print("--project is required for `run`", file=sys.stderr)
        return 2

    projects_root = Path(args.projects_root)
    project_id = resolve_project_id(args, projects_root)

    config = load_config(Path.cwd())
    llm = LLMClient(config)
    ark = ArkClient(config, llm)
    workspace = ProjectWorkspace.open(project_id, root=projects_root)
    runner = SkillRunner(registry, SkillContext(workspace=workspace, llm=llm, ark=ark))

    if args.cmd == "run":
        try:
            input_data = json.loads(args.input_json)
        except json.JSONDecodeError as exc:
            print(f"Invalid --input-json: {exc}", file=sys.stderr)
            return 2
        result = runner.run(args.skill_id, input_data)
        print(json.dumps({"ok": result.ok, "message": result.message, **result.data}, ensure_ascii=False, indent=2))
        return 0 if result.ok else 1

    if args.cmd == "pipeline-from-script":
        sequence = ["script_ingest", "style_select", "consistency_bible", "asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan"]
        if args.with_media:
            sequence.extend(["keyframe_import", "video_generate_ark"])
        script_path = Path(args.script)
        script_input = {"script_path": str(script_path)}
        style_input = {"style": args.style, "style_note": args.style_note} if args.style else {"force_prompt": True}
        print(json.dumps({"project_id": project_id, "project_root": str(workspace.root)}, ensure_ascii=False))
        for skill_id in sequence:
            if skill_id == "script_ingest":
                current_input = script_input
            elif skill_id == "style_select":
                current_input = style_input
            else:
                current_input = {}
            if args.auto_continue:
                current_input = {**current_input, "auto_continue_after_review": True}
            result = runner.run(skill_id, current_input)
            print(json.dumps({"skill": skill_id, "ok": result.ok, "message": result.message, **result.data}, ensure_ascii=False))
            if not result.ok:
                return 1
            if result.data.get("awaiting_user_selection"):
                return 0
            if should_pause_for_user_review(result.data, args.auto_continue):
                print(json.dumps(review_pause_payload(project_id, skill_id, sequence), ensure_ascii=False))
                return 0
        return 0

    if args.cmd == "pipeline-from-document":
        sequence = ["document_ingest", "script_ingest", "style_select", "consistency_bible", "asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan"]
        if args.with_media:
            sequence.extend(["keyframe_import", "video_generate_ark"])
        document_input = {"document_path": str(Path(args.document))}
        style_input = {"style": args.style, "style_note": args.style_note} if args.style else {"force_prompt": True}
        print(json.dumps({"project_id": project_id, "project_root": str(workspace.root)}, ensure_ascii=False))
        for skill_id in sequence:
            if skill_id == "document_ingest":
                current_input = document_input
            elif skill_id == "style_select":
                current_input = style_input
            else:
                current_input = {}
            if args.auto_continue:
                current_input = {**current_input, "auto_continue_after_review": True}
            result = runner.run(skill_id, current_input)
            print(json.dumps({"skill": skill_id, "ok": result.ok, "message": result.message, **result.data}, ensure_ascii=False))
            if not result.ok:
                return 1
            if result.data.get("awaiting_user_selection"):
                return 0
            if should_pause_for_user_review(result.data, args.auto_continue):
                print(json.dumps(review_pause_payload(project_id, skill_id, sequence), ensure_ascii=False))
                return 0
        return 0

    return 2


def resolve_project_id(args: argparse.Namespace, projects_root: Path) -> str:
    if args.project:
        return args.project
    if args.cmd == "pipeline-from-document":
        extracted = extract_document_text(Path(args.document))
        return derive_project_id(extracted["source_name"], extracted["text"], existing_project_ids(projects_root))
    if args.cmd == "pipeline-from-script":
        extracted = extract_document_text(Path(args.script))
        return derive_project_id(extracted["source_name"], extracted["text"], existing_project_ids(projects_root))
    return "default"


def existing_project_ids(projects_root: Path) -> set[str]:
    if not projects_root.exists():
        return set()
    return {path.name for path in projects_root.iterdir() if path.is_dir()}


def should_pause_for_user_review(result_data: dict[str, object], auto_continue: bool) -> bool:
    return bool(result_data.get("awaiting_user_review")) and not auto_continue


def review_pause_payload(project_id: str, current_skill: str, sequence: list[str]) -> dict[str, object]:
    try:
        current_index = sequence.index(current_skill)
    except ValueError:
        current_index = -1
    next_skill = sequence[current_index + 1] if 0 <= current_index + 1 < len(sequence) else None
    payload: dict[str, object] = {
        "paused": True,
        "reason": "awaiting_user_review",
        "project_id": project_id,
        "current_skill": current_skill,
        "message": "阶段产物已生成并完成 agent 审阅。请先查看 review/user_<skill>.md，确认后再运行下一阶段。",
    }
    if next_skill:
        payload["next_skill"] = next_skill
        payload["next_command"] = f"python -m storyforge.cli --project {project_id} run {next_skill}"
    return payload


if __name__ == "__main__":
    raise SystemExit(main())
