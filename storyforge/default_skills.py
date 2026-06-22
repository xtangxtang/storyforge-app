from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from .document import extract_document_text
from .services import downscaled_media_ref, media_ref
from .skills import SkillContext, SkillRegistry, SkillResult, write_review_markdown

# 对白/动作镜头恒加的整洁画面约束，避免 Seedance 烧录字幕、台词文字或水印 logo，并防串脸/换人/海报拼贴/塑料感。
CLEAN_FRAME_RULE = (
    "。画面整洁干净，不出现任何字幕、对白文字、标题字、台词、水印或 logo；不做海报拼贴或分格；"
    "保持人物身份与服装、书包颜色一致，不串脸、不换人、不凭空添加计划外人物；"
    "写实质感，避免塑料感CG与过度锐化油光。"
)


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
                "applies_to": ["director_style_select", "scene_bible", "scene_reference_plan", "cross_scene_continuity", "asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan", "keyframe_generate_ark", "video_generate_ark", "continuity_validator"],
                "rule": "除非用户修改风格，否则所有后续 prompt 都必须明确遵守该风格档案。",
            },
        }
        ctx.workspace.write_stage("00_style.json", out)
        ctx.workspace.wiki_dir.joinpath("style.md").write_text(format_style_markdown(profile), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00_style_select.md", "风格选择审阅", out)
        ctx.workspace.append_log("风格已选择", {"style": profile.get("id"), "label": profile.get("label")})
        return SkillResult(True, "风格已选择", {"file": "stages/00_style.json", "style": profile.get("id")})


class DirectorStyleSelectSkill:
    id = "director_style_select"
    description = "选择并持久化导演语言/流派风格，例如日系治愈、青春校园写实或运动热血写实，供后续视觉阶段和导演审查引用。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script:
            return SkillResult(False, "未找到 stages/01_script.json 中的剧本结构化结果", {})

        selected = str(input_data.get("director_style") or input_data.get("director_style_id") or "").strip()
        custom_note = str(input_data.get("director_style_note") or input_data.get("custom_director_style") or "").strip()
        existing = ctx.workspace.read_stage("00a_director_style.json")
        if not selected and existing.get("status") == "selected" and not input_data.get("force_prompt"):
            language = existing.get("director_language") or {}
            return SkillResult(True, "导演语言已选择", {"file": "stages/00a_director_style.json", "director_style": language.get("id")})

        options = director_style_options()
        options_by_id = {option["id"]: option for option in options}
        if not selected:
            out = {
                "source": self.id,
                "status": "awaiting_selection",
                "prompt": "请选择本片的导演语言/流派风格。它会叠加在电影/短剧/漫剧等生产风格之上，影响场景制作包、分镜、原子镜头、关键帧 prompt、视频 prompt 和导演审查。",
                "options": options,
                "how_to_continue": "请用一个 director_style id 继续，例如：{\"director_style\":\"japanese_healing\"}。",
            }
            ctx.workspace.write_stage("00a_director_style.json", out)
            write_review_markdown(ctx.workspace.review_dir / "00a_director_style_select.md", "导演语言选择提示", out)
            return SkillResult(True, "等待用户选择导演语言", {"file": "stages/00a_director_style.json", "awaiting_user_selection": True})

        profile = options_by_id.get(selected)
        if profile is None:
            profile = {
                "id": "custom",
                "label": selected,
                "description": custom_note or selected,
                "visual_rules": [custom_note or selected],
                "camera_rules": ["所有镜头调度都要明确服务该导演语言，而不是只贴风格词。"],
                "performance_rules": ["表演强度、停顿和反应节奏要与该导演语言一致。"],
                "editing_rules": ["剪辑节奏要与该导演语言一致，避免混入不相容的平台化节奏。"],
                "prompt_rules": ["后续 prompt 必须把该导演语言翻译成可拍摄的光线、机位、调度和表演要求。"],
                "avoid": ["不要只写导演名字或流派标签而没有可执行镜头方案。"],
            }
        if custom_note:
            profile = {**profile, "user_note": custom_note}

        out = {
            "source": self.id,
            "status": "selected",
            "director_language": profile,
            "prompt_contract": {
                "applies_to": [
                    "scene_bible",
                    "scene_reference_plan",
                    "asset_design",
                    "storyboard_plan",
                    "atomic_shot_plan",
                    "keyframe_plan",
                    "keyframe_generate_ark",
                    "video_generate_ark",
                    "scene_transition_plan",
                    "director_guard_agent",
                ],
                "rule": "除非用户修改导演语言，否则后续所有视觉 prompt 和导演审查都必须读取并遵守该导演语言档案。",
            },
        }
        ctx.workspace.write_stage("00a_director_style.json", out)
        ctx.workspace.wiki_dir.joinpath("director_style.md").write_text(format_director_style_markdown(profile), encoding="utf-8")
        write_review_markdown(ctx.workspace.review_dir / "00a_director_style_select.md", "导演语言选择审阅", out)
        ctx.workspace.append_log("导演语言已选择", {"director_style": profile.get("id"), "label": profile.get("label")})
        return SkillResult(True, "导演语言已选择", {"file": "stages/00a_director_style.json", "director_style": profile.get("id")})


class ConsistencyBibleSkill:
    id = "consistency_bible"
    description = "在视觉设计前先抽取并锁定跨镜头共享元素（统一校服、配色、地点布局、复用道具、世界规则），供后续所有阶段引用以保持统一。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script.get("assets") and not script.get("scenes"):
            return SkillResult(False, "未找到 stages/01_script.json 中的剧本结构化结果", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 consistency_bible。在所有视觉设计之前，先从剧本里抽取并锁定【跨镜头必须统一】的共享元素，输出严格 JSON："
            "{uniform, fixed_outfits, character_identity_locks, palette, location_layouts, recurring_props, world_rules}。"
            "uniform=全片统一校服的精确描述（颜色与拼色、领口、版型、下装、鞋）；"
            "fixed_outfits={角色原名: 非校服时的固定着装}；"
            "character_identity_locks={角色原名: {可识别配色, 书包颜色与款式, 球拍/随身物的颜色与归属, 发型, 眼镜/配饰, 性别化着装差异, 体型}}——这是防串脸串衣最关键的归属锁：凡剧本中复用的随身物必须锁定唯一颜色并绑定到具体角色，后续不得改色或换主；"
            "palette=全片统一配色与光影基调；"
            "location_layouts={地点原名: 该地点结构与陈设的不变描述，写清黑板/窗/门/课桌排列/招牌等的方位与楼层高度，使该地点在每个镜头都一致}；"
            "recurring_props={复用道具原名: {外观, 默认持有人, 颜色}}——复用道具必须写清唯一外观、默认持有人和颜色；"
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
            "time_weather_light 写清时间、天气，并用【可执行的物理量】描述光线：主光方向用屏幕/钟面方位（如'主光来自画面左上约10点钟方向'）、阴影落向、色温给出开尔文区间（如约5200K）、是否允许镜头间变化——不要只写'温暖的光'这类形容词；"
            "spatial_map 写清场地平面关系、前后左右、入口出口、楼层高度、道路/墙/门/桌椅/球台等固定位置；"
            "screen_direction_rules 用相机相对方位（camera-left/right）固定 180 度轴线，写清人物进入/离开/运动方向、哪一侧是'朝目标/进'方向、禁止反向跨轴的动作；"
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
                "shared_asset_rule": "每个大场景必须先生成 location_master_plate；同一 scene_id 下的角色背影、道具摆放、机位、碰撞点和后续状态参考图必须继承该 master plate 的校门/教室/球馆等共同资产、空间结构、光线方向和轴线，不得各自重新发明场地。",
                "scene_asset_pack_rule": "进入某个大场景的正式分镜、关键帧或图生视频前，必须先为该 scene_id 生成并审阅一整套共同资产包：location_master_plate、必要角色背影 canon、prop_placement_plate、主要 camera_angle_plate，以及该场景需要的动作/状态参考图。",
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
        selected = sort_scene_reference_tasks(selected)
        selected = selected[start_index:]
        if limit:
            selected = selected[:limit]

        canon_index = load_asset_canon_index(ctx)
        scene_by_id = {
            str(scene.get("scene_id")): scene
            for scene in ctx.workspace.read_stage("00c_scene_bible.json").get("scenes", []) or []
            if scene.get("scene_id")
        }
        # 默认缺底图即报错；只有显式 allow_missing_canon 才允许退回纯文字生成。
        require_canon = not bool(input_data.get("allow_missing_canon"))
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
            # 必须继承的底图：显式 canon_refs（角色校服等）+ 该场景的项目级地点 canon（大门等）+ 场景内 master plate。
            scene = scene_by_id.get(str(task.get("scene_id"))) or {}
            declared_canon = [str(c) for c in (task.get("canon_refs") or [])]
            auto_canon = [c for c in location_canon_ids_for_scene(scene, canon_index) if c not in declared_canon]
            canon_used, canon_missing = resolve_canon_reference_media(ctx, declared_canon + auto_canon, canon_index)
            dep_used, dep_missing = resolve_dependency_reference_media(ctx, task, existing)
            blocking_missing: list[str] = []
            if require_canon:
                blocking_missing += [c for c in canon_missing if c in declared_canon]
                if canon_index:
                    blocking_missing += [c for c in canon_missing if c in auto_canon]
                blocking_missing += dep_missing
            if blocking_missing:
                failed += 1
                existing[ref_id] = {**current, **task, "local_path": str(local_path), "image_provider": "ark", "state": "failed", "error": f"缺少必须继承的底图，已拒绝纯文字生成：{sorted(set(blocking_missing))}（先生成对应 canon / master plate，或显式传 allow_missing_canon）"}
                continue
            try:
                # 参考图按重要度排序并限量（payload 太大/太多会拖慢甚至超时）：地点canon→master→角色→道具。
                ref_pairs = sorted(canon_used + dep_used, key=lambda p: scene_ref_priority(p[0]))[:5]
                media_refs = [media for _id, media in ref_pairs]
                url = ctx.ark.generate_image(
                    ark_image_prompt(str(task.get("prompt") or ""), must_show=task.get("must_show"), must_not_show=task.get("must_not_show")),
                    refs=media_refs or None,
                    suffix=ark_image_constraints(has_refs=bool(media_refs)),
                )
                ctx.ark.download(url, local_path)
                generated += 1
                existing[ref_id] = {**task, "reference_url": url, "local_path": str(local_path), "image_provider": "ark", "state": "ready", "reference_image_inputs": [rid for rid, _m in ref_pairs]}
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


class AssetCanonPlanSkill:
    id = "asset_canon_plan"
    description = "把 asset_design 与 Consistency Bible 编译成项目级共用 canon 基准图任务（大门、校服/角色、复用道具的唯一外观锚点）。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        assets = list(ctx.workspace.read_stage("02_assets.json").get("assets") or [])
        if not assets:
            return SkillResult(False, "未找到 stages/02_assets.json，请先运行 asset_design", {})
        consistency = ctx.workspace.read_stage("00b_consistency.json")
        style_context = load_style_context(ctx)
        tasks = asset_canon_tasks(assets, consistency, style_context)
        if not tasks:
            return SkillResult(False, "asset_design 中没有可建立 canon 的 character/location/prop 资产", {})
        out = {
            "source": self.id,
            "image_provider": "codex",
            "prompt_contract": {
                "consistency_reference": "wiki/consistency.md",
                "asset_reference": "stages/02_assets.json",
                "output_dir": "assets/canon",
                "rule": "canon 是项目级唯一外观锚点，不是分镜，不是场景参考图。每个复用角色/地点/道具只生成并锁定一张 canon。",
                "downstream_rule": "scene_reference 的 location_master_plate 必须继承对应地点 canon；角色背影/定妆参考必须继承角色 canon；道具摆放参考必须继承道具 canon。后续 keyframe 与 video 同样继承，不得各自重新发明大门/校服/道具。",
            },
            "asset_canon_tasks": tasks,
        }
        ctx.workspace.write_stage("00f_asset_canon_plan.json", out)
        write_review_markdown(ctx.workspace.review_dir / "00f_asset_canon_plan.md", "共用 canon 基准图任务审阅", out)
        ctx.workspace.append_log("共用 canon 基准图任务已规划", {"tasks": len(tasks)})
        return SkillResult(True, "共用 canon 基准图任务已规划", {"file": "stages/00f_asset_canon_plan.json", "count": len(tasks)})


class AssetCanonGenerateArkSkill:
    id = "asset_canon_generate_ark"
    description = "通过 Ark 生成项目级共用 canon 基准图（大门、校服/角色、复用道具），作为全片唯一外观锚点。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        plan = ctx.workspace.read_stage("00f_asset_canon_plan.json")
        tasks = list(plan.get("asset_canon_tasks") or [])
        if not tasks:
            assets = list(ctx.workspace.read_stage("02_assets.json").get("assets") or [])
            consistency = ctx.workspace.read_stage("00b_consistency.json")
            tasks = asset_canon_tasks(assets, consistency, load_style_context(ctx))
        if not tasks:
            return SkillResult(False, "没有找到 canon 任务，请先运行 asset_canon_plan", {})
        only_ids = normalize_id_filter(input_data.get("canon_ids") or input_data.get("ids"))
        only_types = {str(t).strip() for t in (input_data.get("asset_types") or []) if str(t).strip()}
        start_index = max(0, int(input_data.get("start_index") or 0))
        limit = max(0, int(input_data.get("limit") or input_data.get("max_items") or 0))
        overwrite = bool(input_data.get("overwrite"))
        selected = [
            task for task in tasks
            if (not only_ids or str(task.get("canon_id")) in only_ids)
            and (not only_types or str(task.get("asset_type")) in only_types)
        ]
        selected = selected[start_index:]
        if limit:
            selected = selected[:limit]

        existing = {
            str(item.get("canon_id")): item
            for item in ctx.workspace.read_stage("00f_asset_canon.json").get("asset_canon", [])
            if item.get("canon_id")
        }
        generated = 0
        skipped = 0
        failed = 0
        for task in selected:
            canon_id = str(task.get("canon_id"))
            local_path = resolve_workspace_path(ctx, task.get("local_path")) or ctx.workspace.canon_dir / f"{safe_name(canon_id)}.png"
            current = dict(existing.get(canon_id) or {})
            if local_path.exists() and not overwrite:
                skipped += 1
                existing[canon_id] = {**current, **task, "local_path": str(local_path), "image_provider": "ark", "state": "ready"}
                continue
            try:
                url = ctx.ark.generate_image(ark_image_prompt(str(task.get("prompt") or ""), must_show=task.get("must_show"), must_not_show=task.get("must_not_show")), suffix=ark_image_constraints())
                ctx.ark.download(url, local_path)
                generated += 1
                existing[canon_id] = {**task, "reference_url": url, "local_path": str(local_path), "image_provider": "ark", "state": "ready"}
            except Exception as exc:
                failed += 1
                existing[canon_id] = {**current, **task, "local_path": str(local_path), "image_provider": "ark", "state": "failed", "error": str(exc)}
        canon = [existing[str(task.get("canon_id"))] for task in tasks if str(task.get("canon_id")) in existing]
        out = {
            "source": self.id,
            "image_provider": "ark",
            "asset_canon": canon,
            "success": sum(item.get("state") == "ready" for item in canon),
            "failed": sum(item.get("state") == "failed" for item in canon),
            "total_planned": len(tasks),
        }
        ctx.workspace.write_stage("00f_asset_canon.json", out)
        write_review_markdown(ctx.workspace.review_dir / "00f_asset_canon.md", "共用 canon 基准图生成审阅", out)
        ok = generated > 0 or skipped > 0
        return SkillResult(ok, "共用 canon 基准图生成流程已完成" if ok else "共用 canon 基准图生成失败", {"file": "stages/00f_asset_canon.json", "generated": generated, "skipped": skipped, "failed": failed, "success": out["success"], "total_planned": len(tasks)})


class VisualConsistencyReviewSkill:
    id = "visual_consistency_review"
    description = "看图复核：用视觉 LLM 对比新生成图与项目级 canon 底图，抓大门/校服/书包颜色/人物身份的视觉漂移（守门 agent 看不到图的缺口补丁）。"

    TARGETS = {
        "scene_references": ("00d_scene_references.json", "scene_references", "reference_id"),
        "asset_canon": ("00f_asset_canon.json", "asset_canon", "canon_id"),
        "keyframes": ("05_keyframes.json", "keyframes", "atomic_shot_id"),
    }

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        target = str(input_data.get("target") or "scene_references")
        if target not in self.TARGETS:
            return SkillResult(False, f"未知 target：{target}（可选 {list(self.TARGETS)}）", {})
        stage_file, list_key, id_key = self.TARGETS[target]
        items = list(ctx.workspace.read_stage(stage_file).get(list_key) or [])
        if not items:
            return SkillResult(False, f"未找到 {stage_file} 中的 {list_key}", {})
        only_ids = normalize_id_filter(input_data.get("ids") or input_data.get("reference_ids"))
        canon_index = load_asset_canon_index(ctx)
        consistency = ctx.workspace.read_stage("00b_consistency.json")
        uniform = inline_text(consistency.get("uniform"))

        reviews: list[dict[str, Any]] = []
        checked = mismatched = unavailable = 0
        for item in items:
            item_id = str(item.get(id_key) or item.get("reference_id") or item.get("canon_id") or "")
            if only_ids and item_id not in only_ids:
                continue
            img = resolve_workspace_path(ctx, item.get("local_path") or item.get("first_frame_local_path"))
            if not img or not img.exists():
                continue
            # 收集该图应继承的 canon 底图（reference_image_inputs 里以 canon_ 开头的项 + 自动地点 canon）。
            ref_ids = [r for r in (item.get("reference_image_inputs") or []) if str(r).startswith("canon_")]
            ref_paths: list[str] = []
            for rid in ref_ids:
                c = canon_index.get(str(rid))
                p = resolve_workspace_path(ctx, c.get("local_path")) if c else None
                if p and p.exists():
                    ref_paths.append(str(p))
            checked += 1
            try:
                verdict = ctx.llm.chat_vision_json(
                    "你是电影监制的连续性场记，正在看图复核。第一张是【新生成图】，其余是【项目级 canon 基准图】(全片唯一外观锚点)。"
                    "判断新生成图是否严格继承了 canon 的外观：大门/地点结构是否同一座、校服款式与配色是否一致、书包颜色与归属是否正确、人物身份是否未串脸换人。"
                    "输出严格 JSON：{consistent: true/false, mismatches:[...], notes:''}。mismatches 列出具体不一致点（如'大门造型与canon不同''书包颜色由深灰变蓝'）。",
                    f"资产/镜头ID：{item_id}。统一校服规范：{clip_text(uniform, 200)}。"
                    f"请对比第一张新生成图与后续 canon 基准图，列出所有视觉不一致。",
                    [str(img)] + ref_paths,
                    tag=f"visual_review_{item_id}",
                )
                consistent = bool(verdict.get("consistent"))
                if not consistent:
                    mismatched += 1
                reviews.append({"id": item_id, "image": str(img), "canon_refs": ref_ids, "consistent": consistent, "mismatches": verdict.get("mismatches") or [], "notes": verdict.get("notes") or ""})
            except Exception as exc:  # noqa: BLE001 - 视觉模型不可用时优雅降级，不阻断流程。
                unavailable += 1
                reviews.append({"id": item_id, "image": str(img), "canon_refs": ref_ids, "consistent": None, "error": str(exc)[:200], "notes": "视觉复核不可用，需人工看图。"})

        if unavailable and unavailable == checked:
            verdict = "needs_human"
        elif mismatched:
            verdict = "revise"
        else:
            verdict = "approve"
        out = {
            "source": self.id,
            "target": target,
            "verdict": verdict,
            "checked": checked,
            "mismatched": mismatched,
            "vision_unavailable": unavailable,
            "reviews": reviews,
        }
        ctx.workspace.write_stage("00g_visual_consistency.json", out)
        write_review_markdown(ctx.workspace.review_dir / f"visual_consistency_{target}.md", "视觉一致性看图复核", out)
        ok = checked > 0
        return SkillResult(ok, f"看图复核完成：{checked} 张，{mismatched} 张不一致，{unavailable} 张未复核", {"file": "stages/00g_visual_consistency.json", "verdict": verdict, "checked": checked, "mismatched": mismatched, "vision_unavailable": unavailable})


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
        if assets and (input_data.get("deterministic_assets") or input_data.get("local_fallback_only")):
            designed = [
                normalize_asset_design(asset, idx)
                for idx, asset in enumerate(deterministic_asset_designs(ctx, assets), 1)
            ]
            out = {
                "source": self.id,
                "generation_mode": "deterministic_assets",
                "generation_note": "使用本地确定性资产锚点生成，避免长上下文 LLM 请求阻塞流程。",
                "assets": designed,
            }
            ctx.workspace.write_stage("02_assets.json", out)
            write_review_markdown(ctx.workspace.review_dir / "02_assets.md", "视觉资产设计审阅", out)
            return SkillResult(
                True,
                "视觉资产提示词已设计",
                {"file": "stages/02_assets.json", "count": len(designed), "generation_mode": "deterministic_assets"},
            )
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
            "同时遵守 Style Profile。所有字段值和说明必须使用简体中文。"
            "【硬规则】Workspace context 里的 JSON 只是给你理解约束用的，任何输出字段都必须是给图像模型看的自然语言画面描述："
            "严禁出现花括号、方括号、引号包裹的键名，严禁把 id/entity_id/scene_id/type/label/visual_rules 等键名或整段 JSON/字典原样抄进 visual_anchor_prompt、visual_identity、generation_anchors 等任何字段。",
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
            "必须保留原故事。dramatic_intent 写清这个镜头在情绪/信息/冲突上的功能；"
            "camera_design 必须写清 shot_size（远景/全景/中景/中近景/近景/特写 之一）、焦段感（广角/标准/中长焦/长焦）、机位高度（低/平/高）、景深（浅/中/深）和运动动机——不要只写形容词；"
            "blocking 写人物与道具在空间里的调度关系；screen_direction 写入画方向、视线方向、运动方向和前后镜头怎样接；"
            "edit_value 写这个镜头切出去时观众获得的新信息或情绪；continuity_risks 写可能漂移/穿帮/物理不可信的点。"
            "coverage_role 必须从 建立镜头/主动作镜头/插入特写/反应镜头/过肩关系镜头/转场镜头 中选择最合适的一类；"
            "一场戏的景别要有节奏对比（建立镜+主动作+反应/特写），不要整场都是中远景或全是背影方向镜；背影/过肩只是 i2v 首帧的过审手段，不应牺牲必要的近景反应与特写情绪镜。"
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
            "shot_design, generation_strategy, first_frame_prompt, video_prompt, continuity_state_start, continuity_state_end, reference_asset_names, late_appearance_anchors。"
            "late_appearance_anchors=该镜中段才出场、不在首帧、又无参考图可锁的人物的结构化身份锚点列表 [{name, outfit_colorway, bag_color, hair, accessories, build}]；没有这类人物时填空数组——它必须和 video_prompt 文字里的描述一致，是防串脸串衣的强制项。"
            "shot_design 包含 camera, movement, blocking, performance, edit_intent，用影视语言写清这个镜头怎么拍、为什么这么拍。"
            "generation_strategy 包含 render_mode, first_frame_type, control_frame_role, reference_assets, failure_modes, moderation_notes，用生成语言写清如何稳定产出。"
            "continuity_state_start 和 continuity_state_end 优先写成结构化 JSON object，包含 characters/camera/lighting/props/location/physics/summary；不要只写一句泛泛描述。"
            "每个镜头必须从 Scene Bible 继承 location、光线方向、轴线、人物位置、道具状态和物理规则，并从 Cross Scene Continuity 继承跨大场景的服装、携带物、道具归属、身体/情绪状态；如果剧情需要突破规则，必须在 continuity_state_end 中说明原因。"
            "【拆分】动作连续、中间没有断点的相邻动作合并成一条连续镜（如骑行→相撞→道歉合一条），不要拆成多条再硬切；只在换时间/地点/全新机位、或单条超10秒时才另起一镜。不要过度原子化。"
            "【时长】单条 5-10 秒（下限5上限10），一条连续微场景可用 8-10 秒。video_prompt 的动作节拍数必须与 duration 匹配（约每拍2-2.5秒，5秒镜不超过2-3个主动作节拍，硬接触镜只保留1个核心动作+余波）：节拍装不下就加时长或拆镜，节拍太少则补环境/反应细节。动作塞太多会导致瞬移/穿模/速度突变。"
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
            "1. 是否违反 Scene Bible 的地点结构、入口出口、轴线、运动方向、光线方向、人群规则；逐对相邻镜检查 180 度轴线：角色屏幕朝向（camera-left/right）是否跨轴跳变而未交代，per_shot_notes 用 screen_direction_axis(left/right/neutral) 标注每镜并标出跨轴问题；"
            "1b. 景别/机位是否单调：是否连续多镜同一景别、或全是背影方向镜而缺少必要的反应近景与特写；"
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
        scene_pack_status = scene_asset_pack_statuses(ctx, scene_reference_context)
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
                "scene_asset_pack_id": f"{atom.get('scene_id')}_scene_asset_pack" if atom.get("scene_id") else "",
                "scene_asset_pack_status": scene_pack_status.get(str(atom.get("scene_id") or ""), {}),
                "duration": atom.get("duration", 5),
                "video_prompt": atom.get("video_prompt", ""),
                "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context, continuity_state=atom.get("continuity_state_start")),
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
                task["last_frame_prompt"] = frame_prompt(raw_last, named_assets, style_context, continuity_state=atom.get("continuity_state_end"))
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
                "scene_asset_pack_required": "进入某个大场景的正式关键帧生成前，必须先为该 scene_id 生成并审阅共同资产包：location_master_plate、必要角色背影 canon、prop_placement_plate、主要 camera_angle_plate，以及该场景需要的动作/状态参考图。关键帧任务只能引用已确认的共同资产包，不得重新发明场地。",
                "rule": "每条首帧 prompt 只保留镜头画面、核心动作、物理/方向/光影约束；完整风格、场景制作包、连续性验证和资产锚点由全局引用提供。",
            },
            "scene_asset_pack_status": scene_pack_status,
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
        scene_reference_context = load_scene_reference_context(ctx)
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
                first_url = ctx.ark.generate_image(ark_image_prompt(str(task.get("first_frame_prompt", "")), must_show=task.get("frame_must_show"), must_not_show=task.get("frame_must_not_show")), refs=refs, suffix=ark_image_constraints(has_refs=bool(refs), lock_direction=True))
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
            "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context, continuity_state=atom.get("continuity_state_start")),
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
            task["last_frame_prompt"] = frame_prompt(raw_last, named_assets, style_context, continuity_state=atom.get("continuity_state_end"))
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
    canon_index = load_asset_canon_index(ctx)  # 优先复用项目级 canon，避免重复出图/漂移
    anchors: dict[str, str] = {}
    changed = False
    for asset in assets:
        name = str(asset.get("name") or "").strip()
        if not name:
            continue
        if only_names is not None and name not in only_names:
            continue
        # 1) 项目级 canon 优先（陈/俞/自行车/书包/大门等已有 canon 的资产直接复用，零额外配额、与 canon 一致）。
        canon = canon_index.get(canon_id_for_asset(asset))
        canon_local = resolve_workspace_path(ctx, canon.get("local_path")) if canon else None
        if canon and str(canon.get("state")) == "ready" and canon_local and canon_local.exists():
            anchors[name] = downscaled_media_ref(str(canon_local))
            continue
        local = str(asset.get("reference_image_local_path") or "")
        if local and Path(local).exists():
            anchors[name] = downscaled_media_ref(local)
            continue
        fallback = ctx.workspace.assets_dir / f"{safe_name(name)}.png"
        if fallback.exists():
            asset["reference_image_local_path"] = str(fallback)
            anchors[name] = downscaled_media_ref(str(fallback))
            changed = True
            continue
        if asset.get("reference_image_url"):
            anchors[name] = str(asset["reference_image_url"])
            continue
        url = ctx.ark.generate_image(anchor_prompt(asset, style_context, uniform=uniform, layout=str(layouts.get(name) or "")), suffix=ark_image_constraints())
        path = ctx.ark.download(url, ctx.workspace.assets_dir / f"{safe_name(name)}.png")
        asset["reference_image_url"] = url
        asset["reference_image_local_path"] = str(path)
        anchors[name] = downscaled_media_ref(str(path))
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


def ark_image_prompt(
    prompt: str,
    must_show: list[str] | None = None,
    must_not_show: list[str] | None = None,
) -> str:
    """只产【中文创作部分】（含 must_show/must_not_show），用于送翻译。
    英文硬约束改由 ark_image_constraints() 在翻译后追加，避免把英文再翻译一遍拖慢。"""
    cn_parts = [prompt]
    if must_show:
        shown = "；".join(str(x).strip() for x in must_show if str(x).strip())
        if shown:
            cn_parts.append("画面必须清楚出现：" + shown)
    if must_not_show:
        hidden = "；".join(str(x).strip() for x in must_not_show if str(x).strip())
        if hidden:
            cn_parts.append("画面绝不出现：" + hidden)
    return "\n".join(p for p in cn_parts if p and p.strip())


def ark_image_constraints(has_refs: bool = False, lock_direction: bool = False) -> str:
    """Ark 文生图英文硬约束，翻译后直接追加（不再被翻译）。
    has_refs 时强制"严格保持参考图身份/校服/大门外观"；
    lock_direction 仅用于关键帧控制帧（建立镜/canon/场景总览不应被强制背影）。"""
    constraints = [
        "Ark text-to-image hard constraints: vertical 9:16 cinematic realistic control frame.",
        "Do not render readable Chinese or English text anywhere; signs, plaques, labels, uniforms, papers, and posters must be blank, shadowed, cropped, or too defocused to read.",
        "No watermark, no logo, no subtitles, no captions, no UI, no poster layout, no collage.",
        "Only include the specified characters/elements; do not add extra or unplanned people or props.",
        "Photographic realism: keep natural skin and material texture; avoid plastic over-smooth CG look and over-sharpening.",
    ]
    if has_refs:
        constraints.insert(
            1,
            "Strictly preserve the exact facial identity, hairstyle, body type, uniform colors and cut, bag color, and location/architecture appearance shown in the attached reference image(s); treat them as the canonical look — do not redesign, recolor, or swap identities.",
        )
    if lock_direction:
        constraints.append(
            "Lock motion direction with camera-relative framing: for action or direction shots use a back or over-the-shoulder view with the destination in the deep background; for dialogue use over-the-shoulder framing and avoid two large frontal faces.",
        )
    return "\n".join(constraints)


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
                        new_first_url = ctx.ark.generate_image(ark_image_prompt(faceless_prompt, must_show=kf.get("frame_must_show"), must_not_show=kf.get("frame_must_not_show")), refs=refs or None, suffix=ark_image_constraints(has_refs=bool(refs), lock_direction=True))
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


class ReviewDecisionSkill:
    id = "review_decision"
    description = "记录用户对某个 stage 的 approve/revise/block 决策，并提示后续重跑或复查。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        skill_id = str(input_data.get("skill_id") or input_data.get("stage_skill") or "").strip()
        decision = str(input_data.get("decision") or "").strip().lower()
        if decision not in {"approve", "revise", "changes_requested", "block", "reject"}:
            return SkillResult(False, "decision 必须是 approve、revise、changes_requested、block 或 reject", {})
        changed_stage = normalize_stage_name(str(input_data.get("changed_stage") or input_data.get("stage") or stage_for_skill(skill_id) or "")).strip()
        scene_id = str(input_data.get("scene_id") or "").strip()
        item_id = str(input_data.get("item_id") or "").strip()
        note = str(input_data.get("note") or input_data.get("comment") or "").strip()
        requested_changes = input_data.get("requested_changes") or []
        if isinstance(requested_changes, str):
            requested_changes = [requested_changes]
        graph = stage_dependency_graph()
        impacted = impacted_downstream_stages(changed_stage, graph) if changed_stage else []
        stale = stale_stage_reports(ctx, graph)
        recommendations = rerun_recommendations(changed_stage, impacted, stale, scene_id) if decision != "approve" else []
        record = ctx.workspace.append_decision(
            {
                "skill_id": skill_id,
                "decision": decision,
                "changed_stage": changed_stage,
                "scene_id": scene_id,
                "item_id": item_id,
                "note": note,
                "requested_changes": requested_changes,
                "rerun_recommendations": recommendations,
            }
        )
        out = {
            "source": self.id,
            "decision": record,
            "decisions_file": "review/decisions.json",
            "decisions_markdown": "wiki/decisions.md",
            "rerun_recommendations": recommendations,
        }
        ctx.workspace.write_stage("09_review_decision.json", out)
        write_review_markdown(ctx.workspace.review_dir / "09_review_decision.md", "用户审阅决策记录", out)
        ctx.workspace.refresh_review_index()
        message = "用户审阅决策已记录"
        return SkillResult(True, message, {"file": "stages/09_review_decision.json", "decision_id": record.get("id"), "decision": decision, "rerun_count": len(recommendations)})


class ChangePropagatorSkill:
    id = "change_propagator"
    description = "根据用户对剧本、人物、场景、分镜或关键帧的修改请求，分析影响范围，必要时同步改写相关 stage，并输出改动报告。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        change_request = str(input_data.get("change_request") or input_data.get("request") or input_data.get("note") or "").strip()
        if not change_request:
            return SkillResult(False, "缺少 change_request", {})

        apply_changes = bool(input_data.get("apply") or input_data.get("apply_changes"))
        changed_stage = normalize_stage_name(str(input_data.get("changed_stage") or input_data.get("stage") or ""))
        changed_file = str(input_data.get("changed_file") or input_data.get("file") or "").strip()
        if not changed_stage and changed_file:
            changed_stage = stage_name_from_path(changed_file)
        scene_id = str(input_data.get("scene_id") or "").strip()
        item_id = str(input_data.get("item_id") or "").strip()
        explicit_stages = normalize_stage_list(input_data.get("target_stages") or input_data.get("stages") or [])

        graph = stage_dependency_graph()
        impacted = impacted_downstream_stages(changed_stage, graph) if changed_stage else []
        upstream = upstream_dependency_stages(changed_stage, graph) if changed_stage else []
        stale = stale_stage_reports(ctx, graph)
        recommendations = rerun_recommendations(changed_stage, impacted, stale, scene_id) if changed_stage else rerun_recommendations("", [], stale, scene_id)
        candidate_stages = change_candidate_stages(ctx, changed_stage, impacted, explicit_stages)
        context_stages = unique_stage_order([*upstream, changed_stage, *candidate_stages, *explicit_stages])

        try:
            proposal = ctx.llm.chat_json(
                "你是 Storyforge 的 change_propagator。你的任务不是重新创作整部片，而是根据用户的局部修改请求，"
                "对项目中前后相关的机器可读 stage 做最小同步修订，并清楚报告你改了什么。"
                "输出严格 JSON，字段包括 summary, mode, impacted_stages, update_plan, stage_updates, skipped_stages, user_review_focus, rerun_recommendations。"
                "stage_updates 是数组，每项必须包含 stage, action(update|review_only|skip), reason, changes, updated_stage。"
                "updated_stage 必须是完整 JSON object；只能在确实需要改写且有足够上下文时给出。"
                "保持原 schema、id、scene_id、storyboard_id、atomic_shot_id、文件引用和媒体路径；不要删除未受影响的条目。"
                "不要改写 05_keyframes.json、06_videos.json、00d_scene_references.json、06b_scene_transitions.json 这类媒体结果 stage，只能把它们列为需要重跑或复查。"
                "所有创作内容和报告文字都使用简体中文。",
                change_propagator_prompt(
                    ctx,
                    change_request=change_request,
                    changed_stage=changed_stage,
                    changed_file=changed_file,
                    scene_id=scene_id,
                    item_id=item_id,
                    apply_changes=apply_changes,
                    context_stages=context_stages,
                    candidate_stages=candidate_stages,
                    recommendations=recommendations,
                ),
                temperature=float(input_data.get("temperature", 0.1)),
                tag=self.id,
            )
            mode = "apply" if apply_changes else "plan"
            llm_error = ""
        except Exception as exc:  # noqa: BLE001 - fallback still gives the user a usable impact report.
            proposal = local_change_propagation_plan(
                change_request=change_request,
                changed_stage=changed_stage,
                changed_file=changed_file,
                scene_id=scene_id,
                item_id=item_id,
                candidate_stages=candidate_stages,
                recommendations=recommendations,
                error=str(exc),
            )
            mode = "fallback_plan"
            llm_error = str(exc)
            apply_changes = False

        applied = []
        skipped = []
        if apply_changes:
            applied, skipped = apply_stage_updates(ctx, proposal.get("stage_updates") or [])
        else:
            skipped = [{"stage": stage, "reason": "plan mode; no files were modified"} for stage in candidate_stages]

        report = {
            "source": self.id,
            "mode": mode,
            "applied": bool(applied),
            "change_request": change_request,
            "changed_stage": changed_stage,
            "changed_file": changed_file,
            "scene_id": scene_id,
            "item_id": item_id,
            "upstream_context_stages": upstream,
            "candidate_stages": candidate_stages,
            "impacted_downstream_stages": impacted,
            "stale_stages": stale,
            "summary": proposal.get("summary") or "",
            "update_plan": proposal.get("update_plan") or [],
            "stage_updates": summarize_stage_updates(proposal.get("stage_updates") or []),
            "applied_updates": applied,
            "skipped_updates": [*skipped, *(proposal.get("skipped_stages") or [])],
            "rerun_recommendations": proposal.get("rerun_recommendations") or recommendations,
            "user_review_focus": proposal.get("user_review_focus") or [],
        }
        if llm_error:
            report["llm_error"] = llm_error

        ctx.workspace.write_stage("10_change_propagator.json", report)
        write_change_propagator_markdown(ctx.workspace.review_dir / "10_change_propagator.md", report)
        ctx.workspace.append_log("change_propagator 已完成影响分析" + ("并应用修改" if applied else ""), {"changed_stage": changed_stage, "applied": len(applied)})
        ctx.workspace.refresh_review_index()

        message = "变更传播已应用" if applied else "变更传播分析已生成"
        return SkillResult(
            True,
            message,
            {
                "file": "stages/10_change_propagator.json",
                "review_file": "review/10_change_propagator.md",
                "applied": len(applied),
                "candidate_count": len(candidate_stages),
                "rerun_count": len(report["rerun_recommendations"]),
            },
        )


class ApplyChangeSkill:
    id = "apply_change"
    description = "半自动修改入口：接收用户修改请求，统一调用 change_propagator 生成同步计划或应用改动，并反馈影响范围与改动报告。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        change_request = str(input_data.get("change_request") or input_data.get("request") or input_data.get("note") or "").strip()
        if not change_request:
            return SkillResult(False, "缺少 change_request", {})
        apply_changes = bool(input_data.get("apply") or input_data.get("apply_changes"))
        propagator_input = {
            **input_data,
            "change_request": change_request,
            "apply": apply_changes,
            "skip_agent_review": True,
        }
        result = ChangePropagatorSkill().run(ctx, propagator_input)
        if not result.ok:
            return result
        mode = "apply" if apply_changes else "plan"
        return SkillResult(
            True,
            "修改已应用并生成传播报告" if apply_changes else "修改计划已生成，等待确认后应用",
            {
                **result.data,
                "file": "stages/10_change_propagator.json",
                "review_file": "review/10_change_propagator.md",
                "mode": mode,
                "change_request": change_request,
            },
        )


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
        DirectorStyleSelectSkill(),
        ConsistencyBibleSkill(),
        SceneBibleSkill(),
        AssetDesignSkill(),
        AssetCanonPlanSkill(),
        AssetCanonGenerateArkSkill(),
        VisualConsistencyReviewSkill(),
        SceneReferencePlanSkill(),
        SceneReferenceImportSkill(),
        SceneReferenceGenerateArkSkill(),
        CrossSceneContinuitySkill(),
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
        ReviewDecisionSkill(),
        ApplyChangeSkill(),
        ChangePropagatorSkill(),
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
    parts: list[str] = []
    style_path = ctx.workspace.wiki_dir / "style.md"
    if style_path.exists():
        text = style_path.read_text(encoding="utf-8").strip()
        if text and text != "# Style Profile":
            parts.append(text)
    style_stage = ctx.workspace.read_stage("00_style.json")
    if style_stage:
        parts.append(json.dumps(style_stage, ensure_ascii=False, indent=2))
    director_path = ctx.workspace.wiki_dir / "director_style.md"
    if director_path.exists():
        text = director_path.read_text(encoding="utf-8").strip()
        if text and text != "# Director Style":
            parts.append(text)
    director_stage = ctx.workspace.read_stage("00a_director_style.json")
    if director_stage:
        parts.append(json.dumps(director_stage, ensure_ascii=False, indent=2))
    return "\n\n".join(parts)


def frame_prompt(
    prompt: str, assets: list[dict[str, Any]] | None = None, style_context: str = "",
    continuity_state: Any = None,
) -> str:
    asset_lines = []
    for asset in assets or []:
        asset_lines.append(asset_prompt_line(asset))
    asset_context = "\n".join(asset_lines)
    asset_names = "、".join(str(asset.get("name", "")).strip() for asset in assets or [] if str(asset.get("name", "")).strip())
    # 该帧必须体现的连续性起止状态（服装/道具朝向/光线/站位），比风格摘要更不能丢。
    continuity_line = ""
    cs = clip_text(readable_state(continuity_state), 240) if continuity_state else ""
    if cs:
        continuity_line = f"连续性状态（必须在本帧画面中体现）：{cs}\n"
    base = (
        "竖屏9:16图生视频控制帧；无文字、无品牌、无UI、无拼贴。"
        "保持人物身份、服装、道具、地点、运动方向和物理状态连续。"
        "方向用相机相对语言；动作/方向镜用背影或过肩、把运动目的地放在画面纵深；对话镜用过肩、避免贴镜头大正脸。\n"
    )
    if continuity_line:
        base += continuity_line
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
    if continuity_line:
        compact_base += continuity_line
    # 精简时保留每个资产的身份关键词（校服拼色/书包颜色/配件），而不是只剩名字。
    compact_anchor = "；".join(
        clip_text(f"{str(asset.get('name', '')).strip()}：{clean_canon_text(asset.get('visual_identity') or asset.get('description'))}", 70)
        for asset in (assets or [])
    ) if assets else asset_names
    if style_context:
        compact_base += f"风格摘要：{clip_text(compact_style_summary(style_context), 80)}\n"
    compact_base += f"参考锚点：{compact_anchor}\n"
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


def deterministic_asset_designs(ctx: SkillContext, assets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cross_scene = ctx.workspace.read_stage("00e_cross_scene_continuity.json")
    scene_bible = ctx.workspace.read_stage("00c_scene_bible.json")
    style = ctx.workspace.read_stage("00_style.json")
    director_style = ctx.workspace.read_stage("00a_director_style.json")
    cross_index = {
        str(entity.get("name") or "").strip(): entity
        for entity in cross_scene.get("entities", [])
        if isinstance(entity, dict)
    }
    scene_text = json.dumps(scene_bible, ensure_ascii=False)
    style_profile = style.get("style") if isinstance(style.get("style"), dict) else {}
    director_profile = director_style.get("director_language") if isinstance(director_style.get("director_language"), dict) else {}
    style_label = " + ".join(
        part
        for part in [
            str(style_profile.get("label") or style.get("label") or "电影风格").strip(),
            str(director_profile.get("label") or "").strip(),
        ]
        if part
    )

    designed: list[dict[str, Any]] = []
    for asset in assets:
        item = dict(asset)
        name = str(item.get("name") or "").strip()
        asset_type = str(item.get("type") or "asset").strip()
        description = str(item.get("description") or "").strip()
        continuity = cross_index.get(name, {})
        continuity_text = inline_text(continuity) if continuity else ""
        prompt, negative, usage = deterministic_asset_prompt(
            name=name,
            asset_type=asset_type,
            description=description,
            continuity_text=continuity_text,
            scene_text=scene_text,
            style_label=style_label,
        )
        invariants = [
            f"{name} 的身份、外观核心特征、归属关系和剧情功能不得在后续镜头中无解释改变。",
            "遵守 consistency_bible、scene_bible 与 cross_scene_continuity 中已经锁定的服装、地点布局、道具状态和物理规则。",
        ]
        if continuity_text:
            invariants.append(clip_text(continuity_text, 180))
        item.update(
            {
                "story_function": description or f"{name} 在剧本中的叙事资产。",
                "visual_identity": f"{style_label}下的稳定视觉身份：{name}，{clip_text(description, 120)}",
                "visual_anchor_prompt": prompt,
                "negative_prompt": negative,
                "consistency_notes": "作为后续分镜、关键帧和图生视频的统一身份锚点；不得各镜头重新发明外观、位置关系或道具状态。",
                "continuity_invariants": invariants,
                "allowed_variations": [
                    "镜头景别、焦段、遮挡程度、自然光强弱和表演细微强度可以随场景变化。",
                    "只允许根据已批准的场景时间、剧情推进和人物状态产生合理磨损、汗水、疲惫或情绪变化。",
                ],
                "forbidden_variations": [
                    "禁止海报排版、九宫格拼贴、角色设定表、UI文字说明和水印。",
                    "禁止服装、书包颜色、道具归属、地点结构、运动方向和物理状态无原因跳变。",
                    negative,
                ],
                "cinematic_usage": usage,
                "generation_anchors": {
                    "positive_prompt": prompt,
                    "negative_prompt": negative,
                    "reference_priority": "高：该资产出现在画面时必须优先遵守本锚点，并结合对应 scene_reference 与前后镜头状态。",
                },
            }
        )
        designed.append(item)
    return designed


def deterministic_asset_prompt(
    name: str,
    asset_type: str,
    description: str,
    continuity_text: str,
    scene_text: str,
    style_label: str,
) -> tuple[str, str, dict[str, list[str]]]:
    context = clip_text("；".join(part for part in [description, continuity_text] if part), 220)
    if asset_type == "character":
        identity_bits = []
        if "眼镜" in description or "眼镜" in continuity_text:
            identity_bits.append("保留黑框或高度眼镜这一识别点")
        if "耳机" in description or "耳机" in continuity_text:
            identity_bits.append("耳机只在被场景规则允许时出现")
        identity = "；".join(identity_bits) or "保留剧本描述中的年龄气质、体态和人物状态"
        prompt = (
            f"竖屏9:16，{style_label}写实角色视觉锚点，{name}，中国高中生，统一白蓝校服，"
            f"{identity}；画面是单人或少量环境辅助的可拍摄参考，不是海报，不是拼贴，不是设定表；"
            f"自然光，真实布料褶皱，身份清楚但不过度明星化；剧情信息：{context}"
        )
        usage = {
            "best_framings": ["中景、半身、背影/侧背、过肩关系镜头；方向锁定时优先用无脸背影或局部特写。"],
            "lighting_notes": ["遵守各 scene_bible 的自然光方向和时间，不为单个角色任意改变色温。"],
            "movement_notes": ["人物入画方向、携带物和疲惫/汗水状态必须继承上一镜头与跨场景连续性。"],
        }
    elif asset_type == "location":
        layout_hint = "该地点已出现在场景制作包中。" if name in scene_text else "按剧本描述建立稳定空间结构。"
        prompt = (
            f"竖屏9:16，{style_label}写实地点视觉锚点，{name}，{layout_hint}"
            f"固定入口、出口、纵深、光线方向和主要动线；画面用于场地总览或机位参考，"
            f"不是最终分镜，不包含文字说明牌依赖；自然光与真实校园空间质感；剧情信息：{context}"
        )
        usage = {
            "best_framings": ["建立镜头、场地总览、主要机位板、道具摆放参考。"],
            "lighting_notes": ["同一大场景内保持主光方向、阴影方向和色温连续。"],
            "movement_notes": ["人物和道具运动必须沿 scene_bible 锁定动线，不反转轴线。"],
        }
    else:
        prompt = (
            f"竖屏9:16，{style_label}写实道具视觉锚点，{name}，单个道具或道具在真实场景中的使用状态，"
            f"材质、颜色、尺寸、归属关系和损坏/丢失/转移状态清楚；不是商品广告，不是UI说明，"
            f"不出现多余文字标签；剧情信息：{context}"
        )
        usage = {
            "best_framings": ["插入特写、手部动作特写、道具落点、道具归属确认镜头。"],
            "lighting_notes": ["道具受当前场景自然光影响，不单独打成棚拍广告光。"],
            "movement_notes": ["道具出现、消失、飞出、被捡起或转移必须符合前后镜头因果。"],
        }
    negative = "海报，拼贴，九宫格，设定表，UI，水印，文字说明页，夸张漫画化，服装漂移，身份漂移，地点结构漂移，道具归属错误，物理状态跳变"
    return prompt, negative, usage


def normalize_asset_design(asset: dict[str, Any], idx: int) -> dict[str, Any]:
    """补齐影视资产圣经字段，同时保留旧流程依赖的 prompt 字段。"""
    item = dict(asset)
    name = str(item.get("name") or f"asset_{idx:03d}").strip()
    asset_type = str(item.get("type") or "asset").strip()
    # 清洗 LLM 可能抄进来的 {...}/[...] JSON/dict 片段（如 {'id':'film'}、{"entity_id":...}），避免污染下游图片 prompt。
    description = clean_canon_text(item.get("description"))
    visual_anchor = clean_canon_text(item.get("visual_anchor_prompt"))
    negative = clean_canon_text(item.get("negative_prompt"))
    consistency = clean_canon_text(item.get("consistency_notes"))
    identity = clean_canon_text(item.get("visual_identity") or visual_anchor or description)
    # 把清洗后的值写回，覆盖原始脏值（setdefault 之前先落定干净值）。
    if item.get("description"):
        item["description"] = description
    for field in ("visual_anchor_prompt", "negative_prompt", "consistency_notes", "visual_identity"):
        if item.get(field):
            item[field] = clean_canon_text(item.get(field))

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
        depends = [] if role == "location_master_plate" else [safe_name(f"{scene_id}_location_master_plate")]
        tasks.append(
            {
                "reference_id": ref_id,
                "scene_id": scene_id,
                "scene_asset_pack_id": f"{scene_id}_scene_asset_pack",
                "pack_required_before_keyframes": True,
                "pack_role": "master" if role == "location_master_plate" else "derived",
                "reference_role": role,
                "label": label,
                "local_path": (Path("assets") / "scene_refs" / f"{ref_id}.png").as_posix(),
                "prompt": scene_reference_prompt(scene, label, source_prompt, style_context),
                "must_show": scene_reference_must_show(scene, role),
                "must_not_show": scene_reference_must_not_show(),
                "depends_on_reference_ids": depends,
                "shared_asset_policy": "场地总览 master plate，作为同一 scene_id 后续参考图的共同资产锚点。" if role == "location_master_plate" else "必须继承同一 scene_id 的 location_master_plate，不得重新发明场地共同资产、入口出口、光线方向或轴线。",
                "status": "needs_codex_image_generation",
            }
        )
    return tasks


def sort_scene_reference_tasks(tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    priority = {
        "location_master_plate": 0,
        "prop_placement_plate": 1,
        "camera_angle_plate_01": 2,
        "collision_point_plate": 3,
        "post_collision_state_plate": 4,
    }
    return sorted(
        tasks,
        key=lambda task: (
            str(task.get("scene_id") or ""),
            priority.get(str(task.get("reference_role") or ""), 10),
            str(task.get("reference_id") or ""),
        ),
    )


def dependency_scene_reference_refs(ctx: SkillContext, task: dict[str, Any], existing: dict[str, dict[str, Any]]) -> list[str]:
    refs, _missing = resolve_dependency_reference_media(ctx, task, existing)
    return [media for _id, media in refs][:2]


def resolve_dependency_reference_media(
    ctx: SkillContext, task: dict[str, Any], existing: dict[str, dict[str, Any]]
) -> tuple[list[tuple[str, str]], list[str]]:
    """同一 scene_id 内的依赖底图（通常是 location_master_plate）。返回 (可用 [(id, media_ref)], 缺失 id)。"""
    used: list[tuple[str, str]] = []
    missing: list[str] = []
    for dep_id in task.get("depends_on_reference_ids") or []:
        dep = existing.get(str(dep_id)) or {}
        local = resolve_workspace_path(ctx, dep.get("local_path"))
        if local and local.exists():
            used.append((str(dep_id), downscaled_media_ref(str(local))))
        else:
            missing.append(str(dep_id))
    return used, missing


# ---- Asset canon: 项目级共用参考图（大门/校服/复用道具的唯一外观锚点）----

CANON_TYPE_PREFIX = {"character": "char", "location": "loc", "prop": "prop"}


def canon_id_for_asset(asset: dict[str, Any]) -> str:
    asset_type = str(asset.get("type") or "asset").strip()
    prefix = CANON_TYPE_PREFIX.get(asset_type) or safe_name(asset_type) or "asset"
    name = str(asset.get("name") or asset.get("asset_id") or "asset").strip()
    return safe_name(f"canon_{prefix}_{name}")


# 人物 canon 出正/侧/背三视图，锁全角度身份；正面用基础 canon_id（向后兼容已有 canon_refs）。
CHARACTER_CANON_VIEWS = [
    ("", "front", "正面全身：面向镜头自然站立，清楚展示校服正面（领口、门襟、袖口配色）、书包肩带与体型比例。"),
    ("_side", "side", "正侧面全身：约90度侧身站立，展示校服侧面剪影、裤线走向与书包侧面轮廓。"),
    ("_back", "back", "背面全身：完全背对镜头，清楚展示双肩书包整体外观、颜色、背面校服与发型背影。"),
]


def asset_canon_tasks(
    assets: list[dict[str, Any]], consistency: dict[str, Any], style_context: str = ""
) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    for asset in assets:
        if not isinstance(asset, dict):
            continue
        asset_type = str(asset.get("type") or "").strip()
        if asset_type not in CANON_TYPE_PREFIX:
            continue
        base_id = canon_id_for_asset(asset)
        if asset_type == "character":
            variants = [(base_id + suffix, view, hint) for suffix, view, hint in CHARACTER_CANON_VIEWS]
        else:
            variants = [(base_id, None, "")]
        for canon_id, view, view_hint in variants:
            tasks.append(
                {
                    "canon_id": canon_id,
                    "asset_type": asset_type,
                    "asset_name": asset.get("name"),
                    "asset_id": asset.get("asset_id"),
                    "view": view,
                    "label": f"{asset.get('name', '')} 共用 canon 基准图" + (f"（{view}）" if view else ""),
                    "local_path": (Path("assets") / "canon" / f"{canon_id}.png").as_posix(),
                    "prompt": canon_prompt(asset, consistency, style_context, view=view, view_hint=view_hint),
                    "must_show": canon_must_show(asset, consistency),
                    "must_not_show": canon_must_not_show(),
                    "shared_asset_policy": "项目级唯一外观锚点：全片所有场景参考图、关键帧和图生视频必须继承此 canon，不得各自重新发明大门/校服/道具外观。",
                    "status": "needs_image_generation",
                }
            )
    return tasks


def consistency_layout_for_name(consistency: dict[str, Any], name: str) -> str:
    layouts = consistency.get("location_layouts")
    if isinstance(layouts, dict):
        for key, val in layouts.items():
            if key and (str(key) in name or name in str(key)):
                return inline_text(val)
    return ""


def consistency_prop_for_name(consistency: dict[str, Any], name: str) -> str:
    props = consistency.get("recurring_props")
    if isinstance(props, dict):
        for key, val in props.items():
            if key and (name in str(key) or str(key) in name):
                return inline_text(val)
    return ""


def clean_canon_text(value: Any) -> str:
    """清洗资产字段：去掉混入的 dict/JSON 转储片段、重复的竖屏前缀和多余空白，避免污染图片 prompt。"""
    text = inline_text(value)
    for _ in range(6):  # 反复剥除嵌套的 {...} / [...] JSON 片段
        new = re.sub(r"\{[^{}]*\}", " ", text)
        new = re.sub(r"\[[^\[\]]*\]", " ", new)
        if new == text:
            break
        text = new
    text = re.sub(r"竖屏\s*9:16[，,、]?", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" ，,；;、")
    return text


def canon_prompt(
    asset: dict[str, Any], consistency: dict[str, Any], style_context: str = "",
    view: str | None = None, view_hint: str = "",
) -> str:
    asset_type = str(asset.get("type") or "").strip()
    name = str(asset.get("name") or "")
    anchor = clean_canon_text(asset.get("visual_identity") or asset.get("visual_anchor_prompt") or asset.get("description"))
    invariants = clean_canon_text(asset.get("continuity_invariants"))
    forbidden = clean_canon_text(asset.get("forbidden_variations"))
    parts = [
        "竖屏9:16 项目级共用 canon 基准参考图；这是全片所有场景、分镜、关键帧、图生视频共享的唯一外观锚点，不是分镜，不是海报，不是设定集排版。",
        f"风格摘要：{compact_style_summary(style_context)}" if style_context else "",
    ]
    if asset_type == "character":
        uniform = inline_text(consistency.get("uniform"))
        view_label = {"front": "正面", "side": "正侧面", "back": "背面"}.get(view or "", "")
        parts += [
            f"类型：人物定妆 canon（{view_label}视图）。角色：{name}。" if view_label else f"类型：人物定妆 canon。角色：{name}。",
            f"外观锚点：{anchor}" if anchor else "",
            f"统一校服（全片强制一致）：{uniform}" if uniform else "",
            f"机位与姿态：{view_hint}" if view_hint else "",
            "构图：单人居中、全身入镜，中性纯色或轻度虚化背景，自然均匀光，同一人物在正/侧/背三视图中的五官、发型、身材、校服与书包必须保持完全一致；不要多人、不要叙事场景、不要无关道具堆砌。",
        ]
    elif asset_type == "location":
        layout = consistency_layout_for_name(consistency, name)
        parts += [
            f"类型：地点 canon。地点：{name}。",
            f"外观锚点：{anchor}" if anchor else "",
            f"固定布局（全片强制一致）：{layout}" if layout else "",
            "构图：平视机位（相机约人眼1.5米高度、水平视线，严禁俯瞰/鸟瞰/航拍等高角度）；清楚交代该地点的标志性结构、入口出口、空间方位与材质；只保留少量稀疏的远景人物背影，不要密集人群，不要主要角色大脸特写。",
        ]
    else:
        prop_desc = consistency_prop_for_name(consistency, name)
        parts += [
            f"类型：道具 canon。道具：{name}。",
            f"外观锚点：{anchor}" if anchor else "",
            f"统一外观（全片强制一致）：{prop_desc}" if prop_desc else "",
            "构图：单一道具居中，中性背景，清楚展示款式、颜色、材质与关键细节；不要人物、不要叙事场景。",
        ]
    if invariants:
        parts.append(f"绝不可变的身份/服装/材质规则：{invariants}")
    if forbidden:
        parts.append(f"禁止漂移：{forbidden}")
    parts.append("无可读文字、无字幕、无标题字、无水印、无logo、无UI、无拼贴。")
    return "\n".join(part for part in parts if part)


def canon_must_show(asset: dict[str, Any], consistency: dict[str, Any]) -> list[str]:
    asset_type = str(asset.get("type") or "").strip()
    name = str(asset.get("name") or "")
    items = [f"资产身份：{name}"]
    if asset_type == "character":
        items.append(f"统一校服：{inline_text(consistency.get('uniform'))}")
    elif asset_type == "location":
        items.append(f"固定布局：{consistency_layout_for_name(consistency, name)}")
    else:
        items.append(f"统一外观：{consistency_prop_for_name(consistency, name)}")
    return [item for item in items if item and not item.endswith("：")]


def canon_must_not_show() -> list[str]:
    return [
        "清晰可读文字、字幕、标题字、水印、logo、UI 或拼贴排版",
        "与 Consistency Bible 冲突的服装、配色、布局或道具外观",
        "多个主体抢镜或与该 canon 资产无关的元素",
        "海报感、概念图感、舞台布景感",
    ]


def load_asset_canon_index(ctx: SkillContext) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for canon in ctx.workspace.read_stage("00f_asset_canon.json").get("asset_canon", []) or []:
        canon_id = str(canon.get("canon_id") or "").strip()
        if canon_id:
            out[canon_id] = canon
    return out


def location_canon_ids_for_scene(scene: dict[str, Any], canon_index: dict[str, dict[str, Any]]) -> list[str]:
    location = str(scene.get("location") or "")
    if not location:
        return []
    hits: list[str] = []
    for canon_id, canon in canon_index.items():
        if str(canon.get("asset_type")) != "location":
            continue
        asset_name = str(canon.get("asset_name") or "")
        if asset_name and (asset_name in location or location in asset_name):
            hits.append(canon_id)
    return hits


def scene_ref_priority(ref_id: str) -> int:
    """喂给场景参考图的底图重要度：地点 canon(大门) > 同场景 master plate > 角色 canon > 道具 canon。"""
    r = str(ref_id)
    if r.startswith("canon_loc_"):
        return 0
    if "master_plate" in r:
        return 1
    if r.startswith("canon_char_"):
        return 2
    return 3


def resolve_canon_reference_media(
    ctx: SkillContext, canon_ids: list[str], canon_index: dict[str, dict[str, Any]]
) -> tuple[list[tuple[str, str]], list[str]]:
    """把 canon_id 列表解析成可喂给图片生成的底图。返回 (可用 [(id, media_ref)], 缺失 id)。"""
    used: list[tuple[str, str]] = []
    missing: list[str] = []
    for canon_id in canon_ids:
        canon = canon_index.get(str(canon_id))
        local = resolve_workspace_path(ctx, canon.get("local_path")) if canon else None
        if canon and str(canon.get("state")) == "ready" and local and local.exists():
            used.append((str(canon_id), downscaled_media_ref(str(local))))
        else:
            missing.append(str(canon_id))
    return used, missing


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


def scene_asset_pack_statuses(ctx: SkillContext, scene_reference_context: dict[str, list[dict[str, Any]]]) -> dict[str, dict[str, Any]]:
    statuses: dict[str, dict[str, Any]] = {}
    required_core = {"location_master_plate", "prop_placement_plate"}
    for scene_id, refs in scene_reference_context.items():
        roles: dict[str, list[str]] = {}
        ready: list[str] = []
        missing_images: list[str] = []
        for ref in refs:
            ref_id = str(ref.get("reference_id") or "").strip()
            role = str(ref.get("reference_role") or "").strip()
            if role:
                roles.setdefault(role, []).append(ref_id)
            local = resolve_workspace_path(ctx, ref.get("local_path"))
            if local and local.exists():
                ready.append(ref_id)
            elif ref_id:
                missing_images.append(ref_id)
        has_camera = any(role.startswith("camera_angle_plate") for role in roles)
        missing_core = sorted(role for role in required_core if role not in roles)
        if not has_camera:
            missing_core.append("camera_angle_plate")
        statuses[scene_id] = {
            "scene_asset_pack_id": f"{scene_id}_scene_asset_pack",
            "required_before_keyframes": True,
            "roles_planned": sorted(roles),
            "ready_reference_ids": ready,
            "missing_image_reference_ids": missing_images,
            "missing_core_roles": missing_core,
            "is_ready_for_keyframes": not missing_core and not missing_images,
            "rule": "进入该大场景正式关键帧前，先确认共同资产包已生成并通过审阅。",
        }
    return statuses


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
        return downscaled_media_ref(str(local))  # 参考图缩小，避免大 payload 拖慢/卡死出图
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
        "00a_director_style.json": {"skill": "director_style_select", "deps": ["01_script.json", "00_style.json"]},
        "00b_consistency.json": {"skill": "consistency_bible", "deps": ["01_script.json", "00_style.json", "00a_director_style.json"]},
        "00c_scene_bible.json": {"skill": "scene_bible", "deps": ["01_script.json", "00_style.json", "00a_director_style.json", "00b_consistency.json"]},
        "00d_scene_reference_plan.json": {"skill": "scene_reference_plan", "deps": ["00c_scene_bible.json", "00_style.json", "00a_director_style.json"]},
        "00d_scene_references.json": {"skill": "scene_reference_import 或 scene_reference_generate_ark", "deps": ["00d_scene_reference_plan.json"]},
        "00e_cross_scene_continuity.json": {"skill": "cross_scene_continuity", "deps": ["01_script.json", "00a_director_style.json", "00c_scene_bible.json", "00d_scene_reference_plan.json"]},
        "02_assets.json": {"skill": "asset_design", "deps": ["01_script.json", "00_style.json", "00a_director_style.json", "00b_consistency.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json"]},
        "03_storyboards.json": {"skill": "storyboard_plan", "deps": ["01_script.json", "00_style.json", "00a_director_style.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json", "02_assets.json"]},
        "04_atomic_shots.json": {"skill": "atomic_shot_plan", "deps": ["03_storyboards.json", "00a_director_style.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json", "02_assets.json"]},
        "04b_continuity_validation.json": {"skill": "continuity_validator", "deps": ["00a_director_style.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json", "03_storyboards.json", "04_atomic_shots.json"]},
        "05_keyframe_plan.json": {"skill": "keyframe_plan", "deps": ["04_atomic_shots.json", "04b_continuity_validation.json", "00a_director_style.json", "00d_scene_references.json", "02_assets.json"]},
        "05_keyframes.json": {"skill": "keyframe_import 或 keyframe_generate_ark", "deps": ["05_keyframe_plan.json"]},
        "06_videos.json": {"skill": "video_generate_ark", "deps": ["05_keyframes.json", "05_keyframe_plan.json", "00d_scene_references.json"]},
        "06b_scene_transition_plan.json": {"skill": "scene_transition_plan", "deps": ["06_videos.json", "00c_scene_bible.json", "00e_cross_scene_continuity.json"]},
        "06b_scene_transitions.json": {"skill": "scene_transition_generate_ark", "deps": ["06b_scene_transition_plan.json"]},
    }


def stage_for_skill(skill_id: str) -> str:
    for stage, meta in stage_dependency_graph().items():
        if str(meta.get("skill", "")).split(" ")[0] == skill_id or skill_id in str(meta.get("skill", "")):
            return stage
    skill_stage_map = {
        "review_decision": "09_review_decision.json",
        "knowledge_capture": "07_knowledge_capture.json",
        "change_propagator": "10_change_propagator.json",
        "apply_change": "10_change_propagator.json",
    }
    return skill_stage_map.get(skill_id, "")


NON_MUTABLE_PROPAGATION_STAGES = {
    "00_document.json",
    "00d_scene_references.json",
    "05_keyframes.json",
    "06_videos.json",
    "06b_scene_transitions.json",
}


def normalize_stage_list(value: Any) -> list[str]:
    if isinstance(value, str):
        raw = [item.strip() for item in value.split(",") if item.strip()]
    elif isinstance(value, list):
        raw = [str(item).strip() for item in value if str(item).strip()]
    else:
        raw = []
    return unique_stage_order(normalize_stage_name(item) for item in raw)


def unique_stage_order(values: Any) -> list[str]:
    seen: set[str] = set()
    rows: list[str] = []
    for value in values:
        stage = normalize_stage_name(str(value or ""))
        if not stage or stage in seen:
            continue
        seen.add(stage)
        rows.append(stage)
    return rows


def upstream_dependency_stages(stage: str, graph: dict[str, dict[str, Any]]) -> list[str]:
    if not stage or stage not in graph:
        return []
    rows: list[str] = []

    def visit(current: str) -> None:
        for dep in graph.get(current, {}).get("deps") or []:
            if dep in rows:
                continue
            visit(dep)
            rows.append(dep)

    visit(stage)
    return rows


def change_candidate_stages(ctx: SkillContext, changed_stage: str, impacted: list[str], explicit_stages: list[str]) -> list[str]:
    if explicit_stages:
        raw = explicit_stages
    else:
        raw = [changed_stage, *impacted]
    rows = []
    for stage in unique_stage_order(raw):
        if not stage or stage in NON_MUTABLE_PROPAGATION_STAGES:
            continue
        if ctx.workspace.stage_path(stage).exists():
            rows.append(stage)
    return rows


def change_propagator_prompt(
    ctx: SkillContext,
    *,
    change_request: str,
    changed_stage: str,
    changed_file: str,
    scene_id: str,
    item_id: str,
    apply_changes: bool,
    context_stages: list[str],
    candidate_stages: list[str],
    recommendations: list[dict[str, Any]],
) -> str:
    stage_blocks = []
    for stage in context_stages:
        path = ctx.workspace.stage_path(stage)
        if not path.exists():
            continue
        role = "mutable_candidate" if stage in candidate_stages and stage not in NON_MUTABLE_PROPAGATION_STAGES else "context_only"
        stage_blocks.append(
            "\n".join(
                [
                    f"--- stage: {stage}",
                    f"role: {role}",
                    f"skill: {(stage_dependency_graph().get(stage) or {}).get('skill', '')}",
                    path.read_text(encoding="utf-8")[:50000],
                ]
            )
        )
    decisions = ctx.workspace.read_decisions()
    wiki_parts = []
    for name in ["style.md", "director_style.md", "scene_bible.md", "continuity.md", "decisions.md"]:
        path = ctx.workspace.wiki_dir / name
        if path.exists():
            wiki_parts.append(f"--- wiki/{name}\n{path.read_text(encoding='utf-8')[:8000]}")
    return (
        f"Mode: {'apply' if apply_changes else 'plan'}\n"
        f"Change request: {change_request}\n"
        f"Changed stage: {changed_stage}\n"
        f"Changed file: {changed_file}\n"
        f"Scene id: {scene_id}\n"
        f"Item id: {item_id}\n"
        f"Mutable candidate stages: {json.dumps(candidate_stages, ensure_ascii=False)}\n"
        f"Existing rerun recommendations: {json.dumps(recommendations, ensure_ascii=False, indent=2)}\n"
        f"Recent decisions: {json.dumps((decisions.get('decisions') or [])[-8:], ensure_ascii=False, indent=2)}\n\n"
        "Update policy:\n"
        "- In plan mode, explain exact changes but you may omit updated_stage.\n"
        "- In apply mode, include updated_stage only for mutable candidate stages that need concrete edits.\n"
        "- Preserve every unrelated item and field exactly as much as possible.\n"
        "- If a downstream stage should be regenerated instead of edited, use action=review_only or skip and explain why.\n\n"
        "Wiki context:\n"
        + "\n\n".join(wiki_parts)
        + "\n\nStage context:\n"
        + "\n\n".join(stage_blocks)
    )


def local_change_propagation_plan(
    *,
    change_request: str,
    changed_stage: str,
    changed_file: str,
    scene_id: str,
    item_id: str,
    candidate_stages: list[str],
    recommendations: list[dict[str, Any]],
    error: str,
) -> dict[str, Any]:
    return {
        "summary": "LLM 修改器不可用，已生成本地影响分析；未自动改写 stage。",
        "mode": "fallback_plan",
        "impacted_stages": candidate_stages,
        "update_plan": [
            {
                "stage": stage,
                "action": "review_only",
                "reason": "需要根据用户修改请求人工复查或重跑；本地兜底模式不会自动改写内容。",
            }
            for stage in candidate_stages
        ],
        "stage_updates": [],
        "skipped_stages": [{"stage": stage, "reason": "LLM unavailable"} for stage in candidate_stages],
        "user_review_focus": [
            "确认修改请求是否应先落在上游 stage，再重跑下游 stage。",
            "确认受影响的角色、道具、地点、运动方向和关键帧提示词是否需要同步。",
        ],
        "rerun_recommendations": recommendations,
        "error": error,
        "request_echo": {"change_request": change_request, "changed_stage": changed_stage, "changed_file": changed_file, "scene_id": scene_id, "item_id": item_id},
    }


def apply_stage_updates(ctx: SkillContext, stage_updates: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    applied: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    stamp = time.strftime("%Y%m%d_%H%M%S")
    backup_dir = ctx.workspace.root / "archive" / "change_propagator" / stamp
    for update in stage_updates:
        if not isinstance(update, dict):
            skipped.append({"stage": "", "reason": "invalid update row"})
            continue
        stage = normalize_stage_name(str(update.get("stage") or ""))
        action = str(update.get("action") or "").strip().lower()
        updated_stage = update.get("updated_stage")
        if action != "update":
            skipped.append({"stage": stage, "reason": update.get("reason") or f"action={action or 'n/a'}"})
            continue
        if not stage or stage in NON_MUTABLE_PROPAGATION_STAGES:
            skipped.append({"stage": stage, "reason": "stage is not mutable by change_propagator"})
            continue
        if not isinstance(updated_stage, dict):
            skipped.append({"stage": stage, "reason": "missing complete updated_stage object"})
            continue
        stage_path = ctx.workspace.stage_path(stage)
        if not stage_path.exists():
            skipped.append({"stage": stage, "reason": "stage file does not exist"})
            continue
        before = ctx.workspace.read_stage(stage)
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_path = backup_dir / stage
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        backup_path.write_text(stage_path.read_text(encoding="utf-8"), encoding="utf-8")
        ctx.workspace.write_stage(stage, updated_stage)
        after = ctx.workspace.read_stage(stage)
        applied.append(
            {
                "stage": stage,
                "backup": backup_path.relative_to(ctx.workspace.root).as_posix(),
                "reason": update.get("reason") or "",
                "changes": update.get("changes") or [],
                "top_level_diff": top_level_diff_summary(before, after),
            }
        )
    return applied, skipped


def summarize_stage_updates(stage_updates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for update in stage_updates:
        if not isinstance(update, dict):
            continue
        rows.append(
            {
                "stage": update.get("stage"),
                "action": update.get("action"),
                "reason": update.get("reason"),
                "changes": update.get("changes") or [],
                "has_updated_stage": isinstance(update.get("updated_stage"), dict),
            }
        )
    return rows


def top_level_diff_summary(before: dict[str, Any], after: dict[str, Any]) -> dict[str, list[str]]:
    before_keys = set(before)
    after_keys = set(after)
    changed = []
    for key in sorted(before_keys & after_keys):
        if before.get(key) != after.get(key):
            changed.append(key)
    return {
        "added": sorted(after_keys - before_keys),
        "removed": sorted(before_keys - after_keys),
        "changed": changed,
    }


def write_change_propagator_markdown(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    applied_lines = []
    for item in report.get("applied_updates") or []:
        if isinstance(item, dict):
            applied_lines.append(f"{item.get('stage')}: {inline_text(item.get('changes')) or item.get('reason')}")
        else:
            applied_lines.append(str(item))
    skipped_lines = []
    for item in report.get("skipped_updates") or []:
        if isinstance(item, dict):
            skipped_lines.append(f"{item.get('stage')}: {item.get('reason')}")
        else:
            skipped_lines.append(str(item))
    rerun_lines = []
    for item in report.get("rerun_recommendations") or []:
        if isinstance(item, dict):
            rerun_lines.append(f"{item.get('stage')} ({item.get('skill')}): {item.get('action')} - {item.get('reason')}")
        else:
            rerun_lines.append(str(item))
    lines = [
        "# 变更传播报告",
        "",
        f"- mode: {report.get('mode')}",
        f"- applied: {report.get('applied')}",
        f"- changed_stage: {report.get('changed_stage') or 'n/a'}",
        f"- scene_id: {report.get('scene_id') or 'n/a'}",
        f"- item_id: {report.get('item_id') or 'n/a'}",
        "",
        "## 修改请求",
        "",
        str(report.get("change_request") or ""),
        "",
        "## 总结",
        "",
        str(report.get("summary") or ""),
        "",
        "## 已应用改动",
        "",
        bullet_lines(applied_lines),
        "",
        "## 跳过/只复查",
        "",
        bullet_lines(skipped_lines),
        "",
        "## 后续重跑/复查建议",
        "",
        bullet_lines(rerun_lines),
        "",
        "## 用户复核重点",
        "",
        bullet_lines(report.get("user_review_focus")),
        "",
        "## 完整 JSON",
        "",
        "```json",
        json.dumps(report, ensure_ascii=False, indent=2),
        "```",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


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


def readable_state(value: Any) -> str:
    """把结构化连续性状态（dict/list）扁平成不带花括号的可读中文，喂进图片 prompt。"""
    if value is None:
        return ""
    if isinstance(value, dict):
        parts = [f"{k}：{readable_state(v)}" for k, v in value.items() if readable_state(v)]
        return "；".join(parts)
    if isinstance(value, list):
        return "、".join(readable_state(v) for v in value if readable_state(v))
    return str(value).strip()


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


def director_style_options() -> list[dict[str, Any]]:
    return [
        {
            "id": "japanese_healing",
            "label": "日系治愈风格",
            "description": "自然光、生活化校园空间、克制表演、细节留白和温柔节奏，强调空气感与情绪余波。",
            "visual_rules": ["自然光优先", "低到中等饱和度", "保留清透空气感", "校园空间有生活细节", "避免悬浮偶像剧滤镜"],
            "camera_rules": ["更多静观镜头、轻微跟拍和缓慢推近", "少用强冲突机位和快速剪辑", "用环境和小动作承接情绪", "建立镜头要让空间安静可感"],
            "blocking_rules": ["人物移动自然，不做舞台式站位", "关系变化通过距离、停顿和视线体现", "冲突动作尽量保留真实身体余波"],
            "performance_rules": ["表情克制", "情绪通过停顿、眼神和动作余波表达", "避免夸张喊叫和短剧式大反应"],
            "editing_rules": ["剪辑节奏温和", "允许短暂停留在环境或人物反应上", "困难动作可用反应镜头柔化硬切"],
            "prompt_rules": ["把风格落实为自然光、生活细节、克制表演、轻微镜头运动和真实校园动线", "不要只写日系治愈四个字"],
            "avoid": ["强烈商业广告光", "过度磨皮偶像剧质感", "悬浮校园滤镜", "夸张反应表演", "用大段文字解释情绪"],
        },
        {
            "id": "youth_campus_realism",
            "label": "青春校园写实风格",
            "description": "贴近真实校园的明亮写实语言，强调少年动作、自然交流、轻喜剧节奏和清楚空间动线。",
            "visual_rules": ["真实校园自然光", "校服和书包识别清楚", "画面干净但不过度精修", "同学人流自然"],
            "camera_rules": ["跟拍、过肩、局部特写和中景调度结合", "动作镜头先锁方向再看表情", "对话用关系镜头和反应镜头承接"],
            "blocking_rules": ["人物走位符合真实校园动线", "避免所有人物正面排队式站位", "道具动作要有可见因果"],
            "performance_rules": ["少年感来自动作和犹豫，不来自夸张卖萌", "急、尴尬、好奇要通过微动作呈现"],
            "editing_rules": ["节奏清楚，保留动作因果", "喜剧点用反应镜头收住，不用过度音效化画面"],
            "prompt_rules": ["强调真实校园、自然人流、清楚动线、克制少年表演"],
            "avoid": ["短剧式大吼大叫", "过度偶像剧滤镜", "人物站位僵硬", "校园空间随镜头漂移"],
        },
        {
            "id": "youth_inspirational_campus",
            "label": "青春励志校园风格",
            "description": "明亮、写实、带成长弧光的校园导演语言，强调少年从慌乱、挫败到专注和互相点燃的过程。",
            "visual_rules": ["真实校园自然光", "画面明亮但不过曝", "保留汗水、尘土、书包和球拍等成长痕迹", "色彩清爽有朝气", "避免悬浮偶像剧滤镜"],
            "camera_rules": ["开场用环境和人流建立青春校园气息", "主动作镜头要清楚锁定方向和身体重心", "训练/比赛段落用跟拍、低机位、反应镜头和道具特写形成推进", "情绪转折用缓慢推近或停顿反应承接"],
            "blocking_rules": ["人物关系通过一起走、擦肩、停顿、追赶、训练陪伴等真实动作建立", "运动场景必须看清脚步、球拍、球台和身体重心", "群体同学是校园氛围，不要抢走主角成长线"],
            "performance_rules": ["少年感来自急、犹豫、尴尬、较劲和不服输", "励志感来自一次次调整动作和重新站起来", "避免喊口号式热血和短剧式夸张表情"],
            "editing_rules": ["前半段保留校园生活节奏，训练/比赛段落逐步加快", "关键失败后要给反应镜头，关键进步后要给呼吸和眼神余波", "比分跳转用赛后身体状态、汗水和同伴反应承接"],
            "prompt_rules": ["把青春励志落实为真实校园光线、少年身体动作、训练痕迹、同伴关系和成长节奏", "不要只写青春励志四个字", "运动镜头必须描述身体力学和道具轨迹"],
            "avoid": ["口号式热血", "MV 式空泛慢动作", "过度偶像剧磨皮", "无因果的突然变强", "只靠字幕或比分文字表达成长"],
        },
        {
            "id": "sports_hotblood_realism",
            "label": "运动热血写实风格",
            "description": "写实运动片语言，强调身体力量、节奏推进、汗水和训练/比赛空间的真实压力。",
            "visual_rules": ["运动空间结构清楚", "汗水和呼吸真实", "光线有现场感", "道具和身体动作可信"],
            "camera_rules": ["动作前用建立镜头锁空间", "比赛中用低机位、跟拍、插入特写和反应镜头组合", "关键球不硬赌长镜头"],
            "blocking_rules": ["球拍、球、脚步和身体重心有因果", "困难动作优先拆成可生成的动作段落"],
            "performance_rules": ["热血来自专注、疲惫和不服输", "避免漫画式爆气或夸张超能力"],
            "editing_rules": ["节奏可加快，但每个动作因果必须可读", "比分跳转用赛后状态或插入信息承接"],
            "prompt_rules": ["强调身体力学、运动轨迹、汗水、呼吸和比赛空间压力"],
            "avoid": ["无物理依据的瞬移", "球拍或球随机变形", "过多动作塞进短镜头", "纯文字比分依赖"],
        },
        {
            "id": "urban_lyrical_restraint",
            "label": "都市抒情留白风格",
            "description": "克制、疏离、带留白的作者型镜头语言，强调空间隔阂、反射、擦肩和未说出口的情绪。",
            "visual_rules": ["低对比柔光", "反射和遮挡可作为情绪媒介", "空间留白明显", "色彩克制"],
            "camera_rules": ["多用静观、侧拍、隔物拍摄和缓慢推移", "让人物关系通过距离和错位表达", "少用解释性正反打"],
            "blocking_rules": ["人物不必总在画面中心", "错身、停顿和背影可以承担叙事"],
            "performance_rules": ["情绪内收", "对白后留反应余波", "避免外放式宣泄"],
            "editing_rules": ["允许沉默和停顿", "剪辑点落在情绪变化之后"],
            "prompt_rules": ["把留白落实为空间距离、遮挡、反射、侧背和停顿"],
            "avoid": ["空泛文艺词", "过度慢导致信息缺失", "强行模仿某个具体导演的标志性台词或镜头"],
        },
        {
            "id": "eastern_color_ensemble",
            "label": "东方浓彩群像风格",
            "description": "强构图、色彩秩序、群体调度和空间仪式感，强调人物在环境和群体关系中的位置。",
            "visual_rules": ["色彩有明确主次", "构图稳定", "空间层次强", "群体调度有秩序"],
            "camera_rules": ["用远景/大全景建立空间权力关系", "群像镜头注意前中后景层次", "关键人物用色块和位置突出"],
            "blocking_rules": ["群体运动方向统一但不僵硬", "人物站位服务关系和冲突", "道具位置具有视觉秩序"],
            "performance_rules": ["表演克制但姿态明确", "群体反应形成氛围压力"],
            "editing_rules": ["剪辑不宜过碎", "重要调度让观众看清空间关系"],
            "prompt_rules": ["把风格落实为色彩秩序、群体调度、稳定构图和空间层次"],
            "avoid": ["无理由高饱和", "堆砌红黄大色块", "人物身份被群像淹没", "直接复制具体导演招牌画面"],
        },
    ]


def format_director_style_markdown(profile: dict[str, Any]) -> str:
    lines = [
        "# Director Style（导演语言档案，所有视觉阶段和导演审查必须遵守）",
        "",
        f"- id: {profile.get('id', '')}",
        f"- label: {profile.get('label', '')}",
        f"- description: {profile.get('description', '')}",
        "",
        "## 视觉规则",
        "",
        bullet_lines(profile.get("visual_rules")),
        "",
        "## 镜头规则",
        "",
        bullet_lines(profile.get("camera_rules")),
        "",
        "## 场面调度规则",
        "",
        bullet_lines(profile.get("blocking_rules")),
        "",
        "## 表演规则",
        "",
        bullet_lines(profile.get("performance_rules")),
        "",
        "## 剪辑节奏规则",
        "",
        bullet_lines(profile.get("editing_rules")),
        "",
        "## Prompt 规则",
        "",
        bullet_lines(profile.get("prompt_rules")),
        "",
        "## 避免",
        "",
        bullet_lines(profile.get("avoid")),
        "",
    ]
    if profile.get("user_note"):
        lines.extend(["## 用户补充", "", str(profile.get("user_note", "")).strip(), ""])
    return "\n".join(lines)


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
    if path.exists():
        return path
    root_relative = Path.cwd() / path
    if root_relative.exists():
        return root_relative
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
        "director_style": "00a_director_style.json",
        "director_style_select": "00a_director_style.json",
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
        "review_decision": "09_review_decision.json",
        "decisions": "09_review_decision.json",
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
