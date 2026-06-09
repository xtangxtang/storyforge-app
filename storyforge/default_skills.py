from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .document import extract_document_text
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
                "applies_to": ["asset_design", "storyboard_plan", "atomic_shot_plan", "keyframe_plan", "keyframe_generate_ark", "video_generate_ark"],
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


class AssetDesignSkill:
    id = "asset_design"
    description = "为角色、地点和道具设计稳定的视觉锚点与可复用图片提示词。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        assets = list(script.get("assets") or [])
        if not assets:
            return SkillResult(False, "stages/01_script.json 中没有找到 assets", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 asset_design。输出严格 JSON：{assets:[...]}。对每个 asset 保留 type/name/description，并补充 visual_anchor_prompt、negative_prompt、consistency_notes。提示词必须足够具体，便于图片生成；不要海报感、拼贴感或设定集排版；必须保持身份、服装、地点细节在后续镜头中稳定。必须遵守 workspace context 中的 Consistency Bible（consistency.md）：每个 character 的 visual_anchor_prompt 一律穿统一校服（除非 bible 的 fixed_outfits 另有规定），每个 location 一律采用 bible 里该地点的固定布局与方位，复用道具用 bible 的统一外观，绝不各自发明。同时遵守 Style Profile。所有字段值和说明必须使用简体中文。",
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
        out = {"source": self.id, "assets": designed}
        ctx.workspace.write_stage("02_assets.json", out)
        write_review_markdown(ctx.workspace.review_dir / "02_assets.md", "视觉资产设计审阅", out)
        return SkillResult(True, "视觉资产提示词已设计", {"file": "stages/02_assets.json", "count": len(designed)})


class StoryboardPlanSkill:
    id = "storyboard_plan"
    description = "基于结构化剧本和项目记忆生成可审阅的分镜节拍。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        script = ctx.workspace.read_stage("01_script.json")
        if not script.get("scenes"):
            return SkillResult(False, "stages/01_script.json 中没有找到 scenes", {})
        data = ctx.llm.chat_json(
            "你是 Storyforge 的 storyboard_plan。创建严格 JSON：{storyboards:[...]}。每个分镜节拍包含 id, scene_num, shot_num, location, duration(5-10秒), characters, props, description, first_frame_prompt, video_prompt, continuity。必须保留原故事。动作连续、中间没有断点的段落保持为一个连续节拍、不要拆成需要硬切拼接的多条（如骑行→相撞→道歉合为一条）；只在换时间、换地点、换全新机位的真正断点才切镜。方向/进入/相撞类镜头的 first_frame_prompt 用不含清晰真人脸的画面锁方向（无脸背影人物、或场地空镜、或物件特写如自行车前轮），把运动目的地放在画面纵深。每个节拍和 prompt 都必须遵守 workspace context 中的 Consistency Bible（统一校服/地点布局/复用道具）与 Style Profile。所有字段值和说明必须使用简体中文。",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nScript JSON:\n{json.dumps(script, ensure_ascii=False)}",
            temperature=float(input_data.get("temperature", 0.25)),
            tag=self.id,
        )
        storyboards = list(data.get("storyboards") or [])
        for idx, sb in enumerate(storyboards, 1):
            sb.setdefault("id", f"sb_{idx:03d}")
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
            "你是 Storyforge 的 atomic_shot_plan。输出严格 JSON：{atomic_shots:[...]}。每个镜头包含 id, storyboard_id, render_mode(i2v|t2v), duration, purpose, first_frame_prompt, video_prompt, continuity_state_start, continuity_state_end, reference_asset_names。"
            "【拆分】动作连续、中间没有断点的相邻动作合并成一条连续镜（如骑行→相撞→道歉合一条），不要拆成多条再硬切；只在换时间/地点/全新机位、或单条超10秒时才另起一镜。不要过度原子化。"
            "【时长】单条 5-10 秒（下限5上限10），一条连续微场景可用 8-10 秒。"
            "【render_mode】默认 i2v：能做出『严格无脸纯背影/正后方』首帧的镜（相机正对角色后脑勺与后背、目的地在画面纵深）。i2v 审核只查输入首帧、不查输出，所以无脸首帧既过审又锁方向，碰撞/转身/道歉等有脸画面在输出里照常出现。仅当开局就必须是脸、无法做合理无脸首帧的纯对话/情绪特写才用 t2v。"
            "【first_frame_prompt】只需『不含清晰真人脸（过审）+ 锁方向』，三选一用最合适的：①无脸背影/过肩人物（相机正对后脑勺与后背）；②纯场地/建立空镜（人群背影、无主要人物特写）；③物件/局部特写（如自行车前轮、道具）。用相机相对语言把目的地/运动矢量放进画面锁方向（视频里再上摇/推进露出人物）；若有角色出镜补身份锚点（校服拼色、有无眼镜/书包、发型体型）区分同框角色。人脸在输出视频里照常出现。"
            "【video_prompt】i2v 镜写运动与动作；t2v 镜必须自包含因果（主语+动作+场景+因果，不能只写余波）。困难硬接触（相撞/急刹）放在连续镜里、接触靠运动模糊+余波带过；横切来的人从侧巷汇入交汇、不要站路中间被追尾；余波用中近景收（道歉/反应）。所有镜恒含无字幕/无水印约束、不依赖中文招牌逐帧稳定。"
            "reference_asset_names 列该镜在场角色与地点（地点 canon 优先）。相邻镜共享连续状态。所有 prompt 遵守 Consistency Bible（统一校服/地点布局/复用道具不得各自发明）与 Style Profile。所有字段值用简体中文。",
            f"Workspace context:\n{ctx.workspace.context_pack()}\n\nStoryboards:\n{json.dumps(storyboards, ensure_ascii=False)}",
            temperature=0.2,
            tag=self.id,
        )
        atoms = list(data.get("atomic_shots") or [])
        for idx, atom in enumerate(atoms, 1):
            atom.setdefault("id", f"atom_{idx:03d}")
        out = {"source": self.id, "atomic_shots": atoms}
        ctx.workspace.write_stage("04_atomic_shots.json", out)
        write_review_markdown(ctx.workspace.review_dir / "04_atomic_shots.md", "原子镜头审阅", out)
        return SkillResult(True, "原子镜头已生成", {"file": "stages/04_atomic_shots.json", "count": len(atoms)})


