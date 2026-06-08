from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .skills import SkillContext, SkillRegistry, SkillResult, write_review_markdown


class ScriptIngestSkill:
    id = "script_ingest"
    description = "Normalize a provided script into scenes/assets without rewriting the story."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script_text = (input_data.get("script_text") or "").strip()
        script_path = input_data.get("script_path")
        if not script_text and script_path:
            script_text = Path(script_path).read_text(encoding="utf-8")
        if not script_text:
            return SkillResult(False, "Missing script_text or script_path", {})

        ctx.workspace.raw_dir.joinpath("script.md").write_text(script_text, encoding="utf-8")
        data = ctx.llm.chat_json(
            "You are Storyforge script_ingest. Structure the user's existing script into strict JSON without changing story, characters, locations, dialogue, or event order. Output JSON with scenes and assets. Each scene has scene_num, location, description, action, dialogue, duration. Each asset has type character|location|prop, name, description.",
            script_text,
            temperature=0.2,
            tag=self.id,
        )
        data.setdefault("source", self.id)
        ctx.workspace.write_stage("01_script.json", data)
        write_review_markdown(ctx.workspace.review_dir / "01_script.md", "Script Ingest Review", data)
        ctx.workspace.append_log("Script ingested", {"scenes": len(data.get("scenes", [])), "assets": len(data.get("assets", []))})
        return SkillResult(True, "script ingested", {"file": "stages/01_script.json"})


class AssetDesignSkill:
    id = "asset_design"
    description = "Design visual anchors and reusable image prompts for characters, locations, and props."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        assets = list(script.get("assets") or [])
        if not assets:
            return SkillResult(False, "No assets found in stages/01_script.json", {})
        data = ctx.llm.chat_json(
            "You are Storyforge asset_design. Output strict JSON {assets:[...]}. For each provided asset, preserve type/name/description and add visual_anchor_prompt, negative_prompt, and consistency_notes. Prompts must be concrete enough for image generation, not poster-like, not a collage, and must preserve identity/clothing/location details across later shots.",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nAssets:\n{json.dumps(assets, ensure_ascii=False)}",
            temperature=float(input_data.get("temperature", 0.2)),
            tag=self.id,
        )
        designed = list(data.get("assets") or [])
        if not designed:
            designed = [
                {
                    **asset,
                    "visual_anchor_prompt": (
                        f"Stable production reference for {asset.get('type', 'asset')} {asset.get('name', '')}. "
                        f"{asset.get('description', '')}. Clear reusable identity, no poster, no collage."
                    ),
                    "negative_prompt": "poster, collage, text sheet, UI, inconsistent costume",
                    "consistency_notes": "Use as identity/location anchor for later keyframes.",
                }
                for asset in assets
            ]
        out = {"source": self.id, "assets": designed}
        ctx.workspace.write_stage("02_assets.json", out)
        write_review_markdown(ctx.workspace.review_dir / "02_assets.md", "Asset Design Review", out)
        return SkillResult(True, "asset prompts designed", {"file": "stages/02_assets.json", "count": len(designed)})


class StoryboardPlanSkill:
    id = "storyboard_plan"
    description = "Create reviewable storyboard beats from the structured script and workspace memory."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script.get("scenes"):
            return SkillResult(False, "No scenes found in stages/01_script.json", {})
        data = ctx.llm.chat_json(
            "You are Storyforge storyboard_plan. Create strict JSON {storyboards:[...]}. Each beat has id, scene_num, shot_num, location, duration 3-8, characters, props, description, first_frame_prompt, video_prompt, continuity. Preserve story. Split hard physical actions into smaller beats or cutaways.",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nScript JSON:\n{json.dumps(script, ensure_ascii=False)}",
            temperature=float(input_data.get("temperature", 0.25)),
            tag=self.id,
        )
        storyboards = list(data.get("storyboards") or [])
        for idx, sb in enumerate(storyboards, 1):
            sb.setdefault("id", f"sb_{idx:03d}")
        out = {"source": self.id, "storyboards": storyboards}
        ctx.workspace.write_stage("03_storyboards.json", out)
        write_review_markdown(ctx.workspace.review_dir / "03_storyboards.md", "Storyboard Review", out)
        return SkillResult(True, "storyboards planned", {"file": "stages/03_storyboards.json", "count": len(storyboards)})


class AtomicShotPlanSkill:
    id = "atomic_shot_plan"
    description = "Split storyboard beats into physically plausible atomic shots with start/end states."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        boards = ctx.workspace.read_stage("03_storyboards.json")
        storyboards = list(boards.get("storyboards") or [])
        if not storyboards:
            return SkillResult(False, "No storyboards found", {})
        data = ctx.llm.chat_json(
            "You are Storyforge atomic_shot_plan. Output strict JSON {atomic_shots:[...]}. Each atomic shot has id, storyboard_id, duration, purpose, first_frame_prompt, last_frame_prompt, video_prompt, continuity_state_start, continuity_state_end, reference_asset_names. One action intent per shot. Use cutaways for collisions and other hard physics. Adjacent shots must share states.",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nStoryboards:\n{json.dumps(storyboards, ensure_ascii=False)}",
            temperature=0.2,
            tag=self.id,
        )
        atoms = list(data.get("atomic_shots") or [])
        for idx, atom in enumerate(atoms, 1):
            atom.setdefault("id", f"atom_{idx:03d}")
        out = {"source": self.id, "atomic_shots": atoms}
        ctx.workspace.write_stage("04_atomic_shots.json", out)
        write_review_markdown(ctx.workspace.review_dir / "04_atomic_shots.md", "Atomic Shot Review", out)
        return SkillResult(True, "atomic shots planned", {"file": "stages/04_atomic_shots.json", "count": len(atoms)})


