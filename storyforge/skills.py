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
            if input_data.get("local_agent_review"):
                review = local_review_stage_output(self.ctx, skill_id, result)
            else:
                review = review_stage_output(self.ctx, skill_id, skill.description, result)
            result.data.update(review)
            if should_run_director_guard(skill_id, input_data):
                director_guard = run_director_guard(self.ctx, skill_id, skill.description, result)
                result.data.update(director_guard)
            if should_run_continuity_guard(skill_id, input_data):
                guard = run_continuity_guard(self.ctx, skill_id, skill.description, result)
                result.data.update(guard)
            # 守门 verdict 真正拦截：任一 guard/审阅判 block 时，停在用户审阅门、置 guard_blocked。
            guard_verdicts = [
                result.data.get("director_guard_verdict"),
                result.data.get("continuity_guard_verdict"),
                result.data.get("agent_verdict"),
            ]
            if any(v == "block" for v in guard_verdicts):
                result.data["guard_blocked"] = True
                result.data["awaiting_user_review"] = True
                result.data.setdefault(
                    "guard_block_message",
                    "守门 agent 判定 block：存在必须修复的硬问题，已暂停进入下一阶段。请查看 director/continuity/agent 审阅并修复后再继续。",
                )
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
        try:
            index = self.ctx.workspace.refresh_review_index()
            result.data.setdefault("review_index_file", "review/index.json")
            result.data.setdefault("review_index_markdown", "review/index.md")
            result.data.setdefault("review_next_action", index.get("next_action"))
        except Exception as exc:  # noqa: BLE001 - 审阅索引是辅助产物，不能阻断主流程。
            result.data.setdefault("review_index_error", str(exc))
        return result


DIRECTOR_GUARD_SKILLS = {
    "scene_bible",
    "asset_canon_plan",
    "asset_canon_generate_ark",
    "scene_reference_plan",
    "scene_reference_import",
    "scene_reference_generate_ark",
    "asset_design",
    "storyboard_plan",
    "atomic_shot_plan",
    "keyframe_plan",
    "keyframe_import",
    "keyframe_generate_ark",
    "video_generate_ark",
    "scene_transition_plan",
    "scene_transition_generate_ark",
}


CONTINUITY_GUARD_SKILLS = {
    "consistency_bible",
    "scene_bible",
    "asset_canon_plan",
    "asset_canon_generate_ark",
    "scene_reference_plan",
    "scene_reference_import",
    "scene_reference_generate_ark",
    "cross_scene_continuity",
    "asset_design",
    "storyboard_plan",
    "atomic_shot_plan",
    "keyframe_plan",
    "keyframe_import",
    "keyframe_generate_ark",
    "video_generate_ark",
    "scene_transition_plan",
    "scene_transition_generate_ark",
}


def should_run_director_guard(skill_id: str, input_data: dict[str, Any]) -> bool:
    if input_data.get("skip_director_guard"):
        return False
    return skill_id in DIRECTOR_GUARD_SKILLS


def should_run_continuity_guard(skill_id: str, input_data: dict[str, Any]) -> bool:
    if input_data.get("skip_continuity_guard"):
        return False
    return skill_id in CONTINUITY_GUARD_SKILLS


