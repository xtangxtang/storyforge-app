#!/usr/bin/env python3
"""Fast storyboard-only verification (no image/video gen): brief -> script ->
beat-based storyboard, then print each beat so we can confirm continuous actions
are merged into a single beat (one continuous clip)."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_pipeline_ark import (llm, parse_json, norm_obj, log,
                              BRIEF_SYS, SCRIPT_SYS, SB_SYS, CREATIVE)

def main():
    log("===== 分镜验证 (仅 LLM, 不出图/视频) =====")
    log("[1/3] 策划")
    brief = norm_obj(parse_json(llm(BRIEF_SYS, "创意:"+CREATIVE, 0.8, "brief")))
    log(f"   {brief.get('genre')} {brief.get('duration')}s")
    log("[2/3] 编剧")
    scenes = []; assets = []; chars = []
    for attempt in range(4):
        script = norm_obj(parse_json(llm(SCRIPT_SYS, "创意:"+CREATIVE, 0.8, "script")))
        scenes = script.get("scenes", []); assets = script.get("assets", [])
        chars = [a["name"] for a in assets if a.get("type") == "character"]
        if chars: break
        log(f"   script 无角色,重试 {attempt+1}")
    log(f"   场景{len(scenes)} 角色{chars}")
    log("[3/3] 分镜 (beat-based)")
    sb = norm_obj(parse_json(llm(SB_SYS, "剧本:"+json.dumps(script, ensure_ascii=False), 0.3, "storyboard")), "storyboards")
    shots = sorted(sb.get("storyboards", []), key=lambda s: ((s.get('scene_num') or 0), (s.get('shot_num') or 0)))
    log(f"\n   ===== 共 {len(shots)} 个 beat =====")
    for i, s in enumerate(shots, 1):
        log(f"\n--- beat {i}  S{s.get('scene_num')}-{s.get('shot_num')}  "
            f"连续运镜={s.get('continuous_camera')}  时长={s.get('duration')}s ---")
        log(f"  出场角色: {s.get('characters')}")
        log(f"  景别/运镜: {s.get('shot_type')} / {s.get('camera_move')}")
        log(f"  描述: {s.get('description')}")
        log(f"  视频提示: {s.get('video_prompt')}")
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generated")
    os.makedirs(out, exist_ok=True)
    json.dump({"brief": brief, "script": script, "shots": shots},
              open(os.path.join(out, "storyboard_test.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    log(f"\n===== 已保存 -> {os.path.join(out, 'storyboard_test.json')} =====")

if __name__ == "__main__":
    main()