class KeyframePlanSkill:
    id = "keyframe_plan"
    description = "为 Codex 图片生成规划每个原子镜头的首帧/尾帧任务。"

    def run(self, ctx: SkillContext, input_data: dict[str, Any]) -> SkillResult:
        atoms = list(ctx.workspace.read_stage("04_atomic_shots.json").get("atomic_shots") or [])
        if not atoms:
            return SkillResult(False, "没有找到 atomic_shots", {})
        asset_context = load_asset_context(ctx)
        style_context = load_style_context(ctx)
        tasks = []
        for atom in atoms:
            atom_id = str(atom.get("id"))
            named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
            first_path = Path("keyframes") / f"{safe_name(atom_id)}_first.png"
            raw_last = str(atom.get("last_frame_prompt", "")).strip()
            task = {
                "atomic_shot_id": atom_id,
                "storyboard_id": atom.get("storyboard_id"),
                "duration": atom.get("duration", 5),
                "video_prompt": atom.get("video_prompt", ""),
                "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context),
                "first_frame_local_path": first_path.as_posix(),
                "frame_mode": "first_last" if raw_last else "first_frame_only",
                "render_mode": atom.get("render_mode", "i2v"),
                "reference_asset_names": atom.get("reference_asset_names", []),
                "status": "needs_codex_image_generation",
            }
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
                "asset_reference": "stages/02_assets.json",
                "prompt_budget_chars": 800,
                "frame_policy": "默认 first-frame-only 锁方向；仅困难接触/到达镜才规划 last_frame 任务。",
                "rule": "每条首帧 prompt 只保留镜头画面、核心动作、物理/方向/光影约束；完整风格和资产锚点由全局引用提供。",
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
                    "duration": row.get("duration", 5),
                    "video_prompt": row.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "last_frame_local_path": str(last_path) if has_last else "",
                    "frame_mode": "first_last" if has_last else "first_frame_only",
                    "image_provider": "codex",
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
        asset_types = {n: str(a.get("type") or "") for n, a in load_asset_context(ctx).items()}
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
            refs = [anchors[n] for n in names if anchors.get(n)]
            if not refs:
                refs = continuity_reference_urls(task_order, existing, atom_id)
            # 纯建立/环境镜（只引用地点、没有角色）：直接用该地点 canon 当首帧，零漂移、质量有保证，不再重新生成。
            loc_names = [n for n in names if asset_types.get(n) == "location" and anchors.get(n)]
            char_names = [n for n in names if asset_types.get(n) == "character"]
            canon_direct_url = anchors[loc_names[0]] if (loc_names and not char_names) else ""
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
                    "duration": task.get("duration", 5),
                    "video_prompt": task.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "image_provider": "ark",
                    "frame_mode": "first_frame_only",
                    "render_mode": render_mode,
                    "reference_asset_names": list(names),
                    "state": "ready",
                }
                continue
            try:
                if canon_direct_url:
                    first_url = canon_direct_url
                    ctx.ark.download(first_url, first_path)  # 把该地点 canon 图直接复制为本镜首帧
                else:
                    first_url = ctx.ark.generate_image(ark_image_prompt(str(task.get("first_frame_prompt", ""))), refs=refs)
                    ctx.ark.download(first_url, first_path)
                generated += 1
                existing[atom_id] = {
                    "atomic_shot_id": atom_id,
                    "storyboard_id": task.get("storyboard_id"),
                    "duration": task.get("duration", 5),
                    "video_prompt": task.get("video_prompt", ""),
                    "first_frame_url": first_url,
                    "first_frame_local_path": str(first_path),
                    "image_provider": "ark",
                    "frame_mode": "first_frame_only",
                    "render_mode": render_mode,
                    "reference_asset_names": list(names),
                    "first_frame_source": "canon" if canon_direct_url else "generated",
                    "state": "ready",
                }
            except Exception as exc:
                failed += 1
                existing[atom_id] = {
                    **current,
                    "atomic_shot_id": atom_id,
                    "storyboard_id": task.get("storyboard_id"),
                    "duration": task.get("duration", 5),
                    "video_prompt": task.get("video_prompt", ""),
                    "first_frame_local_path": str(first_path),
                    "image_provider": "ark",
                    "frame_mode": "first_frame_only",
                    "render_mode": render_mode,
                    "reference_asset_names": list(names),
                    "state": "failed",
                    "error": str(exc),
                }

        keyframes = [existing[str(task.get("atomic_shot_id"))] for task in tasks if str(task.get("atomic_shot_id")) in existing]
        out = {
            "source": self.id,
            "image_provider": "ark",
            "mode": "first_frame_only",
            "anchors": anchors,
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
    tasks = []
    for atom in atoms:
        atom_id = str(atom.get("id"))
        named_assets = [asset_context[n] for n in atom.get("reference_asset_names", []) if n in asset_context]
        first_path = Path("keyframes") / f"{safe_name(atom_id)}_first.png"
        raw_last = str(atom.get("last_frame_prompt", "")).strip()
        task = {
            "atomic_shot_id": atom_id,
            "storyboard_id": atom.get("storyboard_id"),
            "duration": atom.get("duration", 5),
            "video_prompt": atom.get("video_prompt", ""),
            "first_frame_prompt": frame_prompt(str(atom.get("first_frame_prompt", "")), named_assets, style_context),
            "first_frame_local_path": first_path.as_posix(),
            "frame_mode": "first_last" if raw_last else "first_frame_only",
            "render_mode": atom.get("render_mode", "i2v"),
            "reference_asset_names": atom.get("reference_asset_names", []),
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
    已有 reference_image_url 的跳过，便于断点续跑复用。返回 name -> url。"""
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
        if asset.get("reference_image_url"):
            anchors[name] = str(asset["reference_image_url"])
            continue
        url = ctx.ark.generate_image(anchor_prompt(asset, style_context, uniform=uniform, layout=str(layouts.get(name) or "")))
        path = ctx.ark.download(url, ctx.workspace.assets_dir / f"{safe_name(name)}.png")
        asset["reference_image_url"] = url
        asset["reference_image_local_path"] = str(path)
        anchors[name] = url
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
            f"{name} 的统一基准空镜（canon base），电影写实风格，竖屏9:16；"
            "完整交代地点结构与陈设，统一校服的学生三三两两、彼此拉开自然间距地背对镜头朝场景纵深方向"
            "（自然分散、不拥挤、不聚堆成团、不排队列队），无主要人物特写、不依赖文字招牌、无海报无拼贴。"
        )
    elif asset_type == "character":
        framing = (
            f"{name} 的角色定妆参考图（character sheet），单人、全身、正面、中性自然站姿、"
            "纯净浅灰摄影棚背景、均匀柔光，写实电影质感，无文字、无海报、无拼贴。"
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


def t2v_reference_urls(kf: dict[str, Any], asset_context: dict[str, dict[str, Any]]) -> list[str]:
    """t2v 镜的 reference_image，按优先级截断（cap 3）：无脸背影方向首帧 + 地点 canon + 在场角色定妆图，道具靠后。
    无脸背影首帧用来给 t2v『带』方向与构图，canon/定妆图维持场景与身份。"""
    refs: list[str] = []
    back_view = str(kf.get("first_frame_url") or kf.get("first_frame_local_path") or "").strip()
    if back_view:
        refs.append(back_view)
    names = kf.get("reference_asset_names") or []
    for want in ("location", "character", "prop"):
        for n in names:
            asset = asset_context.get(n) or {}
            if str(asset.get("type")) != want:
                continue
            url = str(asset.get("reference_image_url") or "").strip()
            if url and url not in refs:
                refs.append(url)
    return refs[:3]


def continuity_reference_urls(task_order: list[str], existing: dict[str, dict[str, Any]], atom_id: str) -> list[str]:
    """取最近一个已生成成功镜头的首帧作参考图，给后一镜首帧做跨镜连续性。
    只喂给图片生成（首帧→首帧有助一致性），绝不喂给视频生成（参考图会带歪视频方向）。"""
    if atom_id not in task_order:
        return []
    index = task_order.index(atom_id)
    for previous_id in reversed(task_order[:index]):
        previous = existing.get(previous_id) or {}
        if previous.get("state") != "ready":
            continue
        url = str(previous.get("first_frame_url") or "").strip()
        if url:
            return [url]
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
        for kf in keyframes:
            try:
                render_mode = str(kf.get("render_mode") or "i2v")
                prompt = video_prompt_with_style(str(kf.get("video_prompt", "")), style_context)
                dur = int(kf.get("duration") or 5)
                if render_mode == "t2v":
                    # 露脸/对话镜：纯文生视频规避 i2v 真实人脸审核；无脸背影首帧+canon+定妆图作 reference_image 维持方向/场景/身份。
                    url = ctx.ark.generate_video_t2v(prompt, duration=dur, reference_image_urls=t2v_reference_urls(kf, asset_context))
                else:
                    first_frame = str(kf.get("first_frame_url") or kf.get("first_frame_local_path") or "")
                    if not first_frame:
                        raise ValueError(f"{kf.get('atomic_shot_id')} 缺少首帧")
                    url = ctx.ark.generate_video(
                        prompt,
                        first_frame,
                        duration=dur,
                        reference_video_urls=[previous] if (chain_reference_video and previous) else None,
                    )
                previous = url
                local = ctx.ark.download(url, ctx.workspace.clips_dir / f"{safe_name(str(kf.get('atomic_shot_id')))}.mp4")
                clips.append({**kf, "state": "ready", "video_url": url, "video_local_path": str(local)})
            except Exception as exc:
                clips.append({**kf, "state": "failed", "error": str(exc)})
        out = {"source": self.id, "clips": clips, "success": sum(c.get("state") == "ready" for c in clips), "failed": sum(c.get("state") == "failed" for c in clips)}
        ctx.workspace.write_stage("06_videos.json", out)
        write_review_markdown(ctx.workspace.review_dir / "06_videos.md", "视频生成审阅", out)
        return SkillResult(True, "视频生成流程已完成", {"file": "stages/06_videos.json", "success": out["success"], "failed": out["failed"]})


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
        asset_lines.append(asset_prompt_line(asset))
    asset_context = "\n".join(asset_lines)
    asset_names = "、".join(str(asset.get("name", "")).strip() for asset in assets or [] if str(asset.get("name", "")).strip())
    base = (
        "竖屏9:16图生视频控制帧；电影写实风格；无文字、无品牌、无UI、无拼贴。"
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
        "竖屏9:16图生视频控制帧；电影写实风格；无文字、无品牌、无UI、无拼贴。"
        "保持人物身份、服装、道具、地点、运动方向和物理状态连续。"
        "方向用相机相对语言；动作/方向镜用背影或过肩、把运动目的地放在画面纵深；对话镜用过肩、避免贴镜头大正脸。\n"
    )
    if style_context:
        compact_base += f"风格摘要：{compact_style_summary(style_context)}\n"
    compact_base += f"参考锚点：{asset_names}（完整视觉锚点见 stages/02_assets.json）\n"
    return compact_base + prompt


def compact_style_summary(style_context: str) -> str:
    return "电影风格；写实自然表演；克制统一色彩；清晰空间连续性；避免短剧夸张、漫画格、网感字幕。"


def asset_prompt_line(asset: dict[str, Any]) -> str:
    name = str(asset.get("name", "")).strip()
    asset_type = str(asset.get("type", "asset")).strip()
    description = clip_text(str(asset.get("description", "")).strip(), 36)
    consistency = clip_text(str(asset.get("consistency_notes", "")).strip(), 52)
    return f"{asset_type} {name}: {description}；{consistency}"


def clip_text(value: str, limit: int) -> str:
    value = " ".join(value.split())
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 1)].rstrip() + "…"


def video_prompt_with_style(prompt: str, style_context: str = "") -> str:
    prompt = f"{prompt}{CLEAN_FRAME_RULE}"
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