def run_director_guard(ctx: SkillContext, skill_id: str, description: str, result: SkillResult) -> dict[str, Any]:
    artifact_ref = str(result.data.get("file") or "")
    artifact_text = read_artifact_text(ctx.workspace, artifact_ref)
    if not artifact_text:
        artifact_text = json.dumps({"message": result.message, **result.data}, ensure_ascii=False, indent=2)
    context = director_guard_context(ctx)
    try:
        review = ctx.llm.chat_json(
            "你是 Storyforge 的 director_guard_agent，一名常驻导演审查员。"
            "你在用户看到材料前，从导演角度纠察每个视觉阶段。"
            "输出严格 JSON，字段包括 score(1-10), verdict(approve|revise|block), macro_review, scene_layout_review, "
            "shot_language_review, blocking_review, rhythm_editing_review, performance_review, generation_practicality_review, "
            "blocking_issues, warnings, revision_plan, per_scene_notes, per_shot_notes, user_review_focus。"
            "审查顺序必须从整体到局部：先看全片/大场景布局和叙事重心，再看场面调度、人物进出、机位覆盖、"
            "景别组合、镜头运动、剪辑点、表演节奏，最后看每个分镜或原子镜头是否可拍、是否可生成。"
            "不要替用户重写故事，不要只做连续性检查；连续性由 continuity_guard_agent 负责。"
            "如果审阅对象是 scene_reference_plan、scene_reference_import、scene_reference_generate_ark、storyboard_plan、atomic_shot_plan、keyframe_plan 或后续视觉阶段，必须检查：进入某个大场景正式分镜/关键帧/视频前，是否已经为该 scene_id 建立一整套共同资产包，而不是只生成单张校门或单张角色图。共同资产包至少包含 location_master_plate、必要角色背影 canon、prop_placement_plate、主要 camera_angle_plate，以及该场景需要的动作/状态参考图。"
            "你的重点是导演执行：这个段落是否有建立镜头、主动作镜头、反应镜头、插入特写和转场节奏；"
            "镜头是否重复、是否缺少视觉推进、是否把太多动作塞进一个镜头、是否有不必要的镜头。"
            "如果问题影响成片叙事或镜头调度，写入 blocking_issues 或 revision_plan；如果只是生成风险或备选方案，写入 warnings。"
            "所有字段值必须使用简体中文。",
            (
                f"Skill id: {skill_id}\n"
                f"Skill description: {description}\n"
                f"Result message: {result.message}\n"
                f"Artifact ref: {artifact_ref}\n\n"
                f"Director context:\n{context}\n\n"
                f"Artifact content:\n{review_text_window(artifact_text, limit=70000)}"
            ),
            temperature=0.15,
            tag=f"director_guard:{skill_id}",
        )
        mode = "llm"
    except Exception as exc:  # noqa: BLE001 - director guard is advisory and must not block stage recording.
        review = build_local_director_guard(skill_id, artifact_ref, artifact_text, str(exc))
        mode = "local_fallback"

    guard_path = ctx.workspace.review_dir / f"director_{skill_id}.md"
    write_director_guard_markdown(guard_path, skill_id, artifact_ref, review, mode)
    return {
        "director_guard_file": guard_path.relative_to(ctx.workspace.root).as_posix(),
        "director_guard_verdict": review.get("verdict"),
        "director_guard_score": review.get("score"),
        "director_guard_mode": mode,
    }


def director_guard_context(ctx: SkillContext) -> str:
    parts: list[str] = []
    for name in [
        "00_style.json",
        "00a_director_style.json",
        "01_script.json",
        "00c_scene_bible.json",
        "00d_scene_reference_plan.json",
        "00e_cross_scene_continuity.json",
        "02_assets.json",
        "03_storyboards.json",
        "04_atomic_shots.json",
        "04b_continuity_validation.json",
    ]:
        path = ctx.workspace.stage_path(name)
        if path.exists():
            parts.append(f"---\nsource: stages/{name}\n\n{path.read_text(encoding='utf-8')[:14000]}")
    for name in ["style.md", "director_style.md", "scene_bible.md", "continuity.md", "decisions.md"]:
        path = ctx.workspace.wiki_dir / name
        if path.exists():
            parts.append(f"---\nsource: wiki/{name}\n\n{path.read_text(encoding='utf-8')[:7000]}")
    return "\n\n".join(parts) or "暂无导演上下文。"


