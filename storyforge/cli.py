from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .config import load_config
from .default_skills import default_registry
from .services import ArkClient, LLMClient
from .skills import SkillContext, SkillRunner
from .workspace import ProjectWorkspace


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="storyforge")
    parser.add_argument("--project", default="default", help="Project id")
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

    args = parser.parse_args(argv)
    registry = default_registry()

    if args.cmd == "list-skills":
        print(json.dumps(registry.describe(), ensure_ascii=False, indent=2))
        return 0

    config = load_config(Path.cwd())
    llm = LLMClient(config)
    ark = ArkClient(config, llm)
    workspace = ProjectWorkspace.open(args.project, root=Path(args.projects_root))
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
        sequence = ["script_ingest", "style_select", "asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan"]
        if args.with_media:
            sequence.extend(["keyframe_import", "video_generate_ark"])
        script_path = Path(args.script)
        script_input = {"script_path": str(script_path)}
        style_input = {"style": args.style, "style_note": args.style_note} if args.style else {"force_prompt": True}
        for skill_id in sequence:
            if skill_id == "script_ingest":
                current_input = script_input
            elif skill_id == "style_select":
                current_input = style_input
            else:
                current_input = {}
            result = runner.run(skill_id, current_input)
            print(json.dumps({"skill": skill_id, "ok": result.ok, "message": result.message, **result.data}, ensure_ascii=False))
            if not result.ok:
                return 1
            if result.data.get("awaiting_user_selection"):
                return 0
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
