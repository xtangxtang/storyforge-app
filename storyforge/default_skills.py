from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .document import extract_document_text
from .services import media_ref
from .skills import SkillContext, SkillRegistry, SkillResult, write_review_markdown

# 对白/动作镜头恒加的整洁画面约束，避免 Seedance 烧录字幕、台词文字或水印 logo。
CLEAN_FRAME_RULE = "。画面整洁干净，不出现任何字幕、对白文字、标题字、台词、水印或 logo。"


class DocumentIngestSkill:
    id = "document_ingest"
    description = "从 txt、markdown、docx 或 pdf 剧本文档中抽取文本，写入 raw/script.md。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        document_path = input_data.get("document_path") or input_data.get("path") or input_data.get("script_path")
        if not document_path:
            return SkillResult(False, "缺少 document_path", {})
        extracted = extract_document_text(Path(str(document_path)))
        source_dir = ctx.workspace.raw_dir / "source"
        source_dir.mkdir(parents=True, exist_ok=True)
        source_path = Path(extracted["source_path"])
        copied_source = source_dir / source_path.name
        copied_source.write_bytes(source_path.read_bytes())
        ctx.workspace.raw_dir.joinpath("script.md").write_text(extracted["text"], encoding="utf-8")
        out = {
            "source": self.id,
            "project_id": ctx.workspace.project_id,
            "source_path": extracted["source_path"],
            "source_name": extracted["source_name"],
            "copied_source_path": str(copied_source.relative_to(ctx.workspace.root).as_posix()),
            "parser": extracted["parser"],
            "suffix": extracted["suffix"],
            "character_count": extracted["character_count"],
            "sha256": extracted["sha256"],
            "raw_script_path": "raw/script.md",
        }
        ctx.workspace.write_stage("00_document.json", out)
        write_review_markdown(ctx.workspace.review_dir / "00_document_ingest.md", "文档导入审阅", out)
        ctx.workspace.append_log("文档已导入", {"source": extracted["source_name"], "characters": extracted["character_count"]})
        return SkillResult(True, "文档已导入", {"file": "stages/00_document.json", "raw_script_path": "raw/script.md"})


class ScriptIngestSkill:
    id = "script_ingest"
    description = "在不改写故事的前提下，把剧本规范化为场景、角色、地点和道具。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script_text = (input_data.get("script_text") or "").strip()
        script_path = input_data.get("script_path")
        if not script_text and script_path:
            script_text = Path(script_path).read_text(encoding="utf-8")
        if not script_text and ctx.workspace.raw_dir.joinpath("script.md").exists():
            script_text = ctx.workspace.raw_dir.joinpath("script.md").read_text(encoding="utf-8")
        if not script_text:
            return SkillResult(False, "缺少 script_text 或 script_path", {})

        ctx.workspace.raw_dir.joinpath("script.md").write_text(script_text, encoding="utf-8")
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 script_ingest。请在不改变故事、角色、地点、对白和事件顺序的前提下，把用户已有剧本整理成严格 JSON。输出包含 scenes 和 assets。每个 scene 包含 scene_num, location, description, action, dialogue, duration。每个 asset 包含 type(character|location|prop), name, description。所有字段值和说明必须使用简体中文。",
            script_text,
            temperature=0.2,
            tag=self.id,
        )
        data.setdefault("source", self.id)
        ctx.workspace.write_stage("01_script.json", data)
        write_review_markdown(ctx.workspace.review_dir / "01_script.md", "剧本结构化审阅", data)
        ctx.workspace.append_log("剧本已结构化", {"scenes": len(data.get("scenes", [])), "assets": len(data.get("assets", []))})
        return SkillResult(True, "剧本已结构化", {"file": "stages/01_script.json"})