def build_local_director_guard(skill_id: str, artifact_ref: str, artifact_text: str, error: str = "") -> dict[str, Any]:
    warnings: list[str] = []
    blocking: list[str] = []
    passed: list[str] = []
    per_scene_notes: list[str] = []
    per_shot_notes: list[str] = []
    try:
        payload = json.loads(artifact_text)
    except json.JSONDecodeError:
        payload = {}
        blocking.append("阶段产物不是合法 JSON，无法进行导演审查。")

    if error:
        warnings.append(f"LLM 导演审查未完成，已使用本地规则兜底：{error}")

    if isinstance(payload, dict):
        if skill_id == "storyboard_plan":
            rows = [row for row in payload.get("storyboards") or [] if isinstance(row, dict)]
            passed.append(f"已检查分镜数量：{len(rows)}。")
            coverage = [str(row.get("coverage_role") or "") for row in rows]
            if rows and not any("建立" in item for item in coverage):
                warnings.append("分镜列表缺少明确建立镜头，观众可能不容易进入空间。")
            if rows and not any("反应" in item for item in coverage):
                warnings.append("分镜列表缺少明确反应镜头，人物情绪转换可能显得生硬。")
            if rows and not any("插入" in item or "特写" in item for item in coverage):
                warnings.append("分镜列表缺少插入特写，道具和动作因果可能不够清楚。")
            scene_counts: dict[str, int] = {}
            for row in rows:
                scene_id = str(row.get("scene_id") or "unknown")
                scene_counts[scene_id] = scene_counts.get(scene_id, 0) + 1
                item_id = row.get("id", "<未命名分镜>")
                if not row.get("dramatic_intent"):
                    warnings.append(f"{item_id} 缺少 dramatic_intent，镜头叙事功能不够明确。")
                if not row.get("camera_design"):
                    warnings.append(f"{item_id} 缺少 camera_design，机位和镜头运动不可执行。")
                if not row.get("blocking"):
                    warnings.append(f"{item_id} 缺少 blocking，人物调度关系不够清楚。")
            per_scene_notes = [f"{scene_id}: {count} 个分镜" for scene_id, count in sorted(scene_counts.items())]
        elif skill_id == "atomic_shot_plan":
            rows = [row for row in payload.get("atomic_shots") or [] if isinstance(row, dict)]
            passed.append(f"已检查原子镜头数量：{len(rows)}。")
            for row in rows:
                item_id = row.get("id", "<未命名原子镜头>")
                duration = int(row.get("duration") or 0)
                prompt = str(row.get("video_prompt") or "")
                if duration and duration < 5:
                    warnings.append(f"{item_id} 时长低于 5 秒，可能不适合当前 Ark 图生视频节奏。")
                if duration and duration <= 5 and prompt.count("，") + prompt.count("、") >= 6:
                    warnings.append(f"{item_id} 在短时长内塞入较多动作，建议拆镜或简化动作重点。")
                shot_design = row.get("shot_design") if isinstance(row.get("shot_design"), dict) else {}
                if not shot_design.get("camera") or not shot_design.get("blocking"):
                    warnings.append(f"{item_id} 的 shot_design 缺少 camera 或 blocking，导演执行信息偏弱。")
                per_shot_notes.append(f"{item_id}: {row.get('purpose', '')}")
        elif skill_id == "keyframe_plan":
            rows = [row for row in payload.get("keyframe_tasks") or [] if isinstance(row, dict)]
            passed.append(f"已检查关键帧任务数量：{len(rows)}。")
            for row in rows:
                item_id = row.get("atomic_shot_id", "<未命名关键帧任务>")
                if not row.get("control_frame_role"):
                    warnings.append(f"{item_id} 缺少 control_frame_role，首帧的导演功能不够明确。")
                if len(str(row.get("first_frame_prompt") or "")) > 2000:
                    warnings.append(f"{item_id} 首帧 prompt 超过 2000 字符，导演重点可能被稀释。")
        elif skill_id in {"scene_bible", "scene_reference_plan"}:
            passed.append("已检查大场景布局/参考图规划产物可读取。")
        elif skill_id in {"keyframe_import", "video_generate_ark", "scene_transition_plan", "scene_transition_generate_ark"}:
            passed.append("已检查媒体或转场阶段产物可读取，具体导演判断需结合生成图像/视频人工复看。")
        else:
            passed.append("本地导演守门已确认阶段产物可读取；详细镜头调度仍建议查看 agent 审阅。")

    verdict = "block" if blocking else "revise" if warnings else "approve"
    score = 4 if blocking else 7 if warnings else 8
    return {
        "score": score,
        "verdict": verdict,
        "macro_review": "本地兜底审查主要检查结构化导演信息是否足够进入下一步。",
        "scene_layout_review": passed,
        "shot_language_review": warnings or "未发现明显镜头语言结构风险。",
        "blocking_review": "已检查 blocking/camera/duration 等字段是否存在。",
        "rhythm_editing_review": "已检查短时长多动作、建立镜头、反应镜头和插入特写的基本覆盖。",
        "performance_review": "表演细节需要结合用户审阅和后续关键帧/视频复看。",
        "generation_practicality_review": "已关注图生视频时长、首帧功能和 prompt 可控性。",
        "blocking_issues": blocking,
        "warnings": warnings,
        "revision_plan": "先修复 blocking_issues；warnings 可根据导演取舍修订。" if blocking or warnings else "无需额外修订，可进入用户审阅。",
        "per_scene_notes": per_scene_notes,
        "per_shot_notes": per_shot_notes,
        "user_review_focus": [
            "这一段是否有清楚的建立镜头、主动作镜头、反应镜头和必要插入特写。",
            "人物进出、站位、视线、运动方向和剪辑点是否像真实可拍的调度。",
            "每个镜头是否有明确叙事功能，是否存在重复镜头或把太多动作塞进一镜的问题。",
        ],
        "artifact": artifact_ref,
    }