class KeyframeGenerateSkill:
    id = "keyframe_generate"
    description = "Generate first/last control frames for atomic shots."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        atoms = list(ctx.workspace.read_stage("04_atomic_shots.json").get("atomic_shots") or [])
        if not atoms:
            return SkillResult(False, "No atomic shots found", {})
        asset_context = load_asset_context(ctx)
        keyframes = []
        for atom in atoms:
            atom_id = str(atom.get("id"))
            named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
            refs = [str(asset["reference_image_url"]) for asset in named_assets if asset.get("reference_image_url")]
            first_url = ctx.ark.generate_image(
                frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets),
                refs=refs,
            )
            first_path = ctx.ark.download(first_url, ctx.workspace.keyframes_dir / f"{safe_name(atom_id)}_first.png")
            last_url = ctx.ark.generate_image(
                frame_prompt(str(atom.get("last_frame_prompt", "")), named_assets),
                refs=[first_url, *refs],
            )
            last_path = ctx.ark.download(last_url, ctx.workspace.keyframes_dir / f"{safe_name(atom_id)}_last.png")
            keyframes.append(
                {
                    "atomic_shot_id": atom_id,
                    "storyboard_id": atom.get("storyboard_id"),
                    "duration": atom.get("duration", 5),
                    "video_prompt": atom.get("video_prompt", ""),
                    "first_frame_url": first_url,
                    "first_frame_local_path": str(first_path),
                    "last_frame_url": last_url,
                    "last_frame_local_path": str(last_path),
                }
            )
        out = {"source": self.id, "keyframes": keyframes}
        ctx.workspace.write_stage("05_keyframes.json", out)
        write_review_markdown(ctx.workspace.review_dir / "05_keyframes.md", "Keyframe Review", out)
        return SkillResult(True, "keyframes generated", {"file": "stages/05_keyframes.json", "count": len(keyframes)})


class VideoGenerateArkSkill:
    id = "video_generate_ark"
    description = "Generate Ark Seedance clips from keyframes."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        keyframes = list(ctx.workspace.read_stage("05_keyframes.json").get("keyframes") or [])
        if not keyframes:
            return SkillResult(False, "No keyframes found", {})
        clips = []
        previous: str | None = None
        for kf in keyframes:
            try:
                url = ctx.ark.generate_video(
                    str(kf.get("video_prompt", "")),
                    str(kf.get("first_frame_url", "")),
                    duration=int(kf.get("duration") or 5),
                    reference_video_urls=[previous] if previous else None,
                )
                previous = url
                local = ctx.ark.download(url, ctx.workspace.clips_dir / f"{safe_name(str(kf.get('atomic_shot_id')))}.mp4")
                clips.append({**kf, "state": "ready", "video_url": url, "video_local_path": str(local)})
            except Exception as exc:
                clips.append({**kf, "state": "failed", "error": str(exc)})
        out = {"source": self.id, "clips": clips, "success": sum(c.get("state") == "ready" for c in clips), "failed": sum(c.get("state") == "failed" for c in clips)}
        ctx.workspace.write_stage("06_videos.json", out)
        write_review_markdown(ctx.workspace.review_dir / "06_videos.md", "Video Review", out)
        return SkillResult(True, "video generation completed", {"file": "stages/06_videos.json", "success": out["success"], "failed": out["failed"]})


def default_registry() -> SkillRegistry:
    return SkillRegistry([
        ScriptIngestSkill(),
        AssetDesignSkill(),
        StoryboardPlanSkill(),
        AtomicShotPlanSkill(),
        KeyframeGenerateSkill(),
        VideoGenerateArkSkill(),
    ])


def load_asset_context(ctx: SkillContext) -> dict[str, dict[str, Any]]:
    refs: dict[str, dict[str, Any]] = {}
    for asset in ctx.workspace.read_stage("02_assets.json").get("assets", []) or []:
        name = asset.get("name")
        if name:
            refs[str(name)] = dict(asset)
    return refs


def frame_prompt(prompt: str, assets: list[dict[str, Any]] | None = None) -> str:
    asset_lines = []
    for asset in assets or []:
        asset_lines.append(
            f"- {asset.get('type', 'asset')} {asset.get('name', '')}: "
            f"{asset.get('description', '')} "
            f"Visual anchor: {asset.get('visual_anchor_prompt', '')} "
            f"Consistency: {asset.get('consistency_notes', '')}"
        )
    asset_context = "\n".join(asset_lines)
    base = (
        "Vertical 9:16 cinematic control frame for image-to-video. Preserve identity, clothing, props, location, "
        "movement direction, and physical state. No poster, no chart, no UI, no text sheet, no collage.\n\n"
    )
    if asset_context:
        base += f"Referenced asset anchors:\n{asset_context}\n\n"
    return base + prompt


def safe_name(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)
    return cleaned.strip("_") or "item"