class StyleSelectSkill:
    id = "style_select"
    description = "询问用户选择生产风格，并持久化选定的风格档案。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script:
            return SkillResult(False, "未找到 stages/01_script.json 中的剧本结构化结果", {})

        selected = str(input_data.get("style") or input_data.get("style_id") or "").strip()
        custom_note = str(input_data.get("style_note") or input_data.get("custom_style") or "").strip()
        existing = ctx.workspace.read_stage("00_style.json")
        if not selected and existing.get("status") == "selected" and not input_data.get("force_prompt"):
            return SkillResult(True, "风格已选择", {"file": "stages/00_style.json", "style": existing.get("style", {}).get("id")})
        options = style_options()
        options_by_id = {option["id"]: option for option in options}

        if not selected:
            out = {
                "source": self.id,
                "status": "awaiting_selection",
                "prompt": "请选择本片的生产风格。后续所有角色设计、分镜、原子镜头、关键帧 prompt 和视频 prompt 都会按该风格构建。",
                "options": options,
                "how_to_continue": "请用一个风格 id 继续，例如：{\"style\":\"film\"}。",
            }
            ctx.workspace.write_stage("00_style.json", out)
            write_review_markdown(ctx.workspace.review_dir / "00_style_select.md", "风格选择提示", out)
            return SkillResult(True, "等待用户选择风格", {"file": "stages/00_style.json", "awaiting_user_selection": True})

        profile = options_by_id.get(selected)
        if profile is None:
            profile = {
                "id": "custom",
                "label": selected,
                "description": custom_note or selected,
                "visual_rules": [custom_note or selected],
                "storyboard_rules": ["所有阶段都要稳定遵守用户自定义风格。"],
                "prompt_rules": ["每个视觉 prompt 和视频 prompt 都要明确注入该自定义风格。"],
                "avoid": ["不要漂移到其他类型或平台语言。"],
            }
        if custom_note:
            profile = {**profile, "user_note": custom_note}

        out = {
            "source": self.id,
            "status": "selected",
            "style": profile,
            "prompt_contract": {
                "applies_to": ["scene_bible", "scene_reference_plan", "cross_scene_continuity", "asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan", "keyframe_generate_ark", "video_generate_ark", "continuity_validator"],
                "rule": "除非用户修改风格，否则所有后续 prompt 都必须明确遵守该风格档案。",
            },
        }
        ctx.workspace.write_stage("00_style.json", out)
        ctx.workspace.wiki_dir.joinpath("style.md").write_text(format_style_markdown(profile), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00_style_select.md", "风格选择审阅", out)
        ctx.workspace.append_log("风格已选择", {"style": profile.get("id"), "label": profile.get("label")})
        return SkillResult(True, "风格已选择", {"file": "stages/00_style.json", "style": profile.get("id")})


class ConsistencyBibleSkill:
    id = "consistency_bible"
    description = "在视觉设计前先抽取并锁定跨镜头共享元素（统一校服、配色、地点布局、复用道具、世界规则），供后续所有阶段引用以保持统一。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script.get("assets") and not script.get("scenes"):
            return SkillResult(False, "未找到 stages/01_script.json 中的剧本结构化结果", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 consistency_bible。在所有视觉设计之前，先从剧本里抽取并锁定【跨镜头必须统一】的共享元素，输出严格 JSON："
            "{uniform, fixed_outfits, palette, location_layouts, recurring_props, world_rules}。"
            "uniform=全片统一校服的精确描述（颜色与拼色、领口、版型、下装、鞋）；"
            "fixed_outfits={角色原名: 非校服时的固定着装}；"
            "palette=全片统一配色与光影基调；"
            "location_layouts={地点原名: 该地点结构与陈设的不变描述，写清黑板/窗/门/课桌排列/招牌等的方位，使该地点在每个镜头都一致}；"
            "recurring_props={复用道具原名: 统一外观}；"
            "world_rules=必须全片一致的世界规则，要包含人流的真实细节：携带物（如开学一律背双肩书包/拖行李箱）、人流密度与间距（三三两两拉开自然间距、不聚堆不列队）、朝向（如一律朝校门进）、季节着装（夏季短袖）。"
            "只锁定真正跨镜头复用的共享项，描述要具体可画、不要泛泛。所有字段值用简体中文。",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nScript JSON:\n{json.dumps(script, ensure_ascii=False)}",
            temperature=float(input_data.get("temperature", 0.2)),
            tag=self.id,
        )
        data.setdefault("source", self.id)
        ctx.workspace.write_stage("00b_consistency.json", data)
        ctx.workspace.wiki_dir.joinpath("consistency.md").write_text(format_consistency_markdown(data), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00b_consistency.md", "共享元素清单审阅", data)
        ctx.workspace.append_log("共享元素清单已抽取", {
            "locations": len(data.get("location_layouts") or {}),
            "props": len(data.get("recurring_props") or {}),
        })
        return SkillResult(True, "共享元素清单已抽取", {"file": "stages/00b_consistency.json"})


class SceneBibleSkill:
    id = "scene_bible"
    description = "为每个大场景建立共享的空间、光线、轴线、道具状态、物理规则和参考图计划。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script.get("scenes"):
            return SkillResult(False, "未找到 stages/01_script.json 中的 scenes", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 scene_bible。你的任务是在分镜之前，为剧本中的每个大场景建立可复用的场景制作包。"
            "输出严格 JSON：{scenes:[...], global_scene_rules:[...]}。"
            "每个 scene 必须包含 scene_id, scene_nums, name, location, story_purpose, time_weather_light, spatial_map, entrances_exits, "
            "screen_direction_rules, camera_coverage_plan, crowd_rules, character_state_rules, prop_state_rules, physics_rules, "
            "scene_reference_frames, continuity_contract, prompt_injection。"
            "字段要求："
            "time_weather_light 写清时间、天气、主光方向、阴影方向、色温和是否允许镜头间变化；"
            "spatial_map 写清场地平面关系、前后左右、入口出口、道路/墙/门/桌椅/球台等固定位置；"
            "screen_direction_rules 写清人物进入/离开/运动方向、镜头左右关系、禁止反向的动作；"
            "camera_coverage_plan 写建立镜头、主动作镜头、插入特写、反应镜头、过肩/关系镜头、转场镜头的覆盖策略；"
            "crowd_rules 写人群密度、朝向、速度、携带物和不能出现的队列/聚堆错误；"
            "character_state_rules 写每个主要人物在该场景中的起始位置、朝向、运动、服装、携带物和情绪初态；"
            "prop_state_rules 写复用道具的位置、朝向、持有人、运动约束和不可跳变状态；"
            "physics_rules 写速度、碰撞、重力、遮挡、身体力学、不可瞬移/穿模等规则；"
            "scene_reference_frames 写后续可先生成的参考图计划，至少包含 location_master_plate、camera_angle_plates、prop_placement_plate；"
            "continuity_contract 写给 storyboard_plan/atomic_shot_plan/keyframe_plan 必须继承的硬规则；"
            "prompt_injection 写一段可直接注入后续 prompt 的简短中文场景约束。"
            "必须遵守 workspace context 中的 Style Profile 和 Consistency Bible，不要改写故事。所有字段值使用简体中文。",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nScript JSON:\n{json.dumps(script, ensure_ascii=False)}",
            temperature=float(input_data.get("temperature", 0.2)),
            tag=self.id,
        )
        scenes = list(data.get("scenes") or [])
        for idx, scene in enumerate(scenes, 1):
            normalize_scene_bible(scene, idx)
        out = {
            "source": self.id,
            "scenes": scenes,
            "global_scene_rules": data.get("global_scene_rules") or [],
        }
        ctx.workspace.write_stage("00c_scene_bible.json", out)
        ctx.workspace.wiki_dir.joinpath("scene_bible.md").write_text(format_scene_bible_markdown(out), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00c_scene_bible.md", "场景制作包审阅", out)
        ctx.workspace.append_log("场景制作包已生成", {"scenes": len(scenes)})
        return SkillResult(True, "场景制作包已生成", {"file": "stages/00c_scene_bible.json", "count": len(scenes)})


class SceneReferencePlanSkill:
    id = "scene_reference_plan"
    description = "把 Scene Bible 中的场景参考图计划编译成可由 Codex 或 Ark 生成的图片任务。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        scene_bible = ctx.workspace.read_stage("00c_scene_bible.json")
        scenes = list(scene_bible.get("scenes") or [])
        if not scenes:
            return SkillResult(False, "未找到 stages/00c_scene_bible.json 中的 scenes，请先运行 scene_bible", {})
        style_context = load_style_context(ctx)
        tasks: list[dict[str, Any]] = []
        for scene in scenes:
            tasks.extend(scene_reference_tasks_for_scene(scene, style_context))
        out = {
            "source": self.id,
            "image_provider": "codex",
            "prompt_contract": {
                "style_reference": "wiki/style.md",
                "scene_reference": "wiki/scene_bible.md",
                "output_dir": "assets/scene_refs",
                "rule": "场景参考图不是最终分镜，而是后续多个分镜共享的空间、光线、轴线、机位和道具状态锚点。",
            },
            "scene_reference_tasks": tasks,
        }
        ctx.workspace.write_stage("00d_scene_reference_plan.json", out)
        write_review_markdown(ctx.workspace.review_dir / "00d_scene_reference_plan.md", "场景参考图任务审阅", out)
        ctx.workspace.append_log("场景参考图任务已规划", {"tasks": len(tasks)})
        return SkillResult(True, "场景参考图任务已规划", {"file": "stages/00d_scene_reference_plan.json", "count": len(tasks)})


class SceneReferenceImportSkill:
    id = "scene_reference_import"
    description = "把 Codex 生成的本地场景参考图导入 stages/00d_scene_references.json。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("00d_scene_reference_plan.json")
        tasks = list(plan.get("scene_reference_tasks") or [])
        explicit_images = normalize_scene_reference_images(input_data.get("images") or input_data.get("scene_references") or [])
        if not tasks and not explicit_images:
            return SkillResult(False, "没有找到场景参考图计划或输入图片", {})
        imported = []
        missing = []
        source_rows = tasks or list(explicit_images.values())
        for row in source_rows:
            ref_id = str(row.get("reference_id") or row.get("id") or "")
            if not ref_id:
                missing.append({"reason": "缺少 reference_id", "row": row})
                continue
            explicit = explicit_images.get(ref_id, {}) if isinstance(explicit_images, dict) else {}
            local_path = resolve_workspace_path(ctx, explicit.get("local_path") or explicit.get("reference_local_path") or row.get("local_path"))
            if not local_path or not local_path.exists():
                missing.append({"reference_id": ref_id, "missing": ["local_path"], "expected": str(local_path)})
                continue
            imported.append({
                **row,
                **explicit,
                "reference_id": ref_id,
                "local_path": str(local_path),
                "image_provider": "codex",
                "state": "ready",
            })
        out = {
            "source": self.id,
            "image_provider": "codex",
            "scene_references": imported,
            "missing": missing,
            "success": len(imported),
            "failed": len(missing),
        }
        ctx.workspace.write_stage("00d_scene_references.json", out)
        write_review_markdown(ctx.workspace.review_dir / "00d_scene_references.md", "场景参考图导入审阅", out)
        ok = bool(imported) and not missing
        return SkillResult(ok, "场景参考图已导入" if ok else "场景参考图导入不完整", {"file": "stages/00d_scene_references.json", "imported": len(imported), "missing": len(missing)})


class SceneReferenceGenerateArkSkill:
    id = "scene_reference_generate_ark"
    description = "备用路径：通过 Ark 生成场景 master plate、机位参考和道具摆放参考图。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("00d_scene_reference_plan.json")
        tasks = list(plan.get("scene_reference_tasks") or [])
        if not tasks:
            scene_bible = ctx.workspace.read_stage("00c_scene_bible.json")
            style_context = load_style_context(ctx)
            for scene in scene_bible.get("scenes") or []:
                tasks.extend(scene_reference_tasks_for_scene(scene, style_context))
        if not tasks:
            return SkillResult(False, "没有找到场景参考图任务，请先运行 scene_reference_plan", {})
        start_index = max(0, int(input_data.get("start_index") or 0))
        limit = max(0, int(input_data.get("limit") or input_data.get("max_items") or 0))
        only_ids = normalize_id_filter(input_data.get("reference_ids") or input_data.get("ids"))
        overwrite = bool(input_data.get("overwrite"))
        selected = [task for task in tasks if not only_ids or str(task.get("reference_id")) in only_ids]
        selected = selected[start_index:]
        if limit:
            selected = selected[:limit]

        existing = {
            str(item.get("reference_id")): item
            for item in ctx.workspace.read_stage("00d_scene_references.json").get("scene_references", [])
            if item.get("reference_id")
        }
        generated = 0
        skipped = 0
        failed = 0
        for task in selected:
            ref_id = str(task.get("reference_id"))
            local_path = resolve_workspace_path(ctx, task.get("local_path")) or ctx.workspace.scene_refs_dir / f"{safe_name(ref_id)}.png"
            current = dict(existing.get(ref_id) or {})
            if local_path.exists() and not overwrite:
                skipped += 1
                existing[ref_id] = {**current, **task, "local_path": str(local_path), "image_provider": "ark", "state": "ready"}
                continue
            try:
                url = ctx.ark.generate_image(ark_image_prompt(str(task.get("prompt") or "")))
                ctx.ark.download(url, local_path)
                generated += 1
                existing[ref_id] = {**task, "reference_url": url, "local_path": str(local_path), "image_provider": "ark", "state": "ready"}
            except Exception as exc:
                failed += 1
                existing[ref_id] = {**current, **task, "local_path": str(local_path), "image_provider": "ark", "state": "failed", "error": str(exc)}
        references = [existing[str(task.get("reference_id"))] for task in tasks if str(task.get("reference_id")) in existing]
        out = {
            "source": self.id,
            "image_provider": "ark",
            "scene_references": references,
            "success": sum(item.get("state") == "ready" for item in references),
            "failed": sum(item.get("state") == "failed" for item in references),
            "total_planned": len(tasks),
        }
        ctx.workspace.write_stage("00d_scene_references.json", out)
        write_review_markdown(ctx.workspace.review_dir / "00d_scene_references.md", "场景参考图生成审阅", out)
        ok = generated > 0 or skipped > 0
        return SkillResult(ok, "场景参考图生成流程已完成" if ok else "场景参考图生成失败", {"file": "stages/00d_scene_references.json", "generated": generated, "skipped": skipped, "failed": failed, "success": out["success"], "total_planned": len(tasks)})


class CrossSceneContinuitySkill:
    id = "cross_scene_continuity"
    description = "建立跨大场景的人物、道具、服装、情绪、物理状态和剧情接力规则。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        scene_bible = ctx.workspace.read_stage("00c_scene_bible.json")
        if not script.get("scenes"):
            return SkillResult(False, "未找到 stages/01_script.json 中的 scenes", {})
        if not scene_bible.get("scenes"):
            return SkillResult(False, "未找到 stages/00c_scene_bible.json，请先运行 scene_bible", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 cross_scene_continuity。你的任务是在多个大场景之间建立人物、道具、服装、情绪和物理状态的接力规则。"
            "输出严格 JSON：{entities:[...], scene_states:[...], transitions:[...], global_rules:[...]}。"
            "entities 列所有跨场景可能复用的角色、道具和地点，字段包含 entity_id, type(character|prop|location), name, invariant_identity, allowed_changes, forbidden_changes, cross_scene_rules。"
            "scene_states 按 scene_id 记录该大场景开始和结束时的状态，字段包含 scene_id, scene_nums, characters, props, locations, carry_over_from_previous, carry_over_to_next, prompt_injection。"
            "characters 必须写每个主要角色在该场景的 outfit, carried_props, physical_state, emotional_state, entry_exit_state, continuity_notes；"
            "props 必须写每个关键道具的 owner, location, condition, orientation, visibility, continuity_notes；"
            "transitions 写相邻大场景之间必须承接/允许变化/禁止跳变的内容，字段包含 from_scene_id, to_scene_id, elapsed_time, required_carryovers, permitted_changes, forbidden_jumps, continuity_checks, prompt_injection。"
            "重点识别：服装是否保持同一天一致；角色是否继续携带书包/球拍/自行车/包子；道具是否丢失、转移、损坏或留在上一场；人物是否因上一场动作出现汗水、疼痛、尴尬、着急等状态；地点变化是否需要解释；时间跳转是否允许换装或道具重置。"
            "不要改写故事，只把跨场景必须一致或必须解释的状态写清楚。所有字段值使用简体中文。",
            (
                f"Workspace context:\n{ctx.workspace.context_pack()}\n\n"
                f"Script JSON:\n{json.dumps(script, ensure_ascii=False)}\n\n"
                f"Scene Bible:\n{json.dumps(scene_bible, ensure_ascii=False)}"
            ),
            temperature=float(input_data.get("temperature", 0.15)),
            tag=self.id,
        )
        out = {
            "source": self.id,
            "entities": data.get("entities") or [],
            "scene_states": data.get("scene_states") or [],
            "transitions": data.get("transitions") or [],
            "global_rules": data.get("global_rules") or [],
        }
        ctx.workspace.write_stage("00e_cross_scene_continuity.json", out)
        ctx.workspace.wiki_dir.joinpath("cross_scene_continuity.md").write_text(format_cross_scene_continuity_markdown(out), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00e_cross_scene_continuity.md", "跨场景连续性审阅", out)
        ctx.workspace.append_log("跨场景连续性已生成", {"entities": len(out["entities"]), "transitions": len(out["transitions"])})
        return SkillResult(True, "跨场景连续性已生成", {"file": "stages/00e_cross_scene_continuity.json", "entities": len(out["entities"]), "transitions": len(out["transitions"])})


class AssetDesignSkill:
    id = "asset_design"
    description = "为角色、地点和道具设计稳定的影视视觉锚点与可复用图片提示词。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        assets = list(script.get("assets") or [])
        if not assets:
            return SkillResult(False, "stages/01_script.json 中没有找到 assets", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 asset_design。输出严格 JSON：{assets:[...]}。"
            "对每个 asset 保留 type/name/description，并补充这些字段："
            "asset_id, story_function, visual_identity, visual_anchor_prompt, negative_prompt, consistency_notes, "
            "continuity_invariants, allowed_variations, forbidden_variations, cinematic_usage, generation_anchors。"
            "字段含义：story_function 是该资产在叙事里的功能；visual_identity 是影视美术可复用的外观身份；"
            "continuity_invariants 是跨镜头绝不能变的身份/服装/位置/材质/朝向规则；allowed_variations 是可随镜头变化的表演、光影、距离、局部遮挡；"
            "forbidden_variations 是绝对禁止的漂移；cinematic_usage 包含 best_framings、lighting_notes、movement_notes；"
            "generation_anchors 包含 positive_prompt、negative_prompt、reference_priority，用于后续图片/视频生成。"
            "提示词必须足够具体、可拍、可生成；不要海报感、拼贴感、设定集排版或 UI 说明；"
            "必须保持身份、服装、地点结构、道具状态在后续镜头中稳定。"
            "必须遵守 workspace context 中的 Consistency Bible（consistency.md）与 Cross Scene Continuity（cross_scene_continuity.md）：每个 character 的 visual_anchor_prompt 一律穿统一校服（除非 bible 的 fixed_outfits 或跨场景状态另有规定），每个 location 一律采用 bible 里该地点的固定布局与方位，复用道具用 bible 的统一外观，并承接跨场景的持有人、状态、损坏/丢失/转移信息，绝不各自发明。"
            "同时遵守 Style Profile。所有字段值和说明必须使用简体中文。",
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
                        f"{asset.get('type', 'asset')} {asset.get('name', '')} 的稳定制作参考。"
                        f"{asset.get('description', '')}。身份清晰、可复用，不要海报，不要拼贴。"
                    ),
                    "negative_prompt": "海报、拼贴、文字设定表、UI、服装不一致",
                    "consistency_notes": "作为后续关键帧的人物/地点身份锚点使用。",
                }
                for asset in assets
            ]
        designed = [normalize_asset_design(asset, idx) for idx, asset in enumerate(designed, 1)]
        out = {"source": self.id, "assets": designed}
        ctx.workspace.write_stage("02_assets.json", out)
        write_review_markdown(ctx.workspace.review_dir / "02_assets.md", "视觉资产设计审阅", out)
        return SkillResult(True, "视觉资产提示词已设计", {"file": "stages/02_assets.json", "count": len(designed)})


class StoryboardPlanSkill:
    id = "storyboard_plan"
    description = "基于结构化剧本和项目记忆生成可审阅的导演分镜节拍。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script.get("scenes"):
            return SkillResult(False, "stages/01_script.json 中没有找到 scenes", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 storyboard_plan。创建严格 JSON：{storyboards:[...]}。"
            "每个分镜节拍包含 id, scene_id, scene_num, shot_num, location, duration(5-10秒), characters, props, description, "
            "coverage_role, scene_bible_refs, dramatic_intent, camera_design, blocking, screen_direction, edit_value, continuity_risks, "
            "first_frame_prompt, video_prompt, continuity。"
            "必须保留原故事。dramatic_intent 写清这个镜头在情绪/信息/冲突上的功能；camera_design 写机位、景别、焦段感、运动动机；"
            "blocking 写人物与道具在空间里的调度关系；screen_direction 写入画方向、视线方向、运动方向和前后镜头怎样接；"
            "edit_value 写这个镜头切出去时观众获得的新信息或情绪；continuity_risks 写可能漂移/穿帮/物理不可信的点。"
            "coverage_role 必须从 建立镜头/主动作镜头/插入特写/反应镜头/过肩关系镜头/转场镜头 中选择最合适的一类；"
            "scene_bible_refs 列出该镜头继承的 scene_bible 规则，如光线、轴线、人群、道具状态、物理规则。"
            "动作连续、中间没有断点的段落保持为一个连续节拍、不要拆成需要硬切拼接的多条（如骑行→相撞→道歉合为一条）；"
            "只在换时间、换地点、换全新机位的真正断点才切镜。"
            "方向/进入/相撞类镜头的 first_frame_prompt 用不含清晰真人脸的画面锁方向（无脸背影人物、或场地空镜、或物件特写如自行车前轮），把运动目的地放在画面纵深。"
            "每个节拍和 prompt 都必须遵守 workspace context 中的 Scene Bible、Cross Scene Continuity、Consistency Bible（统一校服/地点布局/复用道具）与 Style Profile；跨大场景的服装、携带物、道具归属、身体/情绪状态必须承接，不能无解释重置。所有字段值和说明必须使用简体中文。",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nScript JSON:\n{json.dumps(script, ensure_ascii=False)}",
            temperature=float(input_data.get("temperature", 0.25)),
            tag=self.id,
        )
        storyboards = list(data.get("storyboards") or [])
        for idx, sb in enumerate(storyboards, 1):
            sb.setdefault("id", f"sb_{idx:03d}")
            normalize_storyboard_design(sb)
        out = {"source": self.id, "storyboards": storyboards}
        ctx.workspace.write_stage("03_storyboards.json", out)
        write_review_markdown(ctx.workspace.review_dir / "03_storyboards.md", "分镜计划审阅", out)
        return SkillResult(True, "分镜计划已生成", {"file": "stages/03_storyboards.json", "count": len(storyboards)})


class AtomicShotPlanSkill:
    id = "atomic_shot_plan"
    description = "把分镜节拍拆成具有明确起止状态、物理逻辑可信的原子镜头。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        boards = ctx.workspace.read_stage("03_storyboards.json")
        storyboards = list(boards.get("storyboards") or [])
        if not storyboards:
            return SkillResult(False, "没有找到 storyboards", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 atomic_shot_plan。输出严格 JSON：{atomic_shots:[...]}。"
            "每个镜头包含 id, storyboard_id, scene_id, render_mode(i2v|t2v), duration, purpose, "
            "shot_design, generation_strategy, first_frame_prompt, video_prompt, continuity_state_start, continuity_state_end, reference_asset_names。"
            "shot_design 包含 camera, movement, blocking, performance, edit_intent，用影视语言写清这个镜头怎么拍、为什么这么拍。"
            "generation_strategy 包含 render_mode, first_frame_type, control_frame_role, reference_assets, failure_modes, moderation_notes，用生成语言写清如何稳定产出。"
            "continuity_state_start 和 continuity_state_end 优先写成结构化 JSON object，包含 characters/camera/lighting/props/location/physics/summary；不要只写一句泛泛描述。"
            "每个镜头必须从 Scene Bible 继承 location、光线方向、轴线、人物位置、道具状态和物理规则，并从 Cross Scene Continuity 继承跨大场景的服装、携带物、道具归属、身体/情绪状态；如果剧情需要突破规则，必须在 continuity_state_end 中说明原因。"
            "【拆分】动作连续、中间没有断点的相邻动作合并成一条连续镜（如骑行→相撞→道歉合一条），不要拆成多条再硬切；只在换时间/地点/全新机位、或单条超10秒时才另起一镜。不要过度原子化。"
            "【时长】单条 5-10 秒（下限5上限10），一条连续微场景可用 8-10 秒。video_prompt 的动作节拍数必须与 duration 匹配（约每拍1.5-2秒）：节拍装不下就加时长或拆镜，节拍太少则补环境/反应细节。"
            "【中段新出现的人物/地点】Ark 限制 first_frame 与 reference 媒体互斥，i2v 镜里中段才出现、不在首帧画面中的人物/地点没有任何参考图可锁，必须在 video_prompt 文字里写全其外观锚点（校服拼色/发型/眼镜耳机书包等配件/建筑材质结构），否则必然漂移。"
            "【render_mode】默认 i2v：能做出『严格无脸纯背影/正后方』首帧的镜（相机正对角色后脑勺与后背、目的地在画面纵深）。i2v 审核只查输入首帧、不查输出，所以无脸首帧既过审又锁方向，碰撞/转身/道歉等有脸画面在输出里照常出现。仅当开局就必须是脸、无法做合理无脸首帧的纯对话/情绪特写才用 t2v。"
            "【first_frame_prompt】只需『不含清晰真人脸（过审）+ 锁方向』，三选一用最合适的：①无脸背影/过肩人物（相机正对后脑勺与后背）；②纯场地/建立空镜（人群背影、无主要人物特写）；③物件/局部特写（如自行车前轮、道具）。用相机相对语言把目的地/运动矢量放进画面锁方向（视频里再上摇/推进露出人物）；若有角色出镜补身份锚点（校服拼色、有无眼镜/书包、发型体型）区分同框角色。人脸在输出视频里照常出现。同一地点的多个镜头要换不同机位/取景/前景/时刻、避免每镜同一视角（地点结构由 canon 统一，画面要有变化）。"
            "【video_prompt】i2v 镜写运动与动作；t2v 镜必须自包含因果（主语+动作+场景+因果，不能只写余波）。困难硬接触（相撞/急刹）放在连续镜里、接触靠运动模糊+余波带过；横切来的人从侧巷汇入交汇、不要站路中间被追尾；余波用中近景收（道歉/反应）。所有镜恒含无字幕/无水印约束、不依赖中文招牌逐帧稳定。"
            "reference_asset_names 只列该镜【首帧画面里真出现】的资产（地点 canon 优先 + 首帧里可见的物件/角色）；物件特写或纯空镜首帧不要列没出场的角色，否则无关人物描述会触发文本审核 InputTextSensitiveContentDetected。相邻镜共享连续状态。所有 prompt 遵守 Scene Bible、Cross Scene Continuity、Consistency Bible（统一校服/地点布局/复用道具不得各自发明）与 Style Profile。所有字段值用简体中文。",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nStoryboards:\n{json.dumps(storyboards, ensure_ascii=False)}",
            temperature=0.2,
            tag=self.id,
        )
        atoms = list(data.get("atomic_shots") or [])
        for idx, atom in enumerate(atoms, 1):
            atom.setdefault("id", f"atom_{idx:03d}")
            normalize_atomic_shot_design(atom)
        out = {"source": self.id, "atomic_shots": atoms}
        ctx.workspace.write_stage("04_atomic_shots.json", out)
        write_review_markdown(ctx.workspace.review_dir / "04_atomic_shots.md", "原子镜头审阅", out)
        return SkillResult(True, "原子镜头已生成", {"file": "stages/04_atomic_shots.json", "count": len(atoms)})


class ContinuityValidatorSkill:
    id = "continuity_validator"
    description = "对分镜和原子镜头进行场景连续性、轴线方向、道具状态和物理逻辑验证。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        storyboards = ctx.workspace.read_stage("03_storyboards.json")
        atomic_shots = ctx.workspace.read_stage("04_atomic_shots.json")
        if not storyboards.get("storyboards") and not atomic_shots.get("atomic_shots"):
            return SkillResult(False, "未找到 storyboards 或 atomic_shots，无法验证连续性", {})
        scene_bible = ctx.workspace.read_stage("00c_scene_bible.json")
        if not scene_bible.get("scenes"):
            return SkillResult(False, "未找到 stages/00c_scene_bible.json，请先运行 scene_bible", {})
        cross_scene = ctx.workspace.read_stage("00e_cross_scene_continuity.json")
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 continuity_validator。你要像场记、动作指导和生成技术导演一样审查已生成的分镜与原子镜头。"
            "输出严格 JSON：{score, verdict, blocking_issues, warnings, passed_checks, revision_plan, per_shot_notes}。"
            "verdict 只能是 approve/revise/block。"
            "重点检查："
            "1. 是否违反 Scene Bible 的地点结构、入口出口、轴线、运动方向、光线方向、人群规则；"
            "2. 是否违反 Cross Scene Continuity 的跨场景接力：角色服装、发型、携带物、身体/情绪状态、道具归属、道具损坏/丢失/转移是否无解释跳变；"
            "3. 角色服装、发型、携带物、情绪、站位和朝向是否跳变；"
            "4. 道具位置、持有人、朝向、运动状态是否跳变，例如自行车车头方向、球拍在哪只手、书包是否仍背着；"
            "5. 物理动作是否可信，是否有人物瞬移、穿模、速度突变、碰撞方式不合理、过多动作塞进短时长；"
            "6. first_frame_prompt、video_prompt、continuity_state_start/end 是否足够支撑图生视频连续生成；"
            "7. 是否有可读文字、字幕、水印、logo、中文招牌依赖或审核风险。"
            "blocking_issues 只写必须修改的硬错误；warnings 写可优化但不阻塞的问题；revision_plan 给出可执行修改建议。"
            "所有字段值使用简体中文。",
            (
                f"Workspace context:\n{ctx.workspace.context_pack()}\n\n"
                f"Scene Bible:\n{json.dumps(scene_bible, ensure_ascii=False)}\n\n"
                f"Cross Scene Continuity:\n{json.dumps(cross_scene, ensure_ascii=False)}\n\n"
                f"Storyboards:\n{json.dumps(storyboards, ensure_ascii=False)}\n\n"
                f"Atomic Shots:\n{json.dumps(atomic_shots, ensure_ascii=False)}"
            ),
            temperature=float(input_data.get("temperature", 0.1)),
            tag=self.id,
        )
        out = {
            "source": self.id,
            "scene_bible_file": "stages/00c_scene_bible.json",
            "cross_scene_continuity_file": "stages/00e_cross_scene_continuity.json",
            "storyboards_file": "stages/03_storyboards.json",
            "atomic_shots_file": "stages/04_atomic_shots.json",
            **data,
        }
        ctx.workspace.write_stage("04b_continuity_validation.json", out)
        ctx.workspace.wiki_dir.joinpath("continuity.md").write_text(format_continuity_validation_markdown(out), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "04b_continuity_validation.md", "连续性验证审阅", out)
        verdict = str(out.get("verdict") or "").lower()
        blocked = verdict == "block"
        message = "连续性验证发现阻塞问题，请先修改分镜/原子镜头" if blocked else "连续性验证报告已生成"
        return SkillResult(True, message, {"file": "stages/04b_continuity_validation.json", "verdict": out.get("verdict"), "score": out.get("score"), "validation_blocked": blocked})


class KeyframePlanSkill:
    id = "keyframe_plan"
    description = "为 Codex 图片生成规划每个原子镜头的控制首帧任务。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        atoms = list(ctx.workspace.read_stage("04_atomic_shots.json").get("atomic_shots") or [])
        if not atoms:
            return SkillResult(False, "没有找到 atomic_shots", {})
        asset_context = load_asset_context(ctx)
        style_context = load_style_context(ctx)
        scene_reference_context = load_scene_reference_context(ctx)
        tasks = []
        for atom in atoms:
            atom_id = str(atom.get("id"))
            named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
            scene_refs = scene_references_for_atom(atom, scene_reference_context)
            first_path = Path("keyframes") / f"{safe_name(atom_id)}_first.png"
            raw_last = str(atom.get("last_frame_prompt", "")).strip()
            shot_design = normalize_shot_design(atom.get("shot_design"), atom)
            generation_strategy = normalize_generation_strategy(atom.get("generation_strategy"), atom)
            task = {
                "atomic_shot_id": atom_id,
                "storyboard_id": atom.get("storyboard_id"),
                "scene_id": atom.get("scene_id"),
                "duration": atom.get("duration", 5),
                "video_prompt": atom.get("video_prompt", ""),
                "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context),
                "first_frame_local_path": first_path.as_posix(),
                "frame_mode": "first_last" if raw_last else "first_frame_only",
                "render_mode": atom.get("render_mode", "i2v"),
                "reference_asset_names": atom.get("reference_asset_names", []),
                "scene_reference_ids": [ref.get("reference_id") for ref in scene_refs if ref.get("reference_id")],
                "scene_reference_local_paths": [ref.get("local_path") for ref in scene_refs if ref.get("local_path")],
                "control_frame_role": generation_strategy.get("control_frame_role"),
                "frame_must_show": default_frame_must_show(atom, generation_strategy),
                "frame_must_not_show": default_frame_must_not_show(atom, generation_strategy),
                "motion_to_generate": atom.get("video_prompt", ""),
                "shot_design": shot_design,
                "generation_strategy": generation_strategy,
                "continuity_state_start": atom.get("continuity_state_start"),
                "continuity_state_end": atom.get("continuity_state_end"),
                "status": "needs_codex_image_generation",
            }
            task["prompt_chars"] = len(str(task["first_frame_prompt"]))
            # 仅当原子镜确有尾帧指令（困难接触/到达镜）才规划尾帧任务，避免生成无意义的纯模板尾帧。
            if raw_last:
                last_path = Path("keyframes") / f"{safe_name(atom_id)}_last.png"
                task["last_frame_prompt"] = frame_prompt(raw_last, named_assets, style_context)
                task["last_frame_local_path"] = last_path.as_posix()
            tasks.append(task)
        out = {
            "source": self.id,
            "image_provider": "codex",
            "prompt_contract": {
                "style_reference": "wiki/style.md",
                "scene_reference": "wiki/scene_bible.md",
                "scene_reference_plan": "stages/00d_scene_reference_plan.json",
                "scene_reference_images": "stages/00d_scene_references.json",
                "cross_scene_continuity_reference": "wiki/cross_scene_continuity.md",
                "continuity_reference": "wiki/continuity.md",
                "asset_reference": "stages/02_assets.json",
                # 超过 800 时 frame_prompt 自动换精简锚点版；2000 是含风格摘要/锚点行的实际硬上限。
                "prompt_budget_chars": 2000,
                "compact_threshold_chars": 800,
                "frame_policy": "默认 first-frame-only 锁方向；仅困难接触/到达镜才规划 last_frame 任务。",
                "control_frame_policy": "首帧不是分镜插画，而是图生视频控制帧：负责锁定空间、方向、身份、物理初态或动作触发点。",
                "rule": "每条首帧 prompt 只保留镜头画面、核心动作、物理/方向/光影约束；完整风格、场景制作包、连续性验证和资产锚点由全局引用提供。",
            },
            "keyframe_tasks": tasks,
        }
        ctx.workspace.write_stage("05_keyframe_plan.json", out)
        write_review_markdown(ctx.workspace.review_dir / "05_keyframe_plan.md", "关键帧任务审阅", out)
        return SkillResult(True, "关键帧图片任务已规划", {"file": "stages/05_keyframe_plan.json", "count": len(tasks)})


class KeyframeImportSkill:
    id = "keyframe_import"
    description = "把 Codex 生成的本地关键帧图片导入 stages/05_keyframes.json。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("05_keyframe_plan.json")
        tasks = list(plan.get("keyframe_tasks") or [])
        explicit_images = normalize_keyframe_images(input_data.get("images") or input_data.get("keyframes") or [])
        if not tasks and not explicit_images:
            return SkillResult(False, "没有找到关键帧计划或输入图片", {})

        imported = []
        missing = []
        source_rows = tasks or list(explicit_images.values())
        for row in source_rows:
            atom_id = str(row.get("atomic_shot_id") or row.get("id") or "")
            if not atom_id:
                missing.append({"reason": "缺少 atomic_shot_id", "row": row})
                continue
            explicit = explicit_images.get(atom_id, {}) if isinstance(explicit_images, dict) else {}
            first_path = resolve_workspace_path(ctx, explicit.get("first_frame_local_path") or row.get("first_frame_local_path"))
            last_path = resolve_workspace_path(ctx, explicit.get("last_frame_local_path") or row.get("last_frame_local_path"))
            # first-frame-only 锁方向：首帧必需，尾帧可选（仅困难接触/到达镜头才需要）。
            if not first_path or not first_path.exists():
                missing.append({"atomic_shot_id": atom_id, "missing": ["first_frame_local_path"], "expected": {"first": str(first_path)}})
                continue
            has_last = bool(last_path and last_path.exists())
            imported.append(
                {
                    "atomic_shot_id": atom_id,
                    "storyboard_id": row.get("storyboard_id"),
                    "scene_id": row.get("scene_id"),
                    "duration": row.get("duration", 5),
                    "video_prompt": row.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "last_frame_local_path": str(last_path) if has_last else "",
                    "frame_mode": "first_last" if has_last else "first_frame_only",
                    "image_provider": "codex",
                    "reference_asset_names": row.get("reference_asset_names", []),
                    "scene_reference_ids": row.get("scene_reference_ids", []),
                    "scene_reference_local_paths": row.get("scene_reference_local_paths", []),
                    "control_frame_role": row.get("control_frame_role"),
                    "frame_must_show": row.get("frame_must_show", []),
                    "frame_must_not_show": row.get("frame_must_not_show", []),
                    "motion_to_generate": row.get("motion_to_generate", row.get("video_prompt", "")),
                    "shot_design": row.get("shot_design", {}),
                    "generation_strategy": row.get("generation_strategy", {}),
                    "continuity_state_start": row.get("continuity_state_start"),
                    "continuity_state_end": row.get("continuity_state_end"),
                    "status": "imported",
                }
            )

        out = {"source": self.id, "image_provider": "codex", "keyframes": imported, "missing": missing}
        ctx.workspace.write_stage("05_keyframes.json", out)
        write_review_markdown(ctx.workspace.review_dir / "05_keyframes.md", "关键帧导入审阅", out)
        ok = len(imported) > 0 and not missing
        message = "关键帧已导入" if ok else "关键帧导入不完整"
        return SkillResult(ok, message, {"file": "stages/05_keyframes.json", "imported": len(imported), "missing": len(missing)})


class KeyframeGenerateArkSkill:
    id = "keyframe_generate_ark"
    description = "备用路径：通过 Ark 生成每镜背影/过肩首帧控制图（first-frame-only，锁方向不 morph，可断点续跑）。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("05_keyframe_plan.json")
        tasks = list(plan.get("keyframe_tasks") or [])
        atoms = list(ctx.workspace.read_stage("04_atomic_shots.json").get("atomic_shots") or [])
        if not tasks:
            tasks = keyframe_tasks_from_atoms(ctx, atoms)
        if not tasks:
            return SkillResult(False, "没有找到关键帧任务，请先运行 keyframe_plan", {})
        # 计划任务可能不带 reference_asset_names，从原子镜补一张映射表。
        ref_names_by_atom = {str(a.get("id")): list(a.get("reference_asset_names") or []) for a in atoms}
        rmode_by_atom = {str(a.get("id")): str(a.get("render_mode") or "i2v") for a in atoms}

        start_index = max(0, int(input_data.get("start_index") or 0))
        limit = max(0, int(input_data.get("limit") or input_data.get("max_items") or 0))
        only_ids = normalize_id_filter(input_data.get("atomic_shot_ids") or input_data.get("ids"))
        overwrite = bool(input_data.get("overwrite"))
        selected_tasks = [task for task in tasks if not only_ids or str(task.get("atomic_shot_id")) in only_ids]
        selected_tasks = selected_tasks[start_index:]
        if limit:
            selected_tasks = selected_tasks[:limit]

        existing = {
            str(item.get("atomic_shot_id")): item
            for item in ctx.workspace.read_stage("05_keyframes.json").get("keyframes", [])
            if item.get("atomic_shot_id")
        }
        style_context = load_style_context(ctx)
        # canon 注入：先为本批次涉及的地点/角色生成统一锚点（地点=canon基准空镜，角色=定妆图），
        # 缓存进 02_assets.json；该地点每个首帧都引用同一张基准图 -> 跨镜头结构统一。
        # 按 selected_tasks 计算，小批量测试只生成用到的锚点；锚点缓存后续批次自动复用。
        needed = {n for t in selected_tasks for n in (t.get("reference_asset_names") or ref_names_by_atom.get(str(t.get("atomic_shot_id")), []))}
        anchors = ensure_asset_anchors(ctx, style_context, only_names=needed)
        generated = 0
        skipped = 0
        failed = 0
        task_order = [str(task.get("atomic_shot_id")) for task in tasks]

        for task in selected_tasks:
            atom_id = str(task.get("atomic_shot_id"))
            names = task.get("reference_asset_names") or ref_names_by_atom.get(atom_id, [])
            render_mode = str(task.get("render_mode") or rmode_by_atom.get(atom_id) or "i2v")
            # 首帧参考图 = 该镜地点的 canon 基准图 + 在场角色定妆图（只喂图片生成，不喂视频）。
            # 无脸背影首帧：i2v 镜直接作首帧（锁方向+过审）；t2v 镜也生成它，作视频生成的方向 reference_image。
            # 每镜各自生成首帧，把该地点 canon + 在场角色定妆图当参考图：canon 统一地点结构，
            # 每镜不同的 first_frame_prompt（机位/取景/前景/时刻）提供变化。不直接复用 canon，避免每镜一模一样。
            refs = [anchors[n] for n in names if anchors.get(n)]
            for scene_ref in scene_references_for_task(task, scene_reference_context):
                ref = scene_reference_media_ref(ctx, scene_ref)
                if ref and ref not in refs:
                    refs.append(ref)
            if not refs:
                refs = continuity_reference_urls(task_order, existing, atom_id)
            first_path = resolve_workspace_path(ctx, task.get("first_frame_local_path")) or ctx.workspace.keyframes_dir / f"{safe_name(atom_id)}_first.png"
            current = dict(existing.get(atom_id) or {})
            # first-frame-only：只生成背影/过肩首帧驱动自然前进运动，不生成尾帧（避免首尾 morph）。
            # 跳过判定只看首帧是否已存在。
            if first_path.exists() and not overwrite:
                skipped += 1
                existing[atom_id] = {
                    **current,
                    "atomic_shot_id": atom_id,
                    "storyboard_id": task.get("storyboard_id"),
                    "scene_id": task.get("scene_id"),
                    "duration": task.get("duration", 5),
                    "video_prompt": task.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "image_provider": "ark",
                    "frame_mode": "first_frame_only",
                    "render_mode": render_mode,
                    "reference_asset_names": list(names),
                    "scene_reference_ids": task.get("scene_reference_ids", []),
                    "scene_reference_local_paths": task.get("scene_reference_local_paths", []),
                    "control_frame_role": task.get("control_frame_role"),
                    "frame_must_show": task.get("frame_must_show", []),
                    "frame_must_not_show": task.get("frame_must_not_show", []),
                    "motion_to_generate": task.get("motion_to_generate", task.get("video_prompt", "")),
                    "shot_design": task.get("shot_design", {}),
                    "generation_strategy": task.get("generation_strategy", {}),
                    "continuity_state_start": task.get("continuity_state_start"),
                    "continuity_state_end": task.get("continuity_state_end"),
                    "state": "ready",
                }
                continue
            try:
                first_url = ctx.ark.generate_image(ark_image_prompt(str(task.get("first_frame_prompt", ""))), refs=refs)
                ctx.ark.download(first_url, first_path)
                generated += 1
                existing[atom_id] = {
                    "atomic_shot_id": atom_id,
                    "storyboard_id": task.get("storyboard_id"),
                    "scene_id": task.get("scene_id"),
                    "duration": task.get("duration", 5),
                    "video_prompt": task.get("video_prompt", ""),
                    "first_frame_url": first_url,
                    "first_frame_local_path": str(first_path),
                    "image_provider": "ark",
                    "frame_mode": "first_frame_only",
                    "render_mode": render_mode,
                    "reference_asset_names": list(names),
                    "scene_reference_ids": task.get("scene_reference_ids", []),
                    "scene_reference_local_paths": task.get("scene_reference_local_paths", []),
                    "control_frame_role": task.get("control_frame_role"),
                    "frame_must_show": task.get("frame_must_show", []),
                    "frame_must_not_show": task.get("frame_must_not_show", []),
                    "motion_to_generate": task.get("motion_to_generate", task.get("video_prompt", "")),
                    "shot_design": task.get("shot_design", {}),
                    "generation_strategy": task.get("generation_strategy", {}),
                    "continuity_state_start": task.get("continuity_state_start"),
                    "continuity_state_end": task.get("continuity_state_end"),
                    "state": "ready",
                }
            except Exception as exc:
                failed += 1
                existing[atom_id] = {
                    **current,
                    "atomic_shot_id": atom_id,
                    "storyboard_id": task.get("storyboard_id"),
                    "scene_id": task.get("scene_id"),
                    "duration": task.get("duration", 5),
                    "video_prompt": task.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "image_provider": "ark",
                    "frame_mode": "first_frame_only",
                    "render_mode": render_mode,
                    "reference_asset_names": list(names),
                    "scene_reference_ids": task.get("scene_reference_ids", []),
                    "scene_reference_local_paths": task.get("scene_reference_local_paths", []),
                    "control_frame_role": task.get("control_frame_role"),
                    "frame_must_show": task.get("frame_must_show", []),
                    "frame_must_not_show": task.get("frame_must_not_show", []),
                    "motion_to_generate": task.get("motion_to_generate", task.get("video_prompt", "")),
                    "shot_design": task.get("shot_design", {}),
                    "generation_strategy": task.get("generation_strategy", {}),
                    "continuity_state_start": task.get("continuity_state_start"),
                    "continuity_state_end": task.get("continuity_state_end"),
                    "state": "failed",
                    "error": str(exc),
                }

        keyframes = [existing[str(task.get("atomic_shot_id"))] for task in tasks if str(task.get("atomic_shot_id")) in existing]
        # anchors 值可能是 base64 data URI（本地锚点图），写进 stage 文档前换成可读的本地路径/URL。
        asset_rows = {str(a.get("name") or ""): a for a in ctx.workspace.read_stage("02_assets.json").get("assets") or []}
        anchors_doc = {
            n: str((asset_rows.get(n) or {}).get("reference_image_local_path") or (asset_rows.get(n) or {}).get("reference_image_url") or "")
            for n in anchors
        }
        out = {
            "source": self.id,
            "image_provider": "ark",
            "mode": "first_frame_only",
            "anchors": anchors_doc,
            "keyframes": keyframes,
            "success": sum(item.get("state") == "ready" for item in keyframes),
            "failed": sum(item.get("state") == "failed" for item in keyframes),
            "total_planned": len(tasks),
        }
        ctx.workspace.write_stage("05_keyframes.json", out)
        write_review_markdown(ctx.workspace.review_dir / "05_keyframes.md", "关键帧生成审阅", out)
        ok = generated > 0 or skipped > 0
        return SkillResult(
            ok,
            "关键帧生成流程已完成（first-frame-only）" if ok else "关键帧生成失败",
            {"file": "stages/05_keyframes.json", "generated": generated, "skipped": skipped, "failed": failed, "success": out["success"], "total_planned": len(tasks)},
        )


def keyframe_tasks_from_atoms(ctx: SkillContext, atoms: list[dict[str, Any]]) -> list[dict[str, Any]]:
    asset_context = load_asset_context(ctx)
    style_context = load_style_context(ctx)
    scene_reference_context = load_scene_reference_context(ctx)
    tasks = []
    for atom in atoms:
        atom_id = str(atom.get("id"))
        named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
        scene_refs = scene_references_for_atom(atom, scene_reference_context)
        first_path = Path("keyframes") / f"{safe_name(atom_id)}_first.png"
        raw_last = str(atom.get("last_frame_prompt", "")).strip()
        shot_design = normalize_shot_design(atom.get("shot_design"), atom)
        generation_strategy = normalize_generation_strategy(atom.get("generation_strategy"), atom)
        task = {
            "atomic_shot_id": atom_id,
            "storyboard_id": atom.get("storyboard_id"),
            "scene_id": atom.get("scene_id"),
            "duration": atom.get("duration", 5),
            "video_prompt": atom.get("video_prompt", ""),
            "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context),
            "first_frame_local_path": first_path.as_posix(),
            "frame_mode": "first_last" if raw_last else "first_frame_only",
            "render_mode": atom.get("render_mode", "i2v"),
            "reference_asset_names": atom.get("reference_asset_names", []),
            "scene_reference_ids": [ref.get("reference_id") for ref in scene_refs if ref.get("reference_id")],
            "scene_reference_local_paths": [ref.get("local_path") for ref in scene_refs if ref.get("local_path")],
            "control_frame_role": generation_strategy.get("control_frame_role"),
            "frame_must_show": default_frame_must_show(atom, generation_strategy),
            "frame_must_not_show": default_frame_must_not_show(atom, generation_strategy),
            "motion_to_generate": atom.get("video_prompt", ""),
            "shot_design": shot_design,
            "generation_strategy": generation_strategy,
            "continuity_state_start": atom.get("continuity_state_start"),
            "continuity_state_end": atom.get("continuity_state_end"),
        }
        if raw_last:
            last_path = Path("keyframes") / f"{safe_name(atom_id)}_last.png"
            task["last_frame_prompt"] = frame_prompt(raw_last, named_assets, style_context)
            task["last_frame_local_path"] = last_path.as_posix()
        tasks.append(task)
    return tasks


def ensure_asset_anchors(ctx: SkillContext, style_context: str = "", only_names: set[str] | None = None) -> dict[str, str]:
    """为每个 asset 生成一张稳定锚点图并缓存进 stages/02_assets.json：
    地点->canon 基准空镜（统一结构、人群背对镜头、无主要人物特写）；角色->定妆图；道具->干净单体图。
    已有锚点的跳过，便于断点续跑复用。返回 name -> 可直接喂图像生成的 ref：
    优先本地锚点图（base64 data URI，永不过期）；无本地文件才回退 TOS URL（24h 过期，曾导致复用失败）。"""
    stage = ctx.workspace.read_stage("02_assets.json")
    assets = list(stage.get("assets") or [])
    # Consistency Bible：统一校服 + 各地点固定布局，烘进每张锚点图，保证跨镜头统一。
    bible = ctx.workspace.read_stage("00b_consistency.json")
    uniform = str(bible.get("uniform") or "")
    layouts = bible.get("location_layouts") or {}
    anchors: dict[str, str] = {}
    changed = False
    for asset in assets:
        name = str(asset.get("name") or "").strip()
        if not name:
            continue
        if only_names is not None and name not in only_names:
            continue
        local = str(asset.get("reference_image_local_path") or "")
        if local and Path(local).exists():
            anchors[name] = media_ref(local)
            continue
        fallback = ctx.workspace.assets_dir / f"{safe_name(name)}.png"
        if fallback.exists():
            asset["reference_image_local_path"] = str(fallback)
            anchors[name] = media_ref(str(fallback))
            changed = True
            continue
        if asset.get("reference_image_url"):
            anchors[name] = str(asset["reference_image_url"])
            continue
        url = ctx.ark.generate_image(anchor_prompt(asset, style_context, uniform=uniform, layout=str(layouts.get(name) or "")))
        path = ctx.ark.download(url, ctx.workspace.assets_dir / f"{safe_name(name)}.png")
        asset["reference_image_url"] = url
        asset["reference_image_local_path"] = str(path)
        anchors[name] = media_ref(str(path))
        changed = True
    if changed:
        ctx.workspace.write_stage("02_assets.json", {**stage, "assets": assets})
    return anchors


def anchor_prompt(asset: dict[str, Any], style_context: str = "", uniform: str = "", layout: str = "") -> str:
    asset_type = str(asset.get("type", "asset")).strip()
    name = str(asset.get("name", "")).strip()
    visual = str(asset.get("visual_anchor_prompt") or asset.get("description") or "").strip()
    style_line = f"风格摘要：{compact_style_summary(style_context)}\n" if style_context else ""
    consistency = ""
    if asset_type == "location" and layout:
        consistency += f"该地点固定布局（必须与全片一致）：{layout}\n"
    if uniform and asset_type in ("location", "character"):
        consistency += f"统一校服（画面中学生一律遵守）：{uniform}\n"
    style_line += consistency
    if asset_type == "location":
        framing = (
            f"{name} 的统一基准空镜（canon base），竖屏9:16；"
            "完整交代地点结构与陈设，统一校服的学生在前景/中景/远景纵深错落分布、有单独走的也有两三人结伴的、"
            "彼此拉开自然间距地朝场景纵深方向流动（自然分散、不拥挤、不聚堆成团、不排队列队），无主要人物特写、不依赖文字招牌、无海报无拼贴。"
            "光线为自然明亮均匀的日光、自然真实色彩，不要浓雾、不要强烈丁达尔光束/光柱、避免强逆光剪影与过度滤镜。"
        )
    elif asset_type == "character":
        framing = (
            f"{name} 的角色定妆参考图（character sheet），单人、全身、正面、中性自然站姿、"
            "纯净浅灰摄影棚背景、均匀柔光，无文字、无海报、无拼贴。"
        )
    else:
        framing = (
            f"{name} 的道具参考图，干净背景单体呈现，写实质感，无文字、无海报、无拼贴。"
        )
    return f"{style_line}{framing}\n{visual}"


def normalize_id_filter(value: Any) -> set[str]:
    if not value:
        return set()
    if isinstance(value, str):
        return {item.strip() for item in value.split(",") if item.strip()}
    if isinstance(value, list):
        return {str(item).strip() for item in value if str(item).strip()}
    return set()


def durable_media_ref(local_path: str, url: str = "") -> str:
    """优先本地文件（base64 data URI，永不过期），无本地文件才回退 URL（TOS URL 24h 过期）。"""
    local_path = (local_path or "").strip()
    if local_path and Path(local_path).exists():
        return media_ref(local_path)
    return (url or "").strip()


def asset_image_refs(names: list[str], asset_context: dict[str, dict[str, Any]]) -> list[str]:
    """按 location -> character -> prop 优先级取资产锚点图 refs（本地优先，不过期），喂图片生成。"""
    refs: list[str] = []
    for want in ("location", "character", "prop"):
        for n in names:
            asset = asset_context.get(n) or {}
            if str(asset.get("type")) != want:
                continue
            ref = durable_media_ref(str(asset.get("reference_image_local_path") or ""), str(asset.get("reference_image_url") or ""))
            if ref and ref not in refs:
                refs.append(ref)
    return refs


def t2v_reference_urls(ctx: SkillContext, kf: dict[str, Any], asset_context: dict[str, dict[str, Any]], scene_reference_context: dict[str, list[dict[str, Any]]] | None = None) -> list[str]:
    """t2v 镜的 reference_image，按优先级截断（cap 4）：无脸背影方向首帧 + 场景参考图 + 地点/角色资产锚点。
    无脸背影首帧用来给 t2v『带』方向与构图，场景参考图维持空间/光线/轴线，资产图维持身份。"""
    refs: list[str] = []
    back_view = durable_media_ref(str(kf.get("first_frame_local_path") or ""), str(kf.get("first_frame_url") or ""))
    if back_view:
        refs.append(back_view)
    for ref in scene_reference_image_refs(ctx, kf, scene_reference_context or {}):
        if ref and ref not in refs:
            refs.append(ref)
    names = kf.get("reference_asset_names") or []
    for want in ("location", "character", "prop"):
        for n in names:
            asset = asset_context.get(n) or {}
            if str(asset.get("type")) != want:
                continue
            ref = durable_media_ref(str(asset.get("reference_image_local_path") or ""), str(asset.get("reference_image_url") or ""))
            if ref and ref not in refs:
                refs.append(ref)
    return refs[:4]


def continuity_reference_urls(task_order: list[str], existing: dict[str, dict[str, Any]], atom_id: str) -> list[str]:
    """取最近一个已生成成功镜头的首帧作参考图，给后一镜首帧做跨镜连续性。
    只喂给图片生成（首帧→首帧有助一致性），绝不喂给视频生成（参考图会带歪视频方向）。优先本地图（不过期）。"""
    if atom_id not in task_order:
        return []
    index = task_order.index(atom_id)
    for previous_id in reversed(task_order[:index]):
        previous = existing.get(previous_id) or {}
        if previous.get("state") != "ready":
            continue
        ref = durable_media_ref(str(previous.get("first_frame_local_path") or ""), str(previous.get("first_frame_url") or ""))
        if ref:
            return [ref]
    return []


def ark_image_prompt(prompt: str) -> str:
    """Ark 文生图的通用硬约束（与具体项目无关）。
    项目专属的方向/连续性（哪座门、谁穿什么、往哪走）应写进该原子镜头的
    first_frame_prompt（数据层），不要写死在框架代码里。"""
    constraints = [
        "Ark text-to-image hard constraints: vertical 9:16 cinematic realistic control frame.",
        "Do not render readable Chinese or English text anywhere; signs, plaques, labels, uniforms, papers, and posters must be blank, shadowed, cropped, or too defocused to read.",
        "No watermark, no logo, no subtitles, no captions, no UI, no poster layout, no collage.",
        "Lock motion direction with camera-relative framing: for action or direction shots use a back or over-the-shoulder view with the destination in the deep background; for dialogue use over-the-shoulder framing and avoid two large frontal faces.",
    ]
    return prompt + "\n\n" + "\n".join(constraints)


class VideoGenerateArkSkill:
    id = "video_generate_ark"
    description = "基于已确认关键帧，按 render_mode 分流生成视频：i2v 走无脸背影首帧（锁方向+过审），t2v 走文生视频（无脸背影首帧+canon+定妆图作参考图保方向/场景/身份）。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        keyframes = list(ctx.workspace.read_stage("05_keyframes.json").get("keyframes") or [])
        if not keyframes:
            return SkillResult(False, "没有找到 keyframes", {})
        clips = []
        previous: str | None = None
        # 默认不把前一段视频当参考喂给视频生成：实测参考视频/参考图会把相机拽正、带歪方向，
        # 还容易触发审核。方向由背影首帧锁定。仅在用户显式传 chain_reference_video 时才链式参考。
        chain_reference_video = bool(input_data.get("chain_reference_video"))
        style_context = load_style_context(ctx)
        asset_context = load_asset_context(ctx)
        scene_reference_context = load_scene_reference_context(ctx)
        # i2v 首帧被 PrivacyInformation 拦时自动无脸重试要用到原始首帧 prompt，从 plan 取。
        plan_tasks = {
            str(t.get("atomic_shot_id")): t
            for t in ctx.workspace.read_stage("05_keyframe_plan.json").get("keyframe_tasks") or []
        }
        for kf in keyframes:
            try:
                atom_id = str(kf.get("atomic_shot_id"))
                render_mode = str(kf.get("render_mode") or "i2v")
                prompt = video_prompt_with_style(str(kf.get("video_prompt", "")), style_context)
                dur = int(kf.get("duration") or 5)
                if not 5 <= dur <= 10:
                    kf = {**kf, "duration_clamped_from": dur}
                    dur = max(5, min(10, dur))
                if render_mode == "t2v":
                    # 露脸/对话镜：纯文生视频规避 i2v 真实人脸审核；无脸背影首帧+canon+定妆图作 reference_image 维持方向/场景/身份。
                    url = ctx.ark.generate_video_t2v(prompt, duration=dur, reference_image_urls=t2v_reference_urls(ctx, kf, asset_context, scene_reference_context))
                else:
                    # 首帧本地优先（TOS URL 24h 过期，曾导致复用失败）。
                    first_frame = durable_media_ref(str(kf.get("first_frame_local_path") or ""), str(kf.get("first_frame_url") or ""))
                    if not first_frame:
                        raise ValueError(f"{atom_id} 缺少首帧")
                    ref_videos = [previous] if (chain_reference_video and previous) else None
                    try:
                        url = ctx.ark.generate_video(prompt, first_frame, duration=dur, reference_video_urls=ref_videos)
                    except RuntimeError as exc:
                        if "InputImageSensitiveContentDetected" not in str(exc):
                            raise
                        # 首帧含真人脸被审核拦下：自动重出一张严格无脸版首帧，重试一次（脸在输出视频里照常出现）。
                        base_ff_prompt = str((plan_tasks.get(atom_id) or {}).get("first_frame_prompt") or kf.get("first_frame_prompt") or "")
                        if not base_ff_prompt:
                            raise
                        faceless_prompt = (
                            base_ff_prompt
                            + "\n【无脸强制改写】画面中所有人物一律只以背影/正后方呈现，或面部被前景物件完全遮挡；"
                            "完全看不到任何人脸，连侧脸轮廓也不可见。"
                        )
                        refs = scene_reference_image_refs(ctx, kf, scene_reference_context) + asset_image_refs(list(kf.get("reference_asset_names") or []), asset_context)
                        new_first_url = ctx.ark.generate_image(ark_image_prompt(faceless_prompt), refs=refs or None)
                        first_path = resolve_workspace_path(ctx, kf.get("first_frame_local_path")) or ctx.workspace.keyframes_dir / f"{safe_name(atom_id)}_first.png"
                        ctx.ark.download(new_first_url, first_path)
                        kf = {**kf, "first_frame_url": new_first_url, "first_frame_local_path": str(first_path), "auto_faceless_retry": True}
                        url = ctx.ark.generate_video(prompt, str(first_path), duration=dur, reference_video_urls=ref_videos)
                previous = url
                local = ctx.ark.download(url, ctx.workspace.clips_dir / f"{safe_name(atom_id)}.mp4")
                clips.append({**kf, "state": "ready", "video_url": url, "video_local_path": str(local)})
            except Exception as exc:
                clips.append({**kf, "state": "failed", "error": str(exc)})
        out = {"source": self.id, "clips": clips, "success": sum(c.get("state") == "ready" for c in clips), "failed": sum(c.get("state") == "failed" for c in clips)}
        ctx.workspace.write_stage("06_videos.json", out)
        write_review_markdown(ctx.workspace.review_dir / "06_videos.md", "视频生成审阅", out)
        return SkillResult(True, "视频生成流程已完成", {"file": "stages/06_videos.json", "success": out["success"], "failed": out["failed"]})


class SceneTransitionPlanSkill:
    id = "scene_transition_plan"
    description = "根据已生成视频和跨场景连续性，规划大场景之间的连贯转场参考视频。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        clips = list(ctx.workspace.read_stage("06_videos.json").get("clips") or [])
        scene_bible = ctx.workspace.read_stage("00c_scene_bible.json")
        cross_scene = ctx.workspace.read_stage("00e_cross_scene_continuity.json")
        if not clips:
            return SkillResult(False, "未找到 stages/06_videos.json 中的视频片段，请先运行 video_generate_ark", {})
        scenes = list(scene_bible.get("scenes") or [])
        if len(scenes) < 2:
            return SkillResult(False, "少于两个大场景，不需要生成大场景转场参考", {})
        clips_by_scene: dict[str, list[dict[str, Any]]] = {}
        for clip in clips:
            scene_id = str(clip.get("scene_id") or "").strip()
            if scene_id and clip.get("state") == "ready":
                clips_by_scene.setdefault(scene_id, []).append(clip)
        transitions = list(cross_scene.get("transitions") or [])
        tasks = []
        for idx in range(len(scenes) - 1):
            from_scene = scenes[idx]
            to_scene = scenes[idx + 1]
            from_scene_id = str(from_scene.get("scene_id") or "")
            to_scene_id = str(to_scene.get("scene_id") or "")
            previous_clip = last_ready_clip(clips_by_scene.get(from_scene_id) or [])
            next_anchor = first_scene_reference(ctx, to_scene_id)
            transition = find_transition(transitions, from_scene_id, to_scene_id)
            task_id = safe_name(f"{from_scene_id}_to_{to_scene_id}")
            tasks.append(
                {
                    "transition_id": task_id,
                    "from_scene_id": from_scene_id,
                    "to_scene_id": to_scene_id,
                    "previous_scene_video_url": previous_clip.get("video_url", "") if previous_clip else "",
                    "previous_scene_video_local_path": previous_clip.get("video_local_path", "") if previous_clip else "",
                    "next_scene_reference_id": next_anchor.get("reference_id", "") if next_anchor else "",
                    "next_scene_reference_local_path": next_anchor.get("local_path", "") if next_anchor else "",
                    "duration": int(input_data.get("duration") or 5),
                    "transition_prompt": scene_transition_prompt(from_scene, to_scene, transition),
                    "continuity_requirements": transition.get("required_carryovers") or [],
                    "forbidden_jumps": transition.get("forbidden_jumps") or [],
                    "status": "ready_to_generate" if previous_clip else "missing_previous_scene_video",
                }
            )
        out = {
            "source": self.id,
            "video_provider": "ark",
            "prompt_contract": {
                "previous_scene_video": "优先使用上一大场景最后一个 ready clip 作为 reference_video。",
                "next_scene_reference": "优先使用下一大场景的 location_master_plate 作为 reference_image。",
                "rule": "转场参考视频用于帮助用户判断两个大场景之间的状态接力，不替代正式分镜。",
            },
            "transition_tasks": tasks,
        }
        ctx.workspace.write_stage("06b_scene_transition_plan.json", out)
        write_review_markdown(ctx.workspace.review_dir / "06b_scene_transition_plan.md", "大场景转场参考计划审阅", out)
        return SkillResult(True, "大场景转场参考计划已生成", {"file": "stages/06b_scene_transition_plan.json", "count": len(tasks)})


class SceneTransitionGenerateArkSkill:
    id = "scene_transition_generate_ark"
    description = "备用路径：通过 Ark 生成大场景之间的连贯转场参考视频。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("06b_scene_transition_plan.json")
        tasks = list(plan.get("transition_tasks") or [])
        if not tasks:
            return SkillResult(False, "未找到转场参考计划，请先运行 scene_transition_plan", {})
        only_ids = normalize_id_filter(input_data.get("transition_ids") or input_data.get("ids"))
        overwrite = bool(input_data.get("overwrite"))
        selected = [task for task in tasks if not only_ids or str(task.get("transition_id")) in only_ids]
        existing = {
            str(item.get("transition_id")): item
            for item in ctx.workspace.read_stage("06b_scene_transitions.json").get("transitions") or []
            if item.get("transition_id")
        }
        generated = 0
        skipped = 0
        failed = 0
        for task in selected:
            transition_id = str(task.get("transition_id"))
            output_path = ctx.workspace.clips_dir / "transitions" / f"{safe_name(transition_id)}.mp4"
            current = dict(existing.get(transition_id) or {})
            if output_path.exists() and not overwrite:
                skipped += 1
                existing[transition_id] = {**current, **task, "video_local_path": str(output_path), "state": "ready"}
                continue
            try:
                previous_url = str(task.get("previous_scene_video_url") or "").strip()
                if not previous_url.startswith(("http://", "https://")):
                    raise ValueError("缺少可供 Ark 使用的上一场景 video_url，无法生成转场参考视频")
                refs = []
                next_ref = resolve_workspace_path(ctx, task.get("next_scene_reference_local_path"))
                if next_ref and next_ref.exists():
                    refs.append(str(next_ref))
                prompt = video_prompt_with_style(str(task.get("transition_prompt") or ""), load_style_context(ctx))
                url = ctx.ark.generate_video_t2v(
                    prompt,
                    duration=int(task.get("duration") or 5),
                    reference_video_urls=[previous_url],
                    reference_image_urls=refs or None,
                )
                local = ctx.ark.download(url, output_path)
                generated += 1
                existing[transition_id] = {**task, "video_url": url, "video_local_path": str(local), "state": "ready"}
            except Exception as exc:
                failed += 1
                existing[transition_id] = {**current, **task, "state": "failed", "error": str(exc)}
        transitions = [existing[str(task.get("transition_id"))] for task in tasks if str(task.get("transition_id")) in existing]
        out = {
            "source": self.id,
            "transitions": transitions,
            "success": sum(item.get("state") == "ready" for item in transitions),
            "failed": sum(item.get("state") == "failed" for item in transitions),
            "total_planned": len(tasks),
        }
        ctx.workspace.write_stage("06b_scene_transitions.json", out)
        write_review_markdown(ctx.workspace.review_dir / "06b_scene_transitions.md", "大场景转场参考视频审阅", out)
        ok = generated > 0 or skipped > 0
        return SkillResult(ok, "大场景转场参考视频生成完成" if ok else "大场景转场参考视频生成失败", {"file": "stages/06b_scene_transitions.json", "generated": generated, "skipped": skipped, "failed": failed})


class StageRerunAdvisorSkill:
    id = "stage_rerun_advisor"
    description = "在用户修改某个阶段或大场景后，提示后续哪些阶段需要重跑或复查。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        changed_stage = normalize_stage_name(str(input_data.get("changed_stage") or input_data.get("stage") or "")).strip()
        changed_file = str(input_data.get("changed_file") or "").strip()
        scene_id = str(input_data.get("scene_id") or "").strip()
        graph = stage_dependency_graph()
        stale = stale_stage_reports(ctx, graph)
        impacted = []
        if changed_stage:
            impacted = impacted_downstream_stages(changed_stage, graph)
        elif changed_file:
            mapped = stage_name_from_path(changed_file)
            if mapped:
                changed_stage = mapped
                impacted = impacted_downstream_stages(changed_stage, graph)
        recommendations = rerun_recommendations(changed_stage, impacted, stale, scene_id)
        out = {
            "source": self.id,
            "changed_stage": changed_stage,
            "changed_file": changed_file,
            "scene_id": scene_id,
            "stale_stages": stale,
            "impacted_downstream_stages": impacted,
            "recommendations": recommendations,
            "how_to_continue": "先重跑 recommendations 中标记 rerun 的阶段；标记 review_only 的阶段至少打开对应 review/user_<skill>.md 复查。",
        }
        ctx.workspace.write_stage("08_stage_rerun_advisor.json", out)
        write_review_markdown(ctx.workspace.review_dir / "08_stage_rerun_advisor.md", "阶段重跑建议审阅", out)
        return SkillResult(True, "阶段重跑建议已生成", {"file": "stages/08_stage_rerun_advisor.json", "rerun_count": sum(1 for item in recommendations if item.get("action") == "rerun")})


class KnowledgeCaptureSkill:
    id = "knowledge_capture"
    description = "把已确认的分镜、镜头、风格或 prompt 模式沉淀为项目级/全局知识卡。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        source_text, source_ref = resolve_capture_source(ctx, input_data)
        if not source_text.strip():
            return SkillResult(False, "缺少 source_text、source_stage 或 source_file", {})

        scope = str(input_data.get("scope") or "project").lower()
        if scope not in {"project", "global", "both"}:
            return SkillResult(False, "scope 必须是 project、global 或 both", {})

        tags = input_data.get("tags") or []
        if isinstance(tags, str):
            tags = [tag.strip() for tag in tags.split(",") if tag.strip()]
        user_note = str(input_data.get("user_note") or input_data.get("note") or "").strip()
        title_hint = str(input_data.get("title") or "").strip()

        data = ctx.llm.chat_json(
            "你是 Storyforge 的 knowledge_capture。请从已确认产物中提炼可长期复用的制作知识。输出严格 JSON：{cards:[...]}。每张卡包含 title, type, tags, summary, when_to_use, do, avoid, prompt_patterns, examples, source_refs。要捕捉可复用做法、应避免错误、具体 prompt/摄影/动作模式。不要空泛夸奖，不要大段复制原文。所有字段值必须使用简体中文。",
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
                    "title": title_hint or "捕获的制作模式",
                    "type": "style",
                    "tags": tags,
                    "summary": user_note or "从已确认 Storyforge 产物中捕获的可复用制作模式。",
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
        write_review_markdown(ctx.workspace.review_dir / "07_knowledge_capture.md", "知识捕获审阅", review)
        ctx.workspace.append_log("知识已捕获", {"source_ref": source_ref, "scope": scope, "cards": len(cards)})
        return SkillResult(True, "知识已捕获", {"file": "stages/07_knowledge_capture.json", "cards": len(cards), "written": written})


def default_registry() -> SkillRegistry:
    return SkillRegistry([
        DocumentIngestSkill(),
        ScriptIngestSkill(),
        StyleSelectSkill(),
        ConsistencyBibleSkill(),
        SceneBibleSkill(),
        SceneReferencePlanSkill(),
        SceneReferenceImportSkill(),
        SceneReferenceGenerateArkSkill(),
        CrossSceneContinuitySkill(),
        AssetDesignSkill(),
        StoryboardPlanSkill(),
        AtomicShotPlanSkill(),
        ContinuityValidatorSkill(),
        KeyframePlanSkill(),
        KeyframeImportSkill(),
        KeyframeGenerateArkSkill(),
        VideoGenerateArkSkill(),
        SceneTransitionPlanSkill(),
        SceneTransitionGenerateArkSkill(),
        StageRerunAdvisorSkill(),
        KnowledgeCaptureSkill(),
    ])


def load_asset_context(ctx: SkillContext) -> dict[str, dict[str, Any]]:
    refs: dict[str, dict[str, Any]] = {}
    for asset in ctx.workspace.read_stage("02_assets.json").get("assets", []) or []:
        name = asset.get("name")
        if name:
            refs[str(name)] = dict(asset)
    return refs


def load_scene_reference_context(ctx: SkillContext) -> dict[str, list[dict[str, Any]]]:
    refs: dict[str, list[dict[str, Any]]] = {}
    sources = [
        ctx.workspace.read_stage("00d_scene_references.json").get("scene_references") or [],
        ctx.workspace.read_stage("00d_scene_reference_plan.json").get("scene_reference_tasks") or [],
    ]
    seen: set[str] = set()
    for source in sources:
        for item in source:
            if not isinstance(item, dict):
                continue
            ref_id = str(item.get("reference_id") or "").strip()
            scene_id = str(item.get("scene_id") or "").strip()
            if not ref_id or not scene_id or ref_id in seen:
                continue
            seen.add(ref_id)
            refs.setdefault(scene_id, []).append(dict(item))
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
        asset_lines.append(asset_prompt_line(asset))
    asset_context = "\n".join(asset_lines)
    asset_names = "、".join(str(asset.get("name", "")).strip() for asset in assets or [] if str(asset.get("name", "")).strip())
    base = (
        "竖屏9:16图生视频控制帧；无文字、无品牌、无UI、无拼贴。"
        "保持人物身份、服装、道具、地点、运动方向和物理状态连续。"
        "方向用相机相对语言；动作/方向镜用背影或过肩、把运动目的地放在画面纵深；对话镜用过肩、避免贴镜头大正脸。\n"
    )
    if style_context:
        base += f"风格摘要：{compact_style_summary(style_context)}\n"
    if asset_context:
        base += f"参考锚点：{asset_context}\n"
    full_prompt = base + prompt
    if len(full_prompt) <= 800 or not asset_names:
        return full_prompt
    compact_base = (
        "竖屏9:16图生视频控制帧；无文字、无品牌、无UI、无拼贴。"
        "保持人物身份、服装、道具、地点、运动方向和物理状态连续。"
        "方向用相机相对语言；动作/方向镜用背影或过肩、把运动目的地放在画面纵深；对话镜用过肩、避免贴镜头大正脸。\n"
    )
    if style_context:
        compact_base += f"风格摘要：{compact_style_summary(style_context)}\n"
    compact_base += f"参考锚点：{asset_names}（完整视觉锚点见 stages/02_assets.json）\n"
    return compact_base + prompt


# 电影/写实风格的打磨版摘要（经实测最接近真实参考片的配方）。
FILM_REAL_STYLE_SUMMARY = (
    "电影写实风格；胶片柔光质感、低对比、克制不过饱和、保留空气透视与轻微雾感的真实光线；"
    "自然纪实的真实抓拍氛围；写实自然表演；清晰空间连续性；"
    "避免锐利干净的CG/三维渲染感、避免网感滤镜与过度锐化、避免短剧夸张与漫画格。"
)


def compact_style_summary(style_context: str) -> str:
    """从所选风格档案提炼一句风格摘要。电影/写实类风格用打磨过的固定摘要；
    其他风格（短剧/漫剧/动画/纪实/自定义）从档案 label/visual_rules/avoid 动态拼，
    避免硬注入"电影写实"覆盖用户选择。"""
    text = (style_context or "").strip()
    profile: dict[str, Any] | None = None
    if text.startswith("{"):
        try:
            stage = json.loads(text)
            candidate = stage.get("style") if isinstance(stage, dict) else None
            profile = candidate if isinstance(candidate, dict) else (stage if isinstance(stage, dict) else None)
        except (json.JSONDecodeError, AttributeError):
            profile = None
    if profile and profile.get("label"):
        label = str(profile.get("label") or "").strip()
        if str(profile.get("id") or "") == "film" or "电影" in label or "写实" in label:
            return FILM_REAL_STYLE_SUMMARY
        rules = "、".join(str(r).strip() for r in (profile.get("visual_rules") or [])[:4] if str(r).strip())
        avoid = "、".join(str(a).strip() for a in (profile.get("avoid") or [])[:3] if str(a).strip())
        summary = f"{label}；{rules}" if rules else label
        if avoid:
            summary += f"；避免{avoid}"
        return summary
    # markdown(wiki/style.md) 路径：含电影/写实关键词或为空 -> 固定摘要；否则压缩前几行非空文本。
    if not text or "电影" in text or "写实" in text:
        return FILM_REAL_STYLE_SUMMARY
    lines = [line.strip("# ").strip() for line in text.splitlines() if line.strip()]
    return clip_text("；".join(lines[:3]), 120) or FILM_REAL_STYLE_SUMMARY


def normalize_asset_design(asset: dict[str, Any], idx: int) -> dict[str, Any]:
    """补齐影视资产圣经字段，同时保留旧流程依赖的 prompt 字段。"""
    item = dict(asset)
    name = str(item.get("name") or f"asset_{idx:03d}").strip()
    asset_type = str(item.get("type") or "asset").strip()
    description = str(item.get("description") or "").strip()
    visual_anchor = str(item.get("visual_anchor_prompt") or "").strip()
    negative = str(item.get("negative_prompt") or "").strip()
    consistency = str(item.get("consistency_notes") or "").strip()
    identity = str(item.get("visual_identity") or visual_anchor or description).strip()

    item.setdefault("asset_id", safe_name(f"{asset_type}_{name}"))
    item.setdefault("story_function", description or f"{name} 在剧本中的叙事资产。")
    item.setdefault("visual_identity", identity or f"{asset_type} {name} 的稳定影视外观身份。")
    item.setdefault(
        "visual_anchor_prompt",
        visual_anchor
        or f"{asset_type} {name} 的稳定制作参考；{description}；身份清晰、可复用，不要海报，不要拼贴。",
    )
    item.setdefault("negative_prompt", negative or "海报、拼贴、文字设定表、UI、服装不一致、地点结构漂移、道具形态漂移")
    item.setdefault("consistency_notes", consistency or "作为后续关键帧和视频镜头的身份、空间或道具锚点使用。")
    item.setdefault("continuity_invariants", [item["visual_identity"], item["consistency_notes"]])
    item.setdefault("allowed_variations", ["景别、机位、自然光影、表演强弱、局部遮挡可以随镜头变化。"])
    item.setdefault("forbidden_variations", [item["negative_prompt"]])
    item.setdefault(
        "cinematic_usage",
        {
            "best_framings": ["根据剧情使用建立镜头、中景调度、局部特写或过肩关系镜头。"],
            "lighting_notes": ["遵守所选风格档案与场景时间，不为单镜头随意改变光线方向。"],
            "movement_notes": ["运动方向、角色站位和道具状态必须承接前后镜头。"],
        },
    )
    item.setdefault(
        "generation_anchors",
        {
            "positive_prompt": item["visual_anchor_prompt"],
            "negative_prompt": item["negative_prompt"],
            "reference_priority": "高：该资产在画面中出现时必须优先遵守。",
        },
    )
    return item


def normalize_scene_bible(scene: dict[str, Any], idx: int) -> dict[str, Any]:
    scene_id = str(scene.get("scene_id") or f"SCENE_{idx:03d}").strip()
    name = str(scene.get("name") or scene.get("location") or scene_id).strip()
    location = str(scene.get("location") or name).strip()
    scene["scene_id"] = scene_id
    scene.setdefault("scene_nums", [])
    scene.setdefault("name", name)
    scene.setdefault("location", location)
    scene.setdefault("story_purpose", f"{name} 的剧情场景。")
    scene.setdefault("time_weather_light", "时间、天气、主光方向、阴影方向和色温必须在该大场景内保持一致。")
    scene.setdefault("spatial_map", "写清入口、出口、道路、墙面、门窗、桌椅或关键固定物的位置关系。")
    scene.setdefault("entrances_exits", [])
    scene.setdefault("screen_direction_rules", ["同一动作线的运动方向和镜头左右关系不得反向。"])
    scene.setdefault(
        "camera_coverage_plan",
        {
            "establishing": "先用建立镜头交代空间与人流/环境。",
            "main_action": "主动作镜头承接建立镜头的轴线和运动方向。",
            "insert": "用局部特写锁定关键道具、动作触发点或物理状态。",
            "reaction": "困难动作后用反应镜头和余波收束。",
            "transition": "用空间方向或动作末态自然转入下一场景。",
        },
    )
    scene.setdefault("crowd_rules", [])
    scene.setdefault("character_state_rules", {})
    scene.setdefault("prop_state_rules", {})
    scene.setdefault("physics_rules", ["人物、车辆、球、道具不能瞬移、穿模或无因果改变速度/方向。"])
    scene.setdefault(
        "scene_reference_frames",
        {
            "location_master_plate": f"{location} 的竖屏9:16场地总览，锁定空间结构、光线方向和人群规则。",
            "camera_angle_plates": [f"{location} 的主要动作机位参考图。"],
            "prop_placement_plate": f"{location} 中关键道具位置、朝向和持有人状态参考图。",
        },
    )
    scene.setdefault("continuity_contract", ["后续分镜、原子镜头、关键帧必须继承本 scene_bible 的空间、光线、轴线、道具和物理规则。"])
    scene.setdefault("prompt_injection", scene_prompt_injection(scene))
    return scene


def scene_prompt_injection(scene: dict[str, Any]) -> str:
    return (
        f"场景制作包：{scene.get('name') or scene.get('scene_id')}；地点：{scene.get('location')}；"
        f"光线/时间：{clip_text(inline_text(scene.get('time_weather_light')), 80)}；"
        f"空间关系：{clip_text(inline_text(scene.get('spatial_map')), 100)}；"
        f"轴线方向：{clip_text(inline_text(scene.get('screen_direction_rules')), 100)}。"
    )


def scene_reference_tasks_for_scene(scene: dict[str, Any], style_context: str = "") -> list[dict[str, Any]]:
    scene_id = str(scene.get("scene_id") or safe_name(str(scene.get("name") or scene.get("location") or "scene"))).strip()
    refs = scene.get("scene_reference_frames") if isinstance(scene.get("scene_reference_frames"), dict) else {}
    rows: list[tuple[str, str, Any]] = [
        ("location_master_plate", "场地总览参考图", refs.get("location_master_plate") or f"{scene.get('location', scene_id)} 的场地总览参考图。"),
        ("prop_placement_plate", "道具摆放参考图", refs.get("prop_placement_plate") or f"{scene.get('location', scene_id)} 的关键道具摆放参考图。"),
    ]
    camera_plates = refs.get("camera_angle_plates") or [f"{scene.get('location', scene_id)} 的主动作机位参考图。"]
    if isinstance(camera_plates, str):
        camera_plates = [camera_plates]
    for idx, value in enumerate(camera_plates, 1):
        rows.append((f"camera_angle_plate_{idx:02d}", f"机位参考图{idx:02d}", value))

    tasks = []
    for role, label, source_prompt in rows:
        ref_id = safe_name(f"{scene_id}_{role}")
        tasks.append(
            {
                "reference_id": ref_id,
                "scene_id": scene_id,
                "reference_role": role,
                "label": label,
                "local_path": (Path("assets") / "scene_refs" / f"{ref_id}.png").as_posix(),
                "prompt": scene_reference_prompt(scene, label, source_prompt, style_context),
                "must_show": scene_reference_must_show(scene, role),
                "must_not_show": scene_reference_must_not_show(),
                "status": "needs_codex_image_generation",
            }
        )
    return tasks


def scene_reference_prompt(scene: dict[str, Any], label: str, source_prompt: Any, style_context: str = "") -> str:
    parts = [
        "竖屏9:16影视场景参考图；这是后续多个分镜共享的场景锚点，不是海报，不是分镜漫画，不是设定集排版。",
        f"参考图类型：{label}。",
        f"场景：{scene.get('name') or scene.get('scene_id')}；地点：{scene.get('location', '')}。",
        f"风格摘要：{compact_style_summary(style_context)}" if style_context else "",
        f"时间天气光线：{inline_text(scene.get('time_weather_light'))}",
        f"空间地图：{inline_text(scene.get('spatial_map'))}",
        f"入口出口：{inline_text(scene.get('entrances_exits'))}",
        f"轴线与运动方向规则：{inline_text(scene.get('screen_direction_rules'))}",
        f"人群规则：{inline_text(scene.get('crowd_rules'))}",
        f"人物状态规则：{inline_text(scene.get('character_state_rules'))}",
        f"道具状态规则：{inline_text(scene.get('prop_state_rules'))}",
        f"物理规则：{inline_text(scene.get('physics_rules'))}",
        f"该参考图具体要求：{inline_text(source_prompt)}",
        "画面要清楚交代空间、光线、方向和道具位置；可以有人群背影或远景人物，但不要主要角色大脸特写。",
        "无可读文字、无字幕、无标题字、无水印、无logo、无UI、无拼贴。",
    ]
    return "\n".join(part for part in parts if part)


def scene_reference_must_show(scene: dict[str, Any], role: str) -> list[str]:
    items = [
        f"场景地点：{scene.get('location', '')}",
        f"光线状态：{inline_text(scene.get('time_weather_light'))}",
        f"空间地图：{inline_text(scene.get('spatial_map'))}",
        f"轴线方向：{inline_text(scene.get('screen_direction_rules'))}",
    ]
    if role == "prop_placement_plate":
        items.append(f"关键道具状态：{inline_text(scene.get('prop_state_rules'))}")
    if role.startswith("camera_angle_plate"):
        items.append(f"机位覆盖计划：{inline_text(scene.get('camera_coverage_plan'))}")
    return [item for item in items if item and not item.endswith("：")]


def scene_reference_must_not_show() -> list[str]:
    return [
        "清晰可读文字、字幕、标题字、水印、logo、UI 或拼贴排版",
        "与 Scene Bible 冲突的入口出口、光线方向、道具位置或人群朝向",
        "主要角色大正脸特写或与后续分镜无关的抢画面人物",
        "无法复用的海报感、概念图感、舞台布景感",
    ]


def scene_references_for_atom(atom: dict[str, Any], scene_reference_context: dict[str, list[dict[str, Any]]], limit: int = 3) -> list[dict[str, Any]]:
    scene_id = str(atom.get("scene_id") or "").strip()
    if not scene_id:
        return []
    refs = list(scene_reference_context.get(scene_id) or [])
    if not refs:
        return []
    priority = {
        "location_master_plate": 0,
        "prop_placement_plate": 1,
    }
    refs.sort(key=lambda item: priority.get(str(item.get("reference_role")), 2))
    return refs[:limit]


def scene_references_for_task(task: dict[str, Any], scene_reference_context: dict[str, list[dict[str, Any]]], limit: int = 3) -> list[dict[str, Any]]:
    ids = [str(value) for value in task.get("scene_reference_ids") or [] if str(value).strip()]
    if ids:
        by_id = {str(item.get("reference_id")): item for rows in scene_reference_context.values() for item in rows}
        return [by_id[ref_id] for ref_id in ids if ref_id in by_id][:limit]
    scene_id = str(task.get("scene_id") or "").strip()
    return list(scene_reference_context.get(scene_id) or [])[:limit] if scene_id else []


def scene_reference_media_ref(ctx: SkillContext, scene_ref: dict[str, Any]) -> str:
    local = resolve_workspace_path(ctx, scene_ref.get("local_path"))
    if local and local.exists():
        return media_ref(str(local))
    url = str(scene_ref.get("reference_url") or scene_ref.get("url") or "").strip()
    if url.startswith(("http://", "https://", "data:")):
        return url
    return ""


def scene_reference_image_refs(ctx: SkillContext, task: dict[str, Any], scene_reference_context: dict[str, list[dict[str, Any]]], limit: int = 2) -> list[str]:
    refs: list[str] = []
    for scene_ref in scene_references_for_task(task, scene_reference_context, limit=limit):
        ref = scene_reference_media_ref(ctx, scene_ref)
        if ref and ref not in refs:
            refs.append(ref)
    return refs


def last_ready_clip(clips: list[dict[str, Any]]) -> dict[str, Any]:
    ready = [clip for clip in clips if clip.get("state") == "ready"]
    return ready[-1] if ready else {}


def first_scene_reference(ctx: SkillContext, scene_id: str) -> dict[str, Any]:
    refs = load_scene_reference_context(ctx).get(scene_id) or []
    for role in ("location_master_plate", "camera_angle_plate_01", "prop_placement_plate"):
        for ref in refs:
            if str(ref.get("reference_role")) == role:
                return ref
    return refs[0] if refs else {}


def find_transition(transitions: list[dict[str, Any]], from_scene_id: str, to_scene_id: str) -> dict[str, Any]:
    for item in transitions:
        if str(item.get("from_scene_id")) == from_scene_id and str(item.get("to_scene_id")) == to_scene_id:
            return item
    return {}


def scene_transition_prompt(from_scene: dict[str, Any], to_scene: dict[str, Any], transition: dict[str, Any]) -> str:
    return (
        "生成一段竖屏9:16的大场景转场参考视频，时长约5秒。"
        f"从上一大场景《{from_scene.get('name', from_scene.get('scene_id', ''))}》自然过渡到下一大场景《{to_scene.get('name', to_scene.get('scene_id', ''))}》。"
        f"必须承接：{inline_text(transition.get('required_carryovers'))}。"
        f"允许变化：{inline_text(transition.get('permitted_changes'))}。"
        f"禁止跳变：{inline_text(transition.get('forbidden_jumps'))}。"
        "镜头语言以参考为主，不作为正式剧情分镜；重点展示人物/道具/情绪/空间状态如何从上一场合理进入下一场。"
    )


def stage_dependency_graph() -> dict[str, dict[str, Any]]:
    return {
        "00_document.json": {"skill": "document_ingest", "deps": []},
        "01_script.json": {"skill": "script_ingest", "deps": ["00_document.json"]},
        "00_style.json": {"skill": "style_select", "deps": ["01_script.json"]},
        "00b_consistency.json": {"skill": "consistency_bible", "deps": ["01_script.json", "00_style.json"]},
        "00c_scene_bible.json": {"skill": "scene_bible", "deps": ["01_script.json", "00_style.json", "00b_consistency.json"]},
        "00d_scene_reference_plan.json": {"skill": "scene_reference_plan", "deps": ["00c_scene_bible.json", "00_style.json"]},
        "00d_scene_references.json": {"skill": "scene_reference_import 或 scene_reference_generate_ark", "deps": ["00d_scene_reference_plan.json"]},
        "00e_cross_scene_continuity.json": {"skill": "cross_scene_continuity", "deps": ["01_script.json", "00c_scene_bible.json", "00d_scene_reference_plan.json"]},
        "02_assets.json": {"skill": "asset_design", "deps": ["01_script.json", "00_style.json", "00b_consistency.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json"]},
        "03_storyboards.json": {"skill": "storyboard_plan", "deps": ["01_script.json", "00_style.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json", "02_assets.json"]},
        "04_atomic_shots.json": {"skill": "atomic_shot_plan", "deps": ["03_storyboards.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json", "02_assets.json"]},
        "04b_continuity_validation.json": {"skill": "continuity_validator", "deps": ["00c_scene_bible.json", "00e_cross_scene_continuity.json", "03_storyboards.json", "04_atomic_shots.json"]},
        "05_keyframe_plan.json": {"skill": "keyframe_plan", "deps": ["04_atomic_shots.json", "04b_continuity_validation.json", "00d_scene_references.json", "02_assets.json"]},
        "05_keyframes.json": {"skill": "keyframe_import 或 keyframe_generate_ark", "deps": ["05_keyframe_plan.json"]},
        "06_videos.json": {"skill": "video_generate_ark", "deps": ["05_keyframes.json", "05_keyframe_plan.json", "00d_scene_references.json"]},
        "06b_scene_transition_plan.json": {"skill": "scene_transition_plan", "deps": ["06_videos.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json"]},
        "06b_scene_transitions.json": {"skill": "scene_transition_generate_ark", "deps": ["06b_scene_transition_plan.json"]},
    }


def stale_stage_reports(ctx: SkillContext, graph: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    reports = []
    for stage, meta in graph.items():
        stage_path = ctx.workspace.stage_path(stage)
        if not stage_path.exists():
            continue
        stage_mtime = stage_path.stat().st_mtime
        newer_deps = []
        for dep in meta.get("deps") or []:
            dep_path = ctx.workspace.stage_path(dep)
            if dep_path.exists() and dep_path.stat().st_mtime > stage_mtime:
                newer_deps.append(dep)
        if newer_deps:
            reports.append({"stage": stage, "skill": meta.get("skill"), "reason": "依赖文件比当前 stage 更新", "newer_dependencies": newer_deps})
    return reports


def impacted_downstream_stages(changed_stage: str, graph: dict[str, dict[str, Any]]) -> list[str]:
    impacted: list[str] = []
    queue = [changed_stage]
    while queue:
        current = queue.pop(0)
        for stage, meta in graph.items():
            if stage in impacted:
                continue
            if current in (meta.get("deps") or []):
                impacted.append(stage)
                queue.append(stage)
    return impacted


def rerun_recommendations(changed_stage: str, impacted: list[str], stale: list[dict[str, Any]], scene_id: str = "") -> list[dict[str, Any]]:
    stale_stages = {item["stage"] for item in stale}
    graph = stage_dependency_graph()
    rows = []
    for stage in impacted:
        action = "rerun" if stage in stale_stages or changed_stage else "review_only"
        reason = "上游阶段已修改，需要重新生成或至少复查承接关系。"
        if scene_id and stage in {"03_storyboards.json", "04_atomic_shots.json", "05_keyframe_plan.json", "05_keyframes.json", "06_videos.json", "06b_scene_transition_plan.json"}:
            reason += f" 重点检查 scene_id={scene_id} 及其后续镜头。"
        rows.append({"stage": stage, "skill": (graph.get(stage) or {}).get("skill", ""), "action": action, "reason": reason})
    for item in stale:
        if item["stage"] not in impacted:
            rows.append({"stage": item["stage"], "skill": item.get("skill", ""), "action": "rerun", "reason": item.get("reason", ""), "newer_dependencies": item.get("newer_dependencies", [])})
    return rows


def stage_name_from_path(value: str) -> str:
    name = Path(value).name
    return normalize_stage_name(name)


def normalize_storyboard_design(sb: dict[str, Any]) -> dict[str, Any]:
    description = str(sb.get("description") or "").strip()
    first_frame = str(sb.get("first_frame_prompt") or "").strip()
    video_prompt = str(sb.get("video_prompt") or "").strip()
    continuity = str(sb.get("continuity") or "").strip()
    scene_num = str(sb.get("scene_num") or "").strip()
    sb.setdefault("scene_id", f"scene_{safe_name(scene_num)}" if scene_num else "")
    sb.setdefault("coverage_role", "主动作镜头")
    sb.setdefault("scene_bible_refs", [])
    sb.setdefault("dramatic_intent", description or "交代剧情信息并推进人物关系。")
    sb.setdefault("camera_design", first_frame or "根据场景空间选择清晰、可执行的电影机位。")
    sb.setdefault("blocking", description or "人物、道具与场地关系保持清楚。")
    sb.setdefault("screen_direction", continuity or "承接前后镜头的运动方向、视线方向与空间轴线。")
    sb.setdefault("edit_value", video_prompt or "镜头结束时提供可剪辑到下一镜的信息或情绪。")
    sb.setdefault("continuity_risks", [])
    return sb


def normalize_atomic_shot_design(atom: dict[str, Any]) -> dict[str, Any]:
    shot_design = normalize_shot_design(atom.get("shot_design"), atom)
    generation_strategy = normalize_generation_strategy(atom.get("generation_strategy"), atom)
    atom["shot_design"] = shot_design
    atom["generation_strategy"] = generation_strategy
    atom["render_mode"] = str(generation_strategy.get("render_mode") or atom.get("render_mode") or "i2v")
    generation_strategy["render_mode"] = atom["render_mode"]
    atom["continuity_state_start"] = normalize_continuity_state(atom.get("continuity_state_start"), "start")
    atom["continuity_state_end"] = normalize_continuity_state(atom.get("continuity_state_end"), "end")
    return atom


def normalize_continuity_state(value: Any, label: str) -> dict[str, Any]:
    if isinstance(value, dict):
        state = dict(value)
    elif value:
        state = {"summary": str(value)}
    else:
        state = {"summary": f"{label} state 未明确，请从上一阶段和 Scene Bible 推断。"}
    state.setdefault("characters", {})
    state.setdefault("camera", {})
    state.setdefault("lighting", "")
    state.setdefault("props", {})
    state.setdefault("location", "")
    state.setdefault("physics", "")
    return state


def normalize_shot_design(value: Any, atom: dict[str, Any]) -> dict[str, Any]:
    design = dict(value) if isinstance(value, dict) else {}
    design.setdefault("camera", str(atom.get("first_frame_prompt") or "").strip() or "用可执行机位锁定画面初态。")
    design.setdefault("movement", str(atom.get("video_prompt") or "").strip() or "镜头运动与人物运动保持自然、可剪辑。")
    design.setdefault("blocking", str(atom.get("purpose") or "").strip() or "人物与道具在空间中的相对位置清楚。")
    design.setdefault("performance", "表演自然克制，动作节拍符合真实身体力学。")
    design.setdefault("edit_intent", inline_text(atom.get("continuity_state_end")) or "镜头末态能自然接入下一镜。")
    return design


def normalize_generation_strategy(value: Any, atom: dict[str, Any]) -> dict[str, Any]:
    strategy = dict(value) if isinstance(value, dict) else {}
    render_mode = str(strategy.get("render_mode") or atom.get("render_mode") or "i2v").strip() or "i2v"
    strategy.setdefault("render_mode", render_mode)
    strategy.setdefault("first_frame_type", infer_first_frame_type(atom))
    strategy.setdefault("control_frame_role", infer_control_frame_role(atom))
    strategy.setdefault("reference_assets", atom.get("reference_asset_names", []))
    strategy.setdefault("failure_modes", default_generation_failure_modes(atom))
    strategy.setdefault("moderation_notes", "首帧避免清晰真人脸、可读文字、字幕、水印和 logo；输出视频可按剧情出现人物正脸。")
    return strategy


def infer_first_frame_type(atom: dict[str, Any]) -> str:
    prompt = str(atom.get("first_frame_prompt") or "")
    if any(token in prompt for token in ["车轮", "脚踏", "手部", "书包", "球拍", "道具", "特写"]):
        return "物件或局部动作特写"
    if any(token in prompt for token in ["空镜", "建立", "环境", "校门", "走廊", "操场"]):
        return "地点建立或环境控制帧"
    if any(token in prompt for token in ["背影", "过肩", "后脑勺", "后背"]):
        return "无脸背影或过肩控制帧"
    return "身份与方向控制帧"


def infer_control_frame_role(atom: dict[str, Any]) -> str:
    frame_type = infer_first_frame_type(atom)
    if "物件" in frame_type:
        return "action_trigger"
    if "地点" in frame_type:
        return "location_canon"
    if "背影" in frame_type:
        return "direction_lock"
    return "identity_direction_lock"


def default_generation_failure_modes(atom: dict[str, Any]) -> list[str]:
    risks = [
        "角色身份、校服、发型或配件漂移",
        "地点布局、运动方向或光线方向与前后镜头不连续",
        "动作节拍过多导致物理逻辑不可信",
    ]
    prompt = f"{atom.get('first_frame_prompt', '')} {atom.get('video_prompt', '')}"
    if any(token in prompt for token in ["相撞", "急刹", "摔", "碰撞"]):
        risks.append("硬接触动作过于直给，需用运动模糊、遮挡或余波反应带过")
    if any(token in prompt for token in ["说", "对白", "道歉", "喊"]):
        risks.append("模型可能生成字幕或口型文字，必须保持画面无字幕无文字")
    return risks


def default_frame_must_show(atom: dict[str, Any], strategy: dict[str, Any]) -> list[str]:
    items = []
    purpose = str(atom.get("purpose") or "").strip()
    if purpose:
        items.append(f"镜头目的：{purpose}")
    frame_type = str(strategy.get("first_frame_type") or "").strip()
    if frame_type:
        items.append(f"首帧类型：{frame_type}")
    assets = [str(name) for name in atom.get("reference_asset_names", []) if str(name).strip()]
    if assets:
        items.append(f"首帧可见资产：{'、'.join(assets)}")
    start_state = str(atom.get("continuity_state_start") or "").strip()
    start_state = inline_text(atom.get("continuity_state_start")).strip()
    if start_state:
        items.append(f"起始连续状态：{start_state}")
    return items or ["必须清楚呈现该镜头的空间、方向和动作初态。"]


def default_frame_must_not_show(atom: dict[str, Any], strategy: dict[str, Any]) -> list[str]:
    items = [
        "清晰可读文字、字幕、标题字、水印、logo、UI 或拼贴排版",
        "与 Consistency Bible 冲突的服装、地点布局、道具形态或光线方向",
        "reference_asset_names 之外的无关主要角色抢画面",
    ]
    for failure in strategy.get("failure_modes") or []:
        text = str(failure).strip()
        if text:
            items.append(f"避免生成风险：{text}")
    return items


def asset_prompt_line(asset: dict[str, Any]) -> str:
    name = str(asset.get("name", "")).strip()
    asset_type = str(asset.get("type", "asset")).strip()
    description = clip_text(str(asset.get("description", "")).strip(), 36)
    anchors = asset.get("generation_anchors") if isinstance(asset.get("generation_anchors"), dict) else {}
    positive = str(anchors.get("positive_prompt") or asset.get("visual_anchor_prompt") or "").strip()
    consistency = str(asset.get("consistency_notes") or asset.get("visual_identity") or "").strip()
    summary = clip_text(positive or consistency, 64)
    continuity = clip_text(consistency, 44)
    return f"{asset_type} {name}: {description}；{summary}；{continuity}"


def clip_text(value: str, limit: int) -> str:
    value = " ".join(value.split())
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 1)].rstrip() + "…"


def inline_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return str(value)


def video_prompt_with_style(prompt: str, style_context: str = "") -> str:
    # 文档里的 prompt 多以"。"结尾、CLEAN_FRAME_RULE 又以"。"开头，拼接前去重，
    # 并把历史文档里已存在的"。。"一并归一，避免双句号进入生成请求。
    prompt = f"{prompt.strip().rstrip('。')}{CLEAN_FRAME_RULE}"
    prompt = re.sub(r"。{2,}", "。", prompt)
    if not style_context:
        return prompt
    return f"已选风格档案，必须严格遵守：\n{style_context}\n\n视频提示词：\n{prompt}"


def style_options() -> list[dict[str, Any]]:
    return [
        {
            "id": "film",
            "label": "电影风格",
            "description": "更接近短片/电影语言，强调镜头调度、光影、空间关系和情绪递进。",
            "visual_rules": ["电影感光影", "自然真实的表演", "克制统一的色彩", "清晰的空间连续性"],
            "storyboard_rules": ["需要时使用环境建立镜头", "优先使用有动机的镜头运动", "通过镜头顺序递进情绪"],
            "prompt_rules": ["只在必要时写明镜头位置、焦段和运动", "避免过度解释成 UI 指令或说明书"],
            "avoid": ["短剧式夸张表演", "漫画格子感", "过度网感字幕化"],
        },
        {
            "id": "short_drama",
            "label": "短剧风格",
            "description": "节奏更快，人物表情和冲突更直接，适合移动端竖屏爽感叙事。",
            "visual_rules": ["移动端竖屏构图", "人物脸部清晰", "情绪点强", "画面信息易读"],
            "storyboard_rules": ["场景进入要快", "前几秒就让冲突可读", "多使用反应镜头"],
            "prompt_rules": ["明确人物情绪", "让动作和后果在画面上一眼可见"],
            "avoid": ["慢热电影铺垫过长", "含混的情绪表达", "过暗或难读的画面"],
        },
        {
            "id": "comic_drama",
            "label": "漫剧风格",
            "description": "漫画/轻动画式表达，强调清晰轮廓、戏剧姿态、夸张反应和分镜感。",
            "visual_rules": ["角色造型更风格化", "轮廓清晰", "姿态有表现力", "构图有漫画分格感"],
            "storyboard_rules": ["强调关键姿态之间的清晰转换", "让反应图形化且易读", "优先设计标志性动作状态"],
            "prompt_rules": ["清楚描述姿态、表情和视觉强调点", "保持服装和角色设计连续"],
            "avoid": ["写实电影灰暗质感", "过多细碎真实运动模糊", "角色设计漂移"],
        },
        {
            "id": "anime",
            "label": "动画番剧风格",
            "description": "接近动画番剧的镜头和角色表现，兼顾情绪、动作关键姿势和连续性。",
            "visual_rules": ["动画感光影", "角色一致性清晰", "眼神和姿态有表现力", "动态强但动作可读"],
            "storyboard_rules": ["使用清楚的关键姿势", "强调情绪节拍", "物理动作困难时用切镜辅助"],
            "prompt_rules": ["明确角色设计和服装一致性", "描述关键姿势和镜头角度"],
            "avoid": ["真人短剧质感", "过度照片写实", "随机换装"],
        },
        {
            "id": "documentary",
            "label": "纪实风格",
            "description": "自然、克制、像真实观察到的片段，减少表演感和夸张镜头。",
            "visual_rules": ["自然光", "观察式镜头", "真实可信的调度", "克制的色彩"],
            "storyboard_rules": ["优先使用可信的实时动作", "避免过度戏剧化调度", "让环境承担叙事信息"],
            "prompt_rules": ["道具、运动和身体力学都要落地可信"],
            "avoid": ["过度戏剧化", "漫画夸张", "不可信的物理动作"],
        },
    ]


def format_consistency_markdown(bible: dict[str, Any]) -> str:
    def kv(value: Any) -> str:
        if isinstance(value, dict):
            return "\n".join(f"- {k}：{v}" for k, v in value.items())
        return bullet_lines(value)
    return "\n".join([
        "# Consistency Bible（跨镜头共享元素，所有视觉阶段必须遵守，不得各自发明）",
        "",
        "## 统一校服",
        "",
        str(bible.get("uniform", "")).strip(),
        "",
        "## 固定着装（非校服）",
        "",
        kv(bible.get("fixed_outfits")),
        "",
        "## 配色与光影基调",
        "",
        str(bible.get("palette", "")).strip(),
        "",
        "## 地点布局（每个地点跨镜头不变）",
        "",
        kv(bible.get("location_layouts")),
        "",
        "## 复用道具统一外观",
        "",
        kv(bible.get("recurring_props")),
        "",
        "## 世界规则",
        "",
        bullet_lines(bible.get("world_rules")),
        "",
    ])


def format_scene_bible_markdown(bible: dict[str, Any]) -> str:
    lines = [
        "# Scene Bible（大场景制作包，后续分镜/原子镜头/关键帧必须继承）",
        "",
        "## 全局场景规则",
        "",
        bullet_lines(bible.get("global_scene_rules")),
        "",
    ]
    for scene in bible.get("scenes") or []:
        lines.extend(
            [
                f"## {scene.get('scene_id', '')}：{scene.get('name', scene.get('location', '未命名场景'))}",
                "",
                f"- 地点：{scene.get('location', '')}",
                f"- 场景编号：{scene.get('scene_nums', '')}",
                f"- 叙事功能：{scene.get('story_purpose', '')}",
                "",
                "### 时间/天气/光线",
                "",
                bullet_lines(scene.get("time_weather_light")),
                "",
                "### 空间地图",
                "",
                bullet_lines(scene.get("spatial_map")),
                "",
                "### 入口出口",
                "",
                bullet_lines(scene.get("entrances_exits")),
                "",
                "### 轴线与运动方向",
                "",
                bullet_lines(scene.get("screen_direction_rules")),
                "",
                "### 镜头覆盖计划",
                "",
                bullet_lines(scene.get("camera_coverage_plan")),
                "",
                "### 人群规则",
                "",
                bullet_lines(scene.get("crowd_rules")),
                "",
                "### 人物状态规则",
                "",
                bullet_lines(scene.get("character_state_rules")),
                "",
                "### 道具状态规则",
                "",
                bullet_lines(scene.get("prop_state_rules")),
                "",
                "### 物理规则",
                "",
                bullet_lines(scene.get("physics_rules")),
                "",
                "### 场景参考图计划",
                "",
                bullet_lines(scene.get("scene_reference_frames")),
                "",
                "### 连续性契约",
                "",
                bullet_lines(scene.get("continuity_contract")),
                "",
                "### Prompt 注入",
                "",
                str(scene.get("prompt_injection", "")).strip(),
                "",
            ]
        )
    return "\n".join(lines)


def format_cross_scene_continuity_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Cross Scene Continuity（跨大场景人物/道具/状态接力表）",
        "",
        "## 全局规则",
        "",
        bullet_lines(report.get("global_rules")),
        "",
        "## 跨场景实体",
        "",
    ]
    for entity in report.get("entities") or []:
        lines.extend(
            [
                f"### {entity.get('name', entity.get('entity_id', '未命名实体'))}",
                "",
                f"- 类型：{entity.get('type', '')}",
                f"- 不变身份：{entity.get('invariant_identity', '')}",
                "",
                "允许变化：",
                "",
                bullet_lines(entity.get("allowed_changes")),
                "",
                "禁止变化：",
                "",
                bullet_lines(entity.get("forbidden_changes")),
                "",
                "跨场景规则：",
                "",
                bullet_lines(entity.get("cross_scene_rules")),
                "",
            ]
        )
    lines.extend(["## 场景状态", ""])
    for state in report.get("scene_states") or []:
        lines.extend(
            [
                f"### {state.get('scene_id', '')}",
                "",
                f"- 场景编号：{state.get('scene_nums', '')}",
                "",
                "角色状态：",
                "",
                bullet_lines(state.get("characters")),
                "",
                "道具状态：",
                "",
                bullet_lines(state.get("props")),
                "",
                "承接上一场：",
                "",
                bullet_lines(state.get("carry_over_from_previous")),
                "",
                "传递给下一场：",
                "",
                bullet_lines(state.get("carry_over_to_next")),
                "",
                "Prompt 注入：",
                "",
                str(state.get("prompt_injection", "")).strip(),
                "",
            ]
        )
    lines.extend(["## 场景转接", ""])
    for transition in report.get("transitions") or []:
        lines.extend(
            [
                f"### {transition.get('from_scene_id', '')} -> {transition.get('to_scene_id', '')}",
                "",
                f"- 时间间隔：{transition.get('elapsed_time', '')}",
                "",
                "必须承接：",
                "",
                bullet_lines(transition.get("required_carryovers")),
                "",
                "允许变化：",
                "",
                bullet_lines(transition.get("permitted_changes")),
                "",
                "禁止跳变：",
                "",
                bullet_lines(transition.get("forbidden_jumps")),
                "",
                "检查项：",
                "",
                bullet_lines(transition.get("continuity_checks")),
                "",
                "Prompt 注入：",
                "",
                str(transition.get("prompt_injection", "")).strip(),
                "",
            ]
        )
    return "\n".join(lines)