def write_director_guard_markdown(path: Path, skill_id: str, artifact_ref: str, review: dict[str, Any], mode: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# 导演守门审查：{skill_id}",
        "",
        f"- artifact: {artifact_ref or 'n/a'}",
        f"- mode: {mode}",
        f"- 评分: {review.get('score')}",
        f"- 结论: {review.get('verdict')}",
        "",
        "## 用户重点复核",
        "",
        bullet_lines(review.get("user_review_focus")),
        "",
        "## 整体布局",
        "",
        bullet_lines(review.get("macro_review")),
        "",
        "## 场面调度",
        "",
        bullet_lines(review.get("blocking_review")),
        "",
        "## 镜头语言",
        "",
        bullet_lines(review.get("shot_language_review")),
        "",
        "## 节奏剪辑",
        "",
        bullet_lines(review.get("rhythm_editing_review")),
        "",
        "## 表演审查",
        "",
        bullet_lines(review.get("performance_review")),
        "",
        "## 生成可执行性",
        "",
        bullet_lines(review.get("generation_practicality_review")),
        "",
        "## 阻塞问题",
        "",
        bullet_lines(review.get("blocking_issues")) or "- 无",
        "",
        "## 风险提醒",
        "",
        bullet_lines(review.get("warnings")) or "- 无",
        "",
        "## 修订建议",
        "",
        bullet_lines(review.get("revision_plan")),
        "",
        "## 原始 JSON",
        "",
        "```json",
        json.dumps(review, ensure_ascii=False, indent=2),
        "```",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def run_continuity_guard(ctx: SkillContext, skill_id: str, description: str, result: SkillResult) -> dict[str, Any]:
    artifact_ref = str(result.data.get("file") or "")
    artifact_text = read_artifact_text(ctx.workspace, artifact_ref)
    if not artifact_text:
        artifact_text = json.dumps({"message": result.message, **result.data}, ensure_ascii=False, indent=2)
    context = continuity_guard_context(ctx)
    try:
        review = ctx.llm.chat_json(
            "你是 Storyforge 的 continuity_guard_agent，一名常驻一致性检查员。"
            "你在每个视觉阶段产出后做轻量审查，正式总审仍由 continuity_validator 完成。"
            "输出严格 JSON，字段包括 score(1-10), verdict(approve|revise|block), blocking_issues, warnings, passed_checks, "
            "revision_plan, per_item_notes, user_review_focus。"
            "审查口径固定为：人物身份与服装、携带物和道具归属、地点结构、光线方向、轴线和运动方向、"
            "动作物理、跨场景状态、首帧/视频生成可控性、字幕水印和中文招牌依赖风险。"
            "还必须检查同一大场景的共同资产包一致性：location_master_plate、角色背影 canon、道具摆放、机位和动作/状态参考图必须继承同一场地共同资产，不得出现校门、教室、楼梯、食堂或球馆结构各自不同。"
            "轻量审查只指出当前 stage 已经暴露的问题，不要改写故事，不要替代导演审美判断。"
            "【边界声明】你只能看到文字/JSON，看不到实际生成的图片；凡涉及像素级一致性（大门/校服/书包颜色是否真的一致），你只能核对 prompt 是否写清了对应 canon 引用与 reference 继承，不得断言图像本身一致，并必须把『需运行 visual_consistency_review 看图复核或人工看图』写进 user_review_focus。"
            "如果只是生成风险而不是硬错误，放入 warnings；只有会导致后续无法稳定生成或与 bible 明显冲突时才 block。"
            "所有字段值必须使用简体中文。",
            (
                f"Skill id: {skill_id}\n"
                f"Skill description: {description}\n"
                f"Result message: {result.message}\n"
                f"Artifact ref: {artifact_ref}\n\n"
                f"Continuity context:\n{context}\n\n"
                f"Artifact content:\n{review_text_window(artifact_text, limit=70000)}"
            ),
            temperature=0.1,
            tag=f"continuity_guard:{skill_id}",
        )
        mode = "llm"
    except Exception as exc:  # noqa: BLE001 - consistency guard is advisory and must not block stage recording.
        review = build_local_continuity_guard(skill_id, artifact_ref, artifact_text, str(exc))
        mode = "local_fallback"

    guard_path = ctx.workspace.review_dir / f"continuity_{skill_id}.md"
    write_continuity_guard_markdown(guard_path, skill_id, artifact_ref, review, mode)
    return {
        "continuity_guard_file": guard_path.relative_to(ctx.workspace.root).as_posix(),
        "continuity_guard_verdict": review.get("verdict"),
        "continuity_guard_score": review.get("score"),
        "continuity_guard_mode": mode,
    }


def continuity_guard_context(ctx: SkillContext) -> str:
    parts: list[str] = []
    for name in [
        "00_style.json",
        "00a_director_style.json",
        "00b_consistency.json",
        "00c_scene_bible.json",
        "00d_scene_references.json",
        "00e_cross_scene_continuity.json",
        "04b_continuity_validation.json",
    ]:
        path = ctx.workspace.stage_path(name)
        if path.exists():
            parts.append(f"---\nsource: stages/{name}\n\n{path.read_text(encoding='utf-8')[:16000]}")
    for name in ["style.md", "director_style.md", "consistency.md", "scene_bible.md", "cross_scene_continuity.md", "continuity.md"]:
        path = ctx.workspace.wiki_dir / name
        if path.exists():
            parts.append(f"---\nsource: wiki/{name}\n\n{path.read_text(encoding='utf-8')[:8000]}")
    return "\n\n".join(parts) or "暂无连续性上下文。"


def build_local_continuity_guard(skill_id: str, artifact_ref: str, artifact_text: str, error: str = "") -> dict[str, Any]:
    warnings: list[str] = []
    blocking: list[str] = []
    passed: list[str] = []
    try:
        payload = json.loads(artifact_text)
    except json.JSONDecodeError:
        payload = {}
        blocking.append("阶段产物不是合法 JSON，无法进行一致性审查。")

    if error:
        warnings.append(f"LLM 一致性审查未完成，已使用本地规则兜底：{error}")

    if isinstance(payload, dict):
        if skill_id == "asset_design":
            rows = payload.get("assets") or []
            passed.append(f"已检查资产锚点数量：{len(rows)}。")
            for row in rows:
                if not isinstance(row, dict):
                    continue
                missing = [key for key in ["name", "visual_anchor_prompt", "negative_prompt", "consistency_notes"] if not row.get(key)]
                if missing:
                    warnings.append(f"资产 {row.get('name', '<未命名>')} 缺少一致性字段：{', '.join(missing)}。")
        elif skill_id == "storyboard_plan":
            rows = payload.get("storyboards") or []
            passed.append(f"已检查分镜数量：{len(rows)}。")
            for row in rows:
                if not isinstance(row, dict):
                    continue
                item_id = row.get("id", "<未命名分镜>")
                for key in ["scene_id", "screen_direction", "first_frame_prompt", "video_prompt"]:
                    if not row.get(key):
                        warnings.append(f"{item_id} 缺少 {key}，后续方向和连续性锁定会变弱。")
                if "九宫格" in json.dumps(row, ensure_ascii=False):
                    warnings.append(f"{item_id} 仍出现九宫格表达，请确认没有回退到多图猜连续性的旧方案。")
        elif skill_id == "atomic_shot_plan":
            rows = payload.get("atomic_shots") or []
            passed.append(f"已检查原子镜头数量：{len(rows)}。")
            for row in rows:
                if not isinstance(row, dict):
                    continue
                item_id = row.get("id", "<未命名原子镜头>")
                if not isinstance(row.get("continuity_state_start"), dict) or not isinstance(row.get("continuity_state_end"), dict):
                    warnings.append(f"{item_id} 的 continuity_state_start/end 不是结构化对象，前后镜头接力会变弱。")
                strategy = row.get("generation_strategy") if isinstance(row.get("generation_strategy"), dict) else {}
                if row.get("render_mode") == "i2v" and strategy.get("reference_assets"):
                    warnings.append(f"{item_id} 是 i2v，但 generation_strategy.reference_assets 不为空，可能触发 Ark 首帧/参考图互斥问题。")
        elif skill_id == "keyframe_plan":
            rows = payload.get("keyframe_tasks") or []
            passed.append(f"已检查关键帧任务数量：{len(rows)}。")
            for row in rows:
                if not isinstance(row, dict):
                    continue
                item_id = row.get("atomic_shot_id", "<未命名关键帧任务>")
                if not row.get("first_frame_prompt"):
                    blocking.append(f"{item_id} 缺少 first_frame_prompt，无法生成受控首帧。")
                if row.get("scene_id") and not row.get("scene_reference_ids"):
                    warnings.append(f"{item_id} 没有关联 scene_reference_ids，请确认是否已有同场景参考图可用。")
                if not row.get("frame_must_not_show"):
                    warnings.append(f"{item_id} 缺少 frame_must_not_show，容易让禁用角色、道具或字幕误入画面。")
        elif skill_id in {"keyframe_import", "scene_reference_import"}:
            missing = payload.get("missing") or []
            if missing:
                blocking.append(f"导入结果仍有缺失文件：{len(missing)} 项。")
            else:
                passed.append("导入文件没有报告缺失项。")
        elif skill_id in {"video_generate_ark", "scene_transition_generate_ark"}:
            failures = payload.get("failures") or payload.get("missing") or []
            if failures:
                warnings.append(f"媒体生成存在失败或缺失项：{len(failures)} 项。")
            else:
                passed.append("媒体生成阶段没有报告失败项。")
        else:
            passed.append("本地一致性守门已确认阶段产物可读取；详细语义仍建议查看 agent 审阅。")

    verdict = "block" if blocking else "revise" if warnings else "approve"
    score = 4 if blocking else 7 if warnings else 8
    return {
        "score": score,
        "verdict": verdict,
        "blocking_issues": blocking,
        "warnings": warnings,
        "passed_checks": passed,
        "revision_plan": "先修复 blocking_issues；warnings 可在进入下一视觉阶段前按风险决定是否修订。" if blocking or warnings else "无需额外修订，可进入用户审阅。",
        "per_item_notes": [],
        "user_review_focus": [
            "人物身份、校服、书包、眼镜、耳机等识别点是否持续一致。",
            "地点结构、光线方向、轴线和人物运动方向是否延续 scene_bible。",
            "道具出现、消失、转移、损坏和归属是否有明确因果。",
        ],
        "artifact": artifact_ref,
    }


def write_continuity_guard_markdown(path: Path, skill_id: str, artifact_ref: str, review: dict[str, Any], mode: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# 一致性守门审查：{skill_id}",
        "",
        f"- artifact: {artifact_ref or 'n/a'}",
        f"- mode: {mode}",
        f"- 评分: {review.get('score')}",
        f"- 结论: {review.get('verdict')}",
        "",
        "## 用户重点复核",
        "",
        bullet_lines(review.get("user_review_focus")),
        "",
        "## 阻塞问题",
        "",
        bullet_lines(review.get("blocking_issues")) or "- 无",
        "",
        "## 风险提醒",
        "",
        bullet_lines(review.get("warnings")) or "- 无",
        "",
        "## 已通过检查",
        "",
        bullet_lines(review.get("passed_checks")) or "- 无",
        "",
        "## 修订建议",
        "",
        bullet_lines(review.get("revision_plan")),
        "",
        "## 原始 JSON",
        "",
        "```json",
        json.dumps(review, ensure_ascii=False, indent=2),
        "```",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def local_review_stage_output(ctx: SkillContext, skill_id: str, result: SkillResult) -> dict[str, Any]:
    artifact_ref = str(result.data.get("file") or "")
    artifact_text = read_artifact_text(ctx.workspace, artifact_ref)
    if not artifact_text:
        artifact_text = json.dumps({"message": result.message, **result.data}, ensure_ascii=False, indent=2)
    review = build_local_stage_review(skill_id, artifact_ref, artifact_text)
    agent_review_path = ctx.workspace.review_dir / f"agent_{skill_id}.md"
    user_review_path = ctx.workspace.review_dir / f"user_{skill_id}.md"
    write_agent_review_markdown(agent_review_path, skill_id, artifact_ref, review)
    write_user_review_package(user_review_path, skill_id, artifact_ref, artifact_text, review)
    return {
        "agent_review_file": agent_review_path.relative_to(ctx.workspace.root).as_posix(),
        "user_review_file": user_review_path.relative_to(ctx.workspace.root).as_posix(),
        "agent_verdict": review.get("verdict"),
        "agent_score": review.get("score"),
        "agent_review_mode": "local",
    }


def build_local_stage_review(skill_id: str, artifact_ref: str, artifact_text: str) -> dict[str, Any]:
    required_asset_fields = {
        "asset_id",
        "type",
        "name",
        "description",
        "story_function",
        "visual_identity",
        "visual_anchor_prompt",
        "negative_prompt",
        "consistency_notes",
        "continuity_invariants",
        "allowed_variations",
        "forbidden_variations",
        "cinematic_usage",
        "generation_anchors",
    }
    risks: list[str] = []
    checks: list[str] = []
    try:
        payload = json.loads(artifact_text)
    except json.JSONDecodeError:
        payload = {}
        risks.append("阶段产物不是合法 JSON，需要先修复文件格式。")

    if skill_id == "asset_design":
        assets = payload.get("assets") if isinstance(payload, dict) else []
        if not isinstance(assets, list) or not assets:
            risks.append("未找到 assets 列表，后续分镜和关键帧无法引用视觉锚点。")
            assets = []
        missing_rows = []
        for asset in assets:
            if not isinstance(asset, dict):
                missing_rows.append("<非对象资产>")
                continue
            missing = sorted(required_asset_fields - set(asset))
            anchors = asset.get("generation_anchors")
            if isinstance(anchors, dict):
                missing += [f"generation_anchors.{key}" for key in ["positive_prompt", "negative_prompt", "reference_priority"] if key not in anchors]
            else:
                missing.append("generation_anchors")
            if missing:
                missing_rows.append(f"{asset.get('name', '<未命名>')}: {', '.join(missing)}")
        checks.append(f"资产数量：{len(assets)}。")
        checks.append("已检查视觉锚点、负向提示词、连续性不变量、可变项/禁变项和生成锚点字段。")
        if missing_rows:
            risks.append("以下资产字段不完整：" + "；".join(missing_rows[:8]))
        if payload.get("generation_mode") == "deterministic_assets":
            checks.append("本阶段使用本地确定性资产锚点生成，适合先建立稳定一致性，再由后续 stage 细化镜头语言。")
    else:
        checks.append("本地审阅已确认阶段产物存在并可读取。")

    verdict = "revise" if risks else "approve"
    score = 7 if risks else 8
    return {
        "score": score,
        "verdict": verdict,
        "strengths": "阶段产物已落盘，并且包含后续流程需要读取的机器可读文件引用。",
        "risks": risks or "未发现阻断性结构问题；仍建议人工重点确认创作取舍是否符合预期。",
        "continuity_checks": checks,
        "director_review": "本地审阅重点检查结构完整性与生产可用性；镜头美学取舍仍留给用户审阅确认。",
        "continuity_review": "已优先检查字段是否能承接 consistency_bible、scene_bible 与 cross_scene_continuity 的连续性要求。",
        "generation_risk_review": "已检查图像/视频生成所需的正向锚点、负向约束和参考优先级是否存在。",
        "concrete_revision_requests": "无硬性修改要求。" if not risks else risks,
        "user_review_focus": [
            "确认每个角色、地点、道具的视觉锚点是否符合你脑中的电影风格。",
            "重点检查各主要角色的校服、书包颜色与归属、发型、眼镜/配饰等识别点是否一致、是否会串脸串衣。",
            "确认复用道具的出现时机和归属关系是否符合剧本。",
            "注意：本地审阅只看文字/JSON，看不到实际生成的图片；大门/校服/道具的视觉一致性需运行 visual_consistency_review 看图复核或人工看图确认。",
        ],
        "knowledge_capture_candidates": "若你认可这版资产锚点，可在后续把“本地确定性资产锚点生成”沉淀为稳定知识卡或默认 skill 行为。",
    }


def review_stage_output(ctx: SkillContext, skill_id: str, description: str, result: SkillResult) -> dict[str, Any]:
    artifact_ref = str(result.data.get("file") or "")
    artifact_text = read_artifact_text(ctx.workspace, artifact_ref)
    if not artifact_text:
        artifact_text = json.dumps({"message": result.message, **result.data}, ensure_ascii=False, indent=2)
    review_artifact_text = review_text_window(artifact_text)

    agent_review_path = ctx.workspace.review_dir / f"agent_{skill_id}.md"
    user_review_path = ctx.workspace.review_dir / f"user_{skill_id}.md"
    knowledge_block = review_knowledge_block(ctx)
    try:
        review = ctx.llm.chat_json(
            "你是 Storyforge 的 stage_review_agent。你要在用户看到材料之前，先审阅一个已经完成的生产阶段。"
            "输出严格 JSON，字段包括 score(1-10), verdict(approve|revise|block), strengths, risks, continuity_checks, "
            "director_review, continuity_review, generation_risk_review, concrete_revision_requests, user_review_focus, knowledge_capture_candidates。"
            "director_review 检查戏剧意图、机位、景别、调度、表演和剪辑价值是否像可拍的影视方案；"
            "continuity_review 检查角色/服装/地点/道具/光线/轴线/运动方向/物理状态是否承接；"
            "generation_risk_review 检查提示词是否能稳定给文生图、图生视频、Ark Seedance 使用，是否存在审核、身份漂移、文字水印、硬接触、动作节拍过载等风险。"
            "判断要直接、面向制片执行，重点检查故事保真、连续性、物理逻辑、prompt 可用性、字段完整性、下一阶段是否有足够信息。"
            "审阅 scene_reference_plan、scene_reference_import、scene_reference_generate_ark、storyboard_plan、atomic_shot_plan、keyframe_plan 或后续视觉阶段时，必须检查“大场景共同资产包先行”：进入某个 scene_id 的正式分镜、关键帧或视频前，是否已经规划/生成/审阅完整共同资产包；如果只生成单张校门、单张角色图就继续关键帧，应判为 revise。"
            "下面提供的【已沉淀制作知识卡】代表经过实测验证的制作决策，优先级高于通用常识：如果产物遵循了这些知识（例如 first-frame-only 首帧驱动、背影/过肩锁方向、不依赖中文招牌文字、单条视频≥5秒），不要把它判成风险或要求改回通用做法；只在产物违背知识卡、或存在知识卡未覆盖的真实问题时才提风险与修改。"
            "所有字段值必须使用简体中文。",
            (
                f"输出语言规则：{CHINESE_OUTPUT_RULE}\n"
                f"Skill id: {skill_id}\n"
                f"Skill description: {description}\n"
                f"Result message: {result.message}\n"
                f"Artifact ref: {artifact_ref}\n\n"
                f"已沉淀制作知识卡（权威，优先于通用常识）：\n{knowledge_block}\n\n"
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


def review_knowledge_block(ctx: SkillContext) -> str:
    """检索项目级 + 全局知识卡，作为审阅 agent 的权威制作知识上下文。"""
    try:
        cards = ctx.workspace.retrieve_knowledge_cards(limit=8)
    except Exception:
        cards = []
    if not cards:
        return "（暂无知识卡）"
    return "\n\n".join(f"[{card['source']}]\n{card['text'][:3000]}" for card in cards)


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
        "## 导演审阅",
        "",
        bullet_lines(review.get("director_review")),
        "",
        "## 连续性审阅",
        "",
        bullet_lines(review.get("continuity_review")),
        "",
        "## 生成风险审阅",
        "",
        bullet_lines(review.get("generation_risk_review")),
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
