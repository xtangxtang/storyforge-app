#!/usr/bin/env python3
"""Generate ONLY beat 1 (the collision) to verify the rendered collision is
physically reasonable and both boys stay in-frame/continuous. Reuses the script
+ beat from generated/storyboard_test.json so it matches the verified storyboard.
"""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_pipeline_ark import (llm, parse_json, norm_obj, log, to_en, seedream,
                              seedance, getb, UNIFORM_SYS, style_lock, OUT)

def main():
    data = json.load(open(os.path.join(OUT, "storyboard_test.json"), encoding="utf-8"))
    brief, script, shots = data["brief"], data["script"], data["shots"]
    chars = [a for a in script.get("assets", []) if a.get("type") == "character"]
    cnames = [c["name"] for c in chars]
    style = style_lock(brief)
    bi = int(os.environ.get("BEAT", "0"))  # which beat index to render
    beat = shots[bi]
    present = [n for n in (beat.get("characters") or []) if n in cnames]
    # Use the storyboard's own video_prompt (now produced by the structured
    # ①~⑥ template) so we test the real template output, not a hand override.
    log(f"===== beat{bi+1} 验证(模板版 video_prompt): 出场 {present} 时长 {beat.get('duration')}s =====")
    log(f"video_prompt: {beat.get('video_prompt','')[:200]}...")

    uniform = norm_obj(parse_json(llm(UNIFORM_SYS, "剧本:"+json.dumps(script, ensure_ascii=False), 0.3, "uniform"))).get("uniform", "").strip()
    log(f"统一校服: {uniform}")

    # character sheets (unified uniform, neutral pose) for the present characters
    sheet_url = {}
    for a in chars:
        if a["name"] not in present: continue
        name, desc = a["name"], a.get("description", "")
        cn = ("男生角色设定图:一名高一男生,单人全身正面直立站立,双臂自然下垂贴身体两侧,中性表情平视镜头,"
              "不做任何动作,不拿任何道具,无座椅无背包,纯中性灰色无缝影棚背景,均匀柔光,全身完整入镜,证件照式标准姿态。")
        if uniform: cn += f"【全校统一校服,必须严格按此,忽略下方描述里任何不同的服装颜色款式】{uniform}。"
        cn += f"【仅保留此角色的个人特征:脸型、发型、眼镜、体型】{desc}"
        if style: cn = style + "。" + cn
        url = seedream(to_en(cn)); sheet_url[name] = url
        open(os.path.join(OUT, f"beat1_sheet_{name}.jpg"), "wb").write(getb(url))
        log(f"   ✓ 设定图 {name}")

    refs = [sheet_url[n] for n in present if n in sheet_url][:3]
    vtext = ((style + "。") if style else "") + beat.get("video_prompt", "")
    dur = min(max(int(beat.get("duration") or 10), 5), 10)
    t0 = time.time()
    vurl = seedance(to_en(vtext), refs, dur)
    out = os.path.join(OUT, f"beat{bi+1}_test.mp4")
    open(out, "wb").write(getb(vurl))
    sz = os.path.getsize(out)
    log(f"===== ✓ beat{bi+1} 出片 [{time.time()-t0:.0f}s] {sz}B -> {out} =====")

if __name__ == "__main__":
    main()
