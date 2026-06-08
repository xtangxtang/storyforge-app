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


class StyleSelectSkill:
    id = "style_select"
    description = "Ask the user to choose a production style and persist the selected style profile."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script:
            return SkillResult(False, "No script found in stages/01_script.json", {})

        selected = str(input_data.get("style") or input_data.get("style_id") or "").strip()
        custom_note = str(input_data.get("style_note") or input_data.get("custom_style") or "").strip()
        existing = ctx.workspace.read_stage("00_style.json")
        if not selected and existing.get("status") == "selected" and not input_data.get("force_prompt"):
            return SkillResult(True, "style already selected", {"file": "stages/00_style.json", "style": existing.get("style", {}).get("id")})
        options = style_options()
        options_by_id = {option["id"]: option for option in options}

        if not selected:
            out = {
                "source": self.id,
                "status": "awaiting_selection",
                "prompt": "请选择本片的生产风格。后续所有角色设计、分镜、原子镜头、关键帧 prompt 和视频 prompt 都会按该风格构建。",
                "options": options,
                "how_to_continue": "Run style_select with one of the option ids, for example: {\"style\":\"film\"}.",
            }
            ctx.workspace.write_stage("00_style.json", out)
            write_review_markdown(ctx.workspace.review_dir / "00_style_select.md", "Style Selection Prompt", out)
            return SkillResult(True, "awaiting style selection", {"file": "stages/00_style.json", "awaiting_user_selection": True})

        profile = options_by_id.get(selected)
        if profile is None:
            profile = {
                "id": "custom",
                "label": selected,
                "description": custom_note or selected,
                "visual_rules": [custom_note or selected],
                "storyboard_rules": ["Follow the user's custom style consistently across all stages."],
                "prompt_rules": ["Inject the custom style into every visual and video prompt."],
                "avoid": ["Do not drift into a different genre or platform language."],
            }
        if custom_note:
            profile = {**profile, "user_note": custom_note}

        out = {
            "source": self.id,
            "status": "selected",
            "style": profile,
            "prompt_contract": {
                "applies_to": ["asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan", "keyframe_generate_ark", "video_generate_ark"],
                "rule": "All downstream prompts must explicitly preserve this style profile unless the user changes it.",
            },
        }
        ctx.workspace.write_stage("00_style.json", out)
        ctx.workspace.wiki_dir.joinpath("style.md").write_text(format_style_markdown(profile), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00_style_select.md", "Style Selection Review", out)
        ctx.workspace.append_log("Style selected", {"style": profile.get("id"), "label": profile.get("label")})
        return SkillResult(True, "style selected", {"file": "stages/00_style.json", "style": profile.get("id")})


class AssetDesignSkill:
    id = "asset_design"
    description = "Design visual anchors and reusable image prompts for characters, locations, and props."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        assets = list(script.get("assets") or [])
        if not assets:
            return SkillResult(False, "No assets found in stages/01_script.json", {})
        data = ctx.llm.chat_json(
            "You are Storyforge asset_design. Output strict JSON {assets:[...]}. For each provided asset, preserve type/name/description and add visual_anchor_prompt, negative_prompt, and consistency_notes. Prompts must be concrete enough for image generation, not poster-like, not a collage, and must preserve identity/clothing/location details across later shots. You must follow the selected Style Profile from workspace context.",
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
            "You are Storyforge storyboard_plan. Create strict JSON {storyboards:[...]}. Each beat has id, scene_num, shot_num, location, duration 3-8, characters, props, description, first_frame_prompt, video_prompt, continuity. Preserve story. Split hard physical actions into smaller beats or cutaways. Every beat and prompt must follow the selected Style Profile from workspace context.",
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
            "You are Storyforge atomic_shot_plan. Output strict JSON {atomic_shots:[...]}. Each atomic shot has id, storyboard_id, duration, purpose, first_frame_prompt, last_frame_prompt, video_prompt, continuity_state_start, continuity_state_end, reference_asset_names. One action intent per shot. Use cutaways for collisions and other hard physics. Adjacent shots must share states. Every image/video prompt must follow the selected Style Profile from workspace context.",
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


class KeyframePlanSkill:
    id = "keyframe_plan"
    description = "Plan first/last keyframe image tasks for Codex-assisted image generation."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        atoms = list(ctx.workspace.read_stage("04_atomic_shots.json").get("atomic_shots") or [])
        if not atoms:
            return SkillResult(False, "No atomic shots found", {})
        asset_context = load_asset_context(ctx)
        style_context = load_style_context(ctx)
        tasks = []
        for atom in atoms:
            atom_id = str(atom.get("id"))
            named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
            first_path = Path("keyframes") / f"{safe_name(atom_id)}_first.png"
            last_path = Path("keyframes") / f"{safe_name(atom_id)}_last.png"
            tasks.append(
                {
                    "atomic_shot_id": atom_id,
                    "storyboard_id": atom.get("storyboard_id"),
                    "duration": atom.get("duration", 5),
                    "video_prompt": atom.get("video_prompt", ""),
                    "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context),
                    "last_frame_prompt": frame_prompt(str(atom.get("last_frame_prompt", "")), named_assets, style_context),
                    "first_frame_local_path": str(first_path),
                    "last_frame_local_path": str(last_path),
                    "status": "needs_codex_image_generation",
                }
            )
        out = {"source": self.id, "image_provider": "codex", "keyframe_tasks": tasks}
        ctx.workspace.write_stage("05_keyframe_plan.json", out)
        write_review_markdown(ctx.workspace.review_dir / "05_keyframe_plan.md", "Keyframe Plan Review", out)
        return SkillResult(True, "keyframe image tasks planned", {"file": "stages/05_keyframe_plan.json", "count": len(tasks)})


class KeyframeImportSkill:
    id = "keyframe_import"
    description = "Import Codex-created local keyframe images into stages/05_keyframes.json."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("05_keyframe_plan.json")
        tasks = list(plan.get("keyframe_tasks") or [])
        explicit_images = normalize_keyframe_images(input_data.get("images") or input_data.get("keyframes") or [])
        if not tasks and not explicit_images:
            return SkillResult(False, "No keyframe plan or input images found", {})

        imported = []
        missing = []
        source_rows = tasks or list(explicit_images.values())
        for row in source_rows:
            atom_id = str(row.get("atomic_shot_id") or row.get("id") or "")
            if not atom_id:
                missing.append({"reason": "missing atomic_shot_id", "row": row})
                continue
            explicit = explicit_images.get(atom_id, {}) if isinstance(explicit_images, dict) else {}
            first_path = resolve_workspace_path(ctx, explicit.get("first_frame_local_path") or row.get("first_frame_local_path"))
            last_path = resolve_workspace_path(ctx, explicit.get("last_frame_local_path") or row.get("last_frame_local_path"))
            row_missing = []
            if not first_path or not first_path.exists():
                row_missing.append("first_frame_local_path")
            if not last_path or not last_path.exists():
                row_missing.append("last_frame_local_path")
            if row_missing:
                missing.append({"atomic_shot_id": atom_id, "missing": row_missing, "expected": {"first": str(first_path), "last": str(last_path)}})
                continue
            imported.append(
                {
                    "atomic_shot_id": atom_id,
                    "storyboard_id": row.get("storyboard_id"),
                    "duration": row.get("duration", 5),
                    "video_prompt": row.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "last_frame_local_path": str(last_path),
                    "image_provider": "codex",
                    "status": "imported",
                }
            )

        out = {"source": self.id, "image_provider": "codex", "keyframes": imported, "missing": missing}
        ctx.workspace.write_stage("05_keyframes.json", out)
        write_review_markdown(ctx.workspace.review_dir / "05_keyframes.md", "Keyframe Import Review", out)
        ok = len(imported) > 0 and not missing
        message = "keyframes imported" if ok else "keyframe import incomplete"
        return SkillResult(ok, message, {"file": "stages/05_keyframes.json", "imported": len(imported), "missing": len(missing)})


class KeyframeGenerateArkSkill:
    id = "keyframe_generate_ark"
    description = "Optional fallback: generate first/last control frames via Ark image generation."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        atoms = list(ctx.workspace.read_stage("04_atomic_shots.json").get("atomic_shots") or [])
        if not atoms:
            return SkillResult(False, "No atomic shots found", {})
        asset_context = load_asset_context(ctx)
        style_context = load_style_context(ctx)
        keyframes = []
        for atom in atoms:
            atom_id = str(atom.get("id"))
            named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
            refs = [str(asset["reference_image_url"]) for asset in named_assets if asset.get("reference_image_url")]
            first_url = ctx.ark.generate_image(
                frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context),
                refs=refs,
            )
            first_path = ctx.ark.download(first_url, ctx.workspace.keyframes_dir / f"{safe_name(atom_id)}_first.png")
            last_url = ctx.ark.generate_image(
                frame_prompt(str(atom.get("last_frame_prompt", "")), named_assets, style_context),
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
                    "image_provider": "ark",
                }
            )
        out = {"source": self.id, "image_provider": "ark", "keyframes": keyframes}
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
        style_context = load_style_context(ctx)
        for kf in keyframes:
            try:
                first_frame = str(kf.get("first_frame_url") or kf.get("first_frame_local_path") or "")
                if not first_frame:
                    raise ValueError(f"Missing first frame for {kf.get('atomic_shot_id')}")
                url = ctx.ark.generate_video(
                    video_prompt_with_style(str(kf.get("video_prompt", "")), style_context),
                    first_frame,
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


class KnowledgeCaptureSkill:
    id = "knowledge_capture"
    description = "Capture approved storyboard, shot, style, or prompt patterns into project/global knowledge cards."

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        source_text, source_ref = resolve_capture_source(ctx, input_data)
        if not source_text.strip():
            return SkillResult(False, "Missing source_text, source_stage, or source_file", {})

        scope = str(input_data.get("scope") or "project").lower()
        if scope not in {"project", "global", "both"}:
            return SkillResult(False, "scope must be project, global, or both", {})

        tags = input_data.get("tags") or []
        if isinstance(tags, str):
            tags = [tag.strip() for tag in tags.split(",") if tag.strip()]
        user_note = str(input_data.get("user_note") or input_data.get("note") or "").strip()
        title_hint = str(input_data.get("title") or "").strip()

        data = ctx.llm.chat_json(
            "You are Storyforge knowledge_capture. Extract durable reusable production knowledge from an approved result. Output strict JSON {cards:[...]}. Each card has title, type, tags, summary, when_to_use, do, avoid, prompt_patterns, examples, source_refs. Capture what should be reused, what mistakes to avoid, and concrete prompt/camera/action patterns. Do not praise. Do not copy long source text.",
            (
                f"Title hint: {title_hint}\n"
                f"User note: {user_note}\n"
                f"Requested tags: {json.dumps(tags, ensure_ascii=False)}\n"
                f"Source ref: {source_ref}\n\n"
                f"Approved source:\n{source_text[:20000]}"
            ),
            temperature=float(input_data.get("temperature", 0.2)),
            tag=self.id,
        )
        cards = list(data.get("cards") or [])
        if not cards:
            cards = [
                {
                    "title": title_hint or "Captured production pattern",
                    "type": "style",
                    "tags": tags,
                    "summary": user_note or "Reusable production pattern captured from an approved Storyforge result.",
                    "when_to_use": [],
                    "do": [],
                    "avoid": [],
                    "prompt_patterns": [],
                    "examples": [],
                    "source_refs": [source_ref],
                }
            ]

        written: list[str] = []
        scopes = ["project", "global"] if scope == "both" else [scope]
        for card in cards:
            card.setdefault("source_refs", [source_ref])
            existing_tags = card.get("tags") or []
            if isinstance(existing_tags, str):
                existing_tags = [existing_tags]
            card["tags"] = sorted({str(tag) for tag in [*existing_tags, *tags] if str(tag).strip()})
            for target_scope in scopes:
                path = ctx.workspace.write_knowledge_card(card, scope=target_scope)
                written.append(str(path))

        review = {"source": self.id, "source_ref": source_ref, "scope": scope, "cards": cards, "written": written}
        ctx.workspace.write_stage("07_knowledge_capture.json", review)
        write_review_markdown(ctx.workspace.review_dir / "07_knowledge_capture.md", "Knowledge Capture Review", review)
        ctx.workspace.append_log("Knowledge captured", {"source_ref": source_ref, "scope": scope, "cards": len(cards)})
        return SkillResult(True, "knowledge captured", {"file": "stages/07_knowledge_capture.json", "cards": len(cards), "written": written})


def default_registry() -> SkillRegistry:
    return SkillRegistry([
        ScriptIngestSkill(),
        StyleSelectSkill(),
        AssetDesignSkill(),
        StoryboardPlanSkill(),
        AtomicShotPlanSkill(),
        KeyframePlanSkill(),
        KeyframeImportSkill(),
        KeyframeGenerateArkSkill(),
        VideoGenerateArkSkill(),
        KnowledgeCaptureSkill(),
    ])


def load_asset_context(ctx: SkillContext) -> dict[str, dict[str, Any]]:
    refs: dict[str, dict[str, Any]] = {}
    for asset in ctx.workspace.read_stage("02_assets.json").get("assets", []) or []:
        name = asset.get("name")
        if name:
            refs[str(name)] = dict(asset)
    return refs


def load_style_context(ctx: SkillContext) -> str:
    style_path = ctx.workspace.wiki_dir / "style.md"
    if style_path.exists():
        text = style_path.read_text(encoding="utf-8").strip()
        if text and text != "# Style Profile":
            return text
    style_stage = ctx.workspace.read_stage("00_style.json")
    if style_stage:
        return json.dumps(style_stage, ensure_ascii=False, indent=2)
    return ""


def frame_prompt(prompt: str, assets: list[dict[str, Any]] | None = None, style_context: str = "") -> str:
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
    if style_context:
        base += f"Selected Style Profile. Follow this exactly:\n{style_context}\n\n"
    if asset_context:
        base += f"Referenced asset anchors:\n{asset_context}\n\n"
    return base + prompt


def video_prompt_with_style(prompt: str, style_context: str = "") -> str:
    if not style_context:
        return prompt
    return f"Selected Style Profile. Follow this exactly:\n{style_context}\n\nVideo prompt:\n{prompt}"


def style_options() -> list[dict[str, Any]]:
    return [
        {
            "id": "film",
            "label": "电影风格",
            "description": "更接近短片/电影语言，强调镜头调度、光影、空间关系和情绪递进。",
            "visual_rules": ["cinematic lighting", "natural performance", "controlled color palette", "clear spatial continuity"],
            "storyboard_rules": ["use establishing shots when needed", "prefer motivated camera movement", "let emotion build through shot order"],
            "prompt_rules": ["include lens/camera position/movement only when useful", "avoid overexplaining UI-like instructions"],
            "avoid": ["短剧式夸张表演", "漫画格子感", "过度网感字幕化"],
        },
        {
            "id": "short_drama",
            "label": "短剧风格",
            "description": "节奏更快，人物表情和冲突更直接，适合移动端竖屏爽感叙事。",
            "visual_rules": ["vertical mobile framing", "clear faces", "strong emotional beats", "high readability"],
            "storyboard_rules": ["start scenes quickly", "make conflict readable in the first seconds", "use reaction shots often"],
            "prompt_rules": ["make character emotion explicit", "keep action and consequence visually obvious"],
            "avoid": ["慢热电影铺垫过长", "含混的情绪表达", "过暗或难读的画面"],
        },
        {
            "id": "comic_drama",
            "label": "漫剧风格",
            "description": "漫画/轻动画式表达，强调清晰轮廓、戏剧姿态、夸张反应和分镜感。",
            "visual_rules": ["stylized character shapes", "clean silhouettes", "expressive poses", "panel-like composition"],
            "storyboard_rules": ["use pose-to-pose clarity", "make reactions graphic and readable", "favor iconic action states"],
            "prompt_rules": ["describe pose, expression, and visual emphasis clearly", "keep continuity of costume and character design"],
            "avoid": ["写实电影灰暗质感", "过多细碎真实运动模糊", "角色设计漂移"],
        },
        {
            "id": "anime",
            "label": "动画番剧风格",
            "description": "接近动画番剧的镜头和角色表现，兼顾情绪、动作关键姿势和连续性。",
            "visual_rules": ["anime-inspired lighting", "clean character consistency", "expressive eyes and posture", "dynamic but readable motion"],
            "storyboard_rules": ["use clear key poses", "emphasize emotional timing", "support action with cutaways when physics is hard"],
            "prompt_rules": ["state character design and outfit consistency", "describe key pose and camera angle"],
            "avoid": ["真人短剧质感", "过度照片写实", "随机换装"],
        },
        {
            "id": "documentary",
            "label": "纪实风格",
            "description": "自然、克制、像真实观察到的片段，减少表演感和夸张镜头。",
            "visual_rules": ["natural light", "observational camera", "realistic blocking", "restrained color"],
            "storyboard_rules": ["favor believable real-time actions", "avoid melodramatic staging", "let environment tell context"],
            "prompt_rules": ["keep props, movement, and body mechanics grounded"],
            "avoid": ["过度戏剧化", "漫画夸张", "不可信的物理动作"],
        },
    ]


def format_style_markdown(profile: dict[str, Any]) -> str:
    return "\n".join(
        [
            f"# Style Profile: {profile.get('label', profile.get('id', 'custom'))}",
            "",
            f"- id: {profile.get('id', 'custom')}",
            f"- description: {profile.get('description', '')}",
            "",
            "## Visual Rules",
            "",
            bullet_lines(profile.get("visual_rules")),
            "",
            "## Storyboard Rules",
            "",
            bullet_lines(profile.get("storyboard_rules")),
            "",
            "## Prompt Rules",
            "",
            bullet_lines(profile.get("prompt_rules")),
            "",
            "## Avoid",
            "",
            bullet_lines(profile.get("avoid")),
            "",
            "## User Note",
            "",
            str(profile.get("user_note", "")).strip(),
            "",
        ]
    )


def bullet_lines(value: Any) -> str:
    if not value:
        return ""
    if isinstance(value, list):
        return "\n".join(f"- {item}" for item in value)
    return f"- {value}"


def safe_name(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)
    return cleaned.strip("_") or "item"


def normalize_keyframe_images(value: Any) -> dict[str, dict[str, Any]]:
    if isinstance(value, dict):
        if "atomic_shot_id" in value:
            return {str(value["atomic_shot_id"]): value}
        return {str(key): dict(item) for key, item in value.items() if isinstance(item, dict)}
    if isinstance(value, list):
        out: dict[str, dict[str, Any]] = {}
        for item in value:
            if isinstance(item, dict) and item.get("atomic_shot_id"):
                out[str(item["atomic_shot_id"])] = item
        return out
    return {}


def resolve_workspace_path(ctx: SkillContext, value: Any) -> Path | None:
    if not value:
        return None
    path = Path(str(value))
    if path.is_absolute():
        return path
    return ctx.workspace.root / path


def resolve_capture_source(ctx: SkillContext, input_data: dict[str, Any]) -> tuple[str, str]:
    source_text = str(input_data.get("source_text") or "").strip()
    if source_text:
        return source_text, "input:source_text"

    source_file = input_data.get("source_file")
    if source_file:
        path = Path(str(source_file))
        if not path.is_absolute():
            path = ctx.workspace.root / path
        if path.exists():
            return path.read_text(encoding="utf-8"), f"file:{path}"

    source_stage = input_data.get("source_stage")
    if source_stage:
        stage_name = normalize_stage_name(str(source_stage))
        stage = ctx.workspace.read_stage(stage_name)
        if not stage:
            return "", f"stage:{stage_name}"
        item_id = str(input_data.get("item_id") or "").strip()
        if item_id:
            item = find_object_by_id(stage, item_id)
            if item is not None:
                return json.dumps(item, ensure_ascii=False, indent=2), f"stage:{stage_name}#{item_id}"
        return json.dumps(stage, ensure_ascii=False, indent=2), f"stage:{stage_name}"

    return "", "none"


def normalize_stage_name(value: str) -> str:
    if value.endswith(".json"):
        return value
    stage_map = {
        "style": "00_style.json",
        "style_select": "00_style.json",
        "script": "01_script.json",
        "assets": "02_assets.json",
        "storyboards": "03_storyboards.json",
        "storyboard": "03_storyboards.json",
        "atomic_shots": "04_atomic_shots.json",
        "atomic": "04_atomic_shots.json",
        "keyframe_plan": "05_keyframe_plan.json",
        "keyframe_tasks": "05_keyframe_plan.json",
        "keyframes": "05_keyframes.json",
        "videos": "06_videos.json",
    }
    return stage_map.get(value, value)


def find_object_by_id(value: Any, item_id: str) -> Any:
    if isinstance(value, dict):
        for key in ["id", "storyboard_id", "atomic_shot_id", "name"]:
            if str(value.get(key) or "") == item_id:
                return value
        for child in value.values():
            found = find_object_by_id(child, item_id)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_object_by_id(child, item_id)
            if found is not None:
                return found
    return None
