#!/usr/bin/env python3
"""Sheets-only test: brief -> script -> unified uniform -> 3 character sheets.
Verifies all characters wear the SAME school uniform in a neutral standing pose."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_pipeline_ark import (llm, parse_json, norm_obj, log, to_en, seedream, getb,
                              BRIEF_SYS, SCRIPT_SYS, UNIFORM_SYS, CREATIVE, style_lock, OUT)

def main():
    log("===== 设定图验证 (统一校服) =====")
    brief = norm_obj(parse_json(llm(BRIEF_SYS, "创意:"+CREATIVE, 0.8, "brief")))
    chars = []
    for attempt in range(4):
        script = norm_obj(parse_json(llm(SCRIPT_SYS, "创意:"+CREATIVE, 0.8, "script")))
        chars = [a for a in script.get("assets", []) if a.get("type") == "character"]
        if chars: break
        log(f"   script 无角色,重试 {attempt+1}")
    uniform = norm_obj(parse_json(llm(UNIFORM_SYS, "剧本:"+json.dumps(script, ensure_ascii=False), 0.3, "uniform"))).get("uniform", "").strip()
    style = style_lock(brief)
    log(f"统一校服: {uniform}")
    for a in chars:
        name, desc = a.get("name", "").strip(), a.get("description", "")
        cn = ("男生角色设定图:一名高一男生,单人全身正面直立站立,双臂自然下垂贴身体两侧,中性表情平视镜头,"
              "不做任何动作,不拿任何道具,无座椅无背包,纯中性灰色无缝影棚背景,均匀柔光,全身完整入镜,证件照式标准姿态。")
        if uniform: cn += f"【全校统一校服,必须严格按此,忽略下方描述里任何不同的服装颜色款式】{uniform}。"
        cn += f"【仅保留此角色的个人特征:脸型、发型、眼镜、体型】{desc}"
        if style: cn = style + "。" + cn
        url = seedream(to_en(cn))
        fn = f"sheet2_character_{name}.jpg"
        open(os.path.join(OUT, fn), "wb").write(getb(url))
        log(f"   ✓ {name} -> {fn}")
    log("===== DONE =====")

if __name__ == "__main__":
    main()