def format_continuity_validation_markdown(report: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# Continuity Validation（连续性验证报告）",
            "",
            f"- 评分：{report.get('score')}",
            f"- 结论：{report.get('verdict')}",
            "",
            "## 阻塞问题",
            "",
            bullet_lines(report.get("blocking_issues")),
            "",
            "## 警告",
            "",
            bullet_lines(report.get("warnings")),
            "",
            "## 通过检查",
            "",
            bullet_lines(report.get("passed_checks")),
            "",
            "## 修改计划",
            "",
            bullet_lines(report.get("revision_plan")),
            "",
            "## 逐镜备注",
            "",
            bullet_lines(report.get("per_shot_notes")),
            "",
        ]
    )


def format_style_markdown(profile: dict[str, Any]) -> str:
    return "\n".join(
        [
            f"# Style Profile: {profile.get('label', profile.get('id', 'custom'))}",
            "",
            f"- id: {profile.get('id', 'custom')}",
            f"- description: {profile.get('description', '')}",
            "",
            "## 视觉规则",
            "",
            bullet_lines(profile.get("visual_rules")),
            "",
            "## 分镜规则",
            "",
            bullet_lines(profile.get("storyboard_rules")),
            "",
            "## Prompt 规则",
            "",
            bullet_lines(profile.get("prompt_rules")),
            "",
            "## 避免",
            "",
            bullet_lines(profile.get("avoid")),
            "",
            "## 用户补充",
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
    if isinstance(value, dict):
        return "\n".join(f"- {key}: {val}" for key, val in value.items())
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
        "document": "00_document.json",
        "document_ingest": "00_document.json",
        "style": "00_style.json",
        "style_select": "00_style.json",
        "consistency_bible": "00b_consistency.json",
        "scene_bible": "00c_scene_bible.json",
        "scene_reference_plan": "00d_scene_reference_plan.json",
        "scene_references": "00d_scene_references.json",
        "scene_reference_generate_ark": "00d_scene_references.json",
        "scene_reference_import": "00d_scene_references.json",
        "cross_scene_continuity": "00e_cross_scene_continuity.json",
        "cross_scene": "00e_cross_scene_continuity.json",
        "script": "01_script.json",
        "assets": "02_assets.json",
        "storyboards": "03_storyboards.json",
        "storyboard": "03_storyboards.json",
        "atomic_shots": "04_atomic_shots.json",
        "atomic": "04_atomic_shots.json",
        "continuity_validator": "04b_continuity_validation.json",
        "continuity_validation": "04b_continuity_validation.json",
        "keyframe_plan": "05_keyframe_plan.json",
        "keyframe_tasks": "05_keyframe_plan.json",
        "keyframes": "05_keyframes.json",
        "videos": "06_videos.json",
        "scene_transition_plan": "06b_scene_transition_plan.json",
        "scene_transitions": "06b_scene_transitions.json",
        "scene_transition_generate_ark": "06b_scene_transitions.json",
        "stage_rerun_advisor": "08_stage_rerun_advisor.json",
        "rerun_advisor": "08_stage_rerun_advisor.json",
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
