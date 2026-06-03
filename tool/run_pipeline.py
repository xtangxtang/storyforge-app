#!/usr/bin/env python3
"""Full Storyforge pipeline, end-to-end, on the real backends.

Faithfully mirrors lib/core/agents.dart + the new continuity logic:
  qwen3.6-plus (brief -> script -> storyboard, verbatim system prompts)
    -> clean style-locked asset sheets (ComfyUI t2i, Qwen-Image)
    -> per-shot keyframes pulling ONLY the references present in the shot
       (Qwen-Image-Edit-2509, <=3 refs)  -> i2v video (Wan2.2-TI2V-5B)

LLM goes through the corporate proxy with TLS verification disabled (Fortinet
SSL inspection); ComfyUI is reached directly. Key is read from $LLM_KEY.
"""
import json, os, re, sys, time, random, ssl, io, uuid, urllib.request, urllib.parse

LLM_BASE = "https://coding.dashscope.aliyuncs.com/v1"
LLM_MODEL = "qwen3.6-plus"
LLM_KEY = os.environ["LLM_KEY"]
PROXY = "http://proxy-jf.intel.com:914"
COMFY = "http://172.16.116.208:8188"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pipeline_out")
os.makedirs(OUT, exist_ok=True)

# LLM opener: via proxy, TLS verification off (corporate MITM). ComfyUI: direct.
_noverify = ssl.create_default_context(); _noverify.check_hostname = False
_noverify.verify_mode = ssl.CERT_NONE
llm_opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({"https": PROXY, "http": PROXY}),
    urllib.request.HTTPSHandler(context=_noverify))
comfy_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# ----- generation models / nodes (identical to comfyui_service.dart) -----
QWEN_CLIP="qwen_2.5_vl_7b_fp8_scaled.safetensors"; QWEN_VAE="qwen_image_vae.safetensors"
QWEN_IMG="qwen_image_2512_fp8_e4m3fn.safetensors"
QWEN_EDIT="qwen_image_edit_2509_fp8_e4m3fn.safetensors"
WAN_CLIP="umt5_xxl_fp8_e4m3fn_scaled.safetensors"; WAN_VAE="wan2.2_vae.safetensors"
WAN_VIDEO="wan2.2_ti2v_5B_fp16.safetensors"
NEG_IMG="blurry, low quality, distorted, watermark, text, deformed face, extra limbs"
NEG_VID="static, blurry, distorted, low quality, watermark"

def log(m): print(m, flush=True)
def seed(): return random.randint(0, 0x7FFFFFFF)

# ============================ LLM ============================
def llm_chat(system, user, temperature, tag):
    body = json.dumps({"model": LLM_MODEL, "temperature": temperature,
        "response_format": {"type": "json_object"},
        "messages": [{"role":"system","content":system},
                     {"role":"user","content":user}]}).encode()
    req = urllib.request.Request(LLM_BASE + "/chat/completions", data=body,
        headers={"Authorization": f"Bearer {LLM_KEY}", "Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(llm_opener.open(req, timeout=180))
    content = r["choices"][0]["message"]["content"]
    log(f"   [LLM {tag} {time.time()-t0:.0f}s]")
    return content

def parse_json(s):
    s = s.strip()
    s = re.sub(r"^```(json)?", "", s).strip()
    s = re.sub(r"```$", "", s).strip()
    try:
        return json.loads(s)
    except Exception:
        m = re.search(r"[\{\[].*[\}\]]", s, re.S)
        return json.loads(m.group(0))

BRIEF_SYS = """你是专业的影视策划人。根据用户的创意描述，生成一个短剧项目的 Brief。

要求输出严格的 JSON 格式，不要任何多余的文字：
{
  "genre": "类型（romance/thriller/sci-fi/daily/comedy）",
  "duration": 目标时长（秒，30-120之间）,
  "aspect_ratio": "画面比例（9:16 或 16:9）",
  "mood": "情绪基调",
  "visual_style": "视觉风格描述（中文）",
  "story_outline": "故事大纲（200字以内，中文）"
}

默认：竖屏 9:16，时长 60-90 秒，面向手机短视频。"""

SCRIPT_SYS = """你是专业影视编剧。根据创意编写短剧剧本，必须输出严格 JSON 格式，不要任何多余文字。

JSON 结构必须完全匹配：
{
  "scenes": [
    {"scene_num": 1, "location": "场景名称", "description": "场景描述（中文）",
     "action": "角色动作（中文）", "dialogue": ["台词1"], "duration": 15}
  ],
  "assets": [
    {"type": "character", "name": "角色名称", "description": "角色视觉描述（中文，详细外貌、服装、发型）"},
    {"type": "location", "name": "场景名称", "description": "场景视觉描述（中文，环境、光线、色调）"},
    {"type": "prop", "name": "道具名称", "description": "道具视觉描述（中文，外观、材质、颜色）"}
  ]
}

要求：
- 2-5 个场景，总时长匹配目标时长
- 提取所有角色(character)、场景(location)和关键道具(prop)作为 assets
- 所有 description 必须用中文，详细描述用于 AI 图像生成
- 角色描述必须明确外貌/服装/发型；场景描述必须含光线色调；道具描述必须含材质颜色"""

# Storyboard system prompt — includes the new 角色点名硬规则.
STORYBOARD_SYS = """你是专业分镜师。根据提供的剧本文本制作分镜脚本，必须输出严格 JSON 格式，不要任何多余文字。

【最高优先级规则】
1. 场景数量、scene_num 必须与剧本一一对应，不得增减。
2. 角色绝对忠于剧本：用剧本同样的角色名字，不改性别，不加新角色。
3. 剧情绝对忠于剧本：不加新事件，不改地点。
4. 每个场景 2-3 个镜头。

JSON 结构必须完全匹配：
{
  "storyboards": [
    {"scene_num":1,"shot_num":1,"shot_type":"close-up","camera_move":"static",
     "description":"分镜画面描述（中文，忠实反映剧本动作）",
     "first_frame_prompt":"首帧图生成提示词（中文，五个维度：[主体描述][细节描述][背景描述][光影描述][情绪描述]）",
     "video_prompt":"视频生成提示词（中文，运镜、动作、环境变化）","duration":8}
  ]
}

要求：
- shot_type: close-up/medium/wide/extreme-close-up；camera_move: static/pan/zoom/tilt/dolly
- first_frame_prompt 五个维度都要有实质内容

【角色点名硬规则 — 用于跨镜头一致性，必须遵守】
- 每个镜头的 description 和 first_frame_prompt 的[主体描述]里，必须用剧本中的角色原名逐一点出本镜头画面内实际出现的角色，禁止用"他""她""一个男生"等模糊指代。
- 如果某镜头没有任何角色，必须在 first_frame_prompt 开头写"【无人物】"。
- 不要点出画面中并不出现的角色；点名必须与画面严格一致。

【镜头连续性】同一 scene 内相邻 shot 必须衔接，保持人物服装、朝向、场景方位一致。"""

def format_script(brief, script):
    b = StringBuf()
    chars=[a for a in script["assets"] if a.get("type")=="character"]
    locs=[a for a in script["assets"] if a.get("type")=="location"]
    props=[a for a in script["assets"] if a.get("type")=="prop"]
    b.w("=== 剧本 ===\n")
    if chars:
        b.w("【角色列表】（分镜中只能出现这些角色）")
        for c in chars: b.w(f"- 名字：{c['name']}，描述：{c['description']}")
    if locs:
        b.w("【场景地点】")
        for l in locs: b.w(f"- 地点：{l['name']}，描述：{l['description']}")
    if props:
        b.w("【关键道具】")
        for p in props: b.w(f"- 名称：{p['name']}，描述：{p['description']}")
    b.w(f"\n【场景清单】共 {len(script['scenes'])} 个场景：")
    for s in script["scenes"]:
        b.w(f"场景 {s.get('scene_num')}：地点：{s.get('location','')}；"
            f"描述：{s.get('description','')}；动作：{s.get('action','')}；"
            f"台词：{'；'.join(s.get('dialogue',[]) or [])}")
    return str(b)

class StringBuf:
    def __init__(self): self.lines=[]
    def w(self,s): self.lines.append(s)
    def __str__(self): return "\n".join(self.lines)

# ============================ ComfyUI ============================
def cpost(p,o):
    r=urllib.request.Request(COMFY+p,data=json.dumps(o).encode(),headers={"Content-Type":"application/json"})
    return json.load(comfy_opener.open(r,timeout=60))
def cgetj(p): return json.load(comfy_opener.open(COMFY+p,timeout=30))
def cgetb(u): return comfy_opener.open(u,timeout=180).read()
def cupload(b,name):
    bnd="----sf"+uuid.uuid4().hex; body=io.BytesIO()
    w=lambda s: body.write(s if isinstance(s,bytes) else s.encode())
    w(f"--{bnd}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n")
    w(f"--{bnd}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n")
    w("Content-Type: image/png\r\n\r\n"); w(b); w("\r\n"); w(f"--{bnd}--\r\n")
    r=urllib.request.Request(COMFY+"/upload/image",data=body.getvalue(),
        headers={"Content-Type":f"multipart/form-data; boundary={bnd}"})
    j=json.load(comfy_opener.open(r,timeout=120)); n,s=j["name"],j.get("subfolder","")
    return f"{s}/{n}" if s else n
def vurl(it): return COMFY+"/view?"+urllib.parse.urlencode({"filename":it["filename"],
    "subfolder":it.get("subfolder",""),"type":it.get("type","output")})
def crun(wf,timeout,keys):
    pid=cpost("/prompt",{"prompt":wf,"client_id":f"sf_{int(time.time()*1e6)}"})["prompt_id"]
    end=time.time()+timeout
    while time.time()<end:
        time.sleep(2)
        try: h=cgetj(f"/history/{pid}")
        except Exception: continue
        e=h.get(pid)
        if not isinstance(e,dict): continue
        st=e.get("status",{})
        if st.get("status_str")=="error": raise RuntimeError(json.dumps(st.get("messages"))[:500])
        outs=e.get("outputs")
        if isinstance(outs,dict) and outs:
            for nd in outs.values():
                for k in keys:
                    arr=nd.get(k)
                    if isinstance(arr,list) and arr and arr[0].get("filename"): return vurl(arr[0])
            raise RuntimeError("no output")
    raise RuntimeError("timeout")

def clean(s, n=1200):
    s=re.sub(r"\s+"," ",s).strip(); return s[:n]

def with_style(style, prompt):
    if not style.strip(): return prompt
    return f"【全局视觉风格锁 — 时代、画质、色调、光线、胶片质感必须统一】{style}。{prompt}"

def t2i(prompt):
    wf={"1":{"class_type":"UNETLoader","inputs":{"unet_name":QWEN_IMG,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":QWEN_CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":QWEN_VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":prompt,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG_IMG,"clip":["2",0]}},
        "6":{"class_type":"EmptySD3LatentImage","inputs":{"width":768,"height":1024,"batch_size":1}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.1}},
        "8":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":seed(),"steps":20,"cfg":2.5,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["6",0],"denoise":1.0}},
        "9":{"class_type":"VAEDecode","inputs":{"samples":["8",0],"vae":["3",0]}},
        "10":{"class_type":"SaveImage","inputs":{"images":["9",0],"filename_prefix":"sf_sheet"}}}
    return crun(wf,300,["images"])

def edit(prompt, ref_names):
    wf={"1":{"class_type":"UNETLoader","inputs":{"unet_name":QWEN_EDIT,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":QWEN_CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":QWEN_VAE}},
        "5":{"class_type":"TextEncodeQwenImageEditPlus","inputs":{"clip":["2",0],"prompt":NEG_IMG}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.0}},
        "8":{"class_type":"EmptySD3LatentImage","inputs":{"width":768,"height":1024,"batch_size":1}},
        "9":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":seed(),"steps":20,"cfg":2.5,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["8",0],"denoise":1.0}},
        "10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["3",0]}},
        "11":{"class_type":"SaveImage","inputs":{"images":["10",0],"filename_prefix":"sf_shot"}}}
    pos={"clip":["2",0],"prompt":prompt,"vae":["3",0]}
    for i,nm in enumerate(ref_names[:3]):
        lid=str(20+i); wf[lid]={"class_type":"LoadImage","inputs":{"image":nm}}
        pos[f"image{i+1}"]=[lid,0]
    wf["4"]={"class_type":"TextEncodeQwenImageEditPlus","inputs":pos}
    return crun(wf,300,["images"])

def i2v(prompt, img, length):
    wf={"1":{"class_type":"UNETLoader","inputs":{"unet_name":WAN_VIDEO,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":WAN_CLIP,"type":"wan"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":WAN_VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":prompt,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG_VID,"clip":["2",0]}},
        "6":{"class_type":"LoadImage","inputs":{"image":img}},
        "7":{"class_type":"Wan22ImageToVideoLatent","inputs":{"vae":["3",0],"width":768,"height":1024,
              "length":length,"batch_size":1,"start_image":["6",0]}},
        "8":{"class_type":"ModelSamplingSD3","inputs":{"model":["1",0],"shift":8.0}},
        "9":{"class_type":"KSampler","inputs":{"model":["8",0],"seed":seed(),"steps":20,"cfg":5.0,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["7",0],"denoise":1.0}},
        "10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["3",0]}},
        "11":{"class_type":"CreateVideo","inputs":{"images":["10",0],"fps":24.0}},
        "12":{"class_type":"SaveVideo","inputs":{"video":["11",0],"filename_prefix":"sf_clip",
              "format":"mp4","codec":"h264"}}}
    return crun(wf,900,["images","gifs","videos"])

def save(url, fn, opener=comfy_opener):
    open(os.path.join(OUT,fn),"wb").write(opener.open(url,timeout=180).read()); return fn

# ============================ pipeline ============================
CREATIVE = """整个故事发生在2000年的江南小镇。茅盾中学门口外，万里无云的大晴天，九月一号开学当天，桐乡依旧很热，每个人都汗如雨下。人们陆续赶来学校。陈振飞骑着自行车飞驰，因为还有一分钟就要九点了，不想开学第一天迟到。他嘴里叼着半个包子用力蹬脚踏板。由于骑得太快没刹住车，跟迎面而来睡眼惺忪的俞墨凡撞了个满怀，包子飞了出去。陈振飞心里一凉：没事吧同学，我骑得太快了，太对不起了，我扶你起来。俞墨凡只是平静地拍了拍裤子上的土，淡淡地说：没事。然后头也不回捡起书包走进大门。陈振飞呆在原地，直到九点铃响第一遍才回过神，匆忙把车停门口往校内跑。此时周瑞在二楼教室内，望着窗外跑进教室的陈振飞，嘴角一直笑着。"""

def char_names(assets): return [a["name"] for a in assets if a.get("type")=="character"]
def chars_in_shot(names, text): return [n for n in names if n and n in text]

def select_refs(reg, char_names_list, loc_by_name, loc_list, prop_by_name, prop_names, shot_text):
    out=[]
    def add(u):
        if u and u not in out and len(out)<3: out.append(u)
    for n in chars_in_shot(char_names_list, shot_text):
        add(reg.get(n))
    # location: matched by name else first
    locimg=None
    for ln,iu in loc_by_name.items():
        if ln in shot_text: locimg=iu; break
    if not locimg and loc_list: locimg=loc_list[0]
    add(locimg)
    for pn in prop_names:
        if pn in shot_text: add(prop_by_name.get(pn))
    return out

def main():
    log("================ Storyforge 完整流水线（真实 LLM + ComfyUI）================")
    log("[阶段1/5] 策划 PlanningAgent -> Brief")
    brief = parse_json(llm_chat(BRIEF_SYS, f"请为以下创意生成 Brief：{CREATIVE}", 0.8, "brief"))
    log(f"   genre={brief.get('genre')} duration={brief.get('duration')} mood={brief.get('mood')}")
    log(f"   visual_style={brief.get('visual_style')}")

    log("[阶段2/5] 编剧 ScriptAgent -> 剧本+资产")
    bt=f"Brief: genre={brief.get('genre')}, mood={brief.get('mood')}, story={brief.get('story_outline')}, style={brief.get('visual_style')}"
    script = parse_json(llm_chat(SCRIPT_SYS, f"根据以下创意编写剧本：{CREATIVE}\n{bt}", 0.8, "script"))
    assets=script.get("assets",[]); scenes=script.get("scenes",[])
    log(f"   场景数={len(scenes)} 资产数={len(assets)} "
        f"(角色{sum(1 for a in assets if a['type']=='character')}/"
        f"场景{sum(1 for a in assets if a['type']=='location')}/"
        f"道具{sum(1 for a in assets if a['type']=='prop')})")

    log("[阶段3/5] 分镜 ProductionAgent -> storyboards")
    sb = parse_json(llm_chat(STORYBOARD_SYS,
        f"请根据以下剧本制作分镜，严格按剧本场景/角色/剧情，不得自创。\n\n{format_script(brief, script)}",
        0.3, "storyboard"))
    shots=sb.get("storyboards",[])
    shots.sort(key=lambda s:((s.get('scene_num') or 0),(s.get('shot_num') or 0)))
    log(f"   分镜数={len(shots)}")
    for s in shots: log(f"     S{s.get('scene_num')}-{s.get('shot_num')} {s.get('shot_type')}: {clean(s.get('description',''),60)}")

    if len(sys.argv)>1 and sys.argv[1]=="llm":
        log("(llm-only 冒烟测试，跳过出图出视频)")
        return

    style = "；".join([x for x in [brief.get('visual_style','').strip(),
                                   ('情绪基调：'+brief.get('mood','').strip()) if brief.get('mood') else ''] if x])

    log("[阶段4/5] 资产设计 AssetDesignAgent -> 风格锁干净设定图")
    reg={}; loc_by_name={}; loc_list=[]; prop_by_name={}
    cnames=char_names(assets); pnames=[a["name"] for a in assets if a.get("type")=="prop"]
    for a in assets:
        typ=a.get("type"); name=a.get("name","").strip(); desc=a.get("description","")
        if not name: continue
        if typ=="character":
            p=f"[角色设计参考图] 单个角色全身正面、纯色中性背景、不要其他人物、均匀光照、五官清晰。角色描述：{desc}"
        elif typ=="location":
            p=f"[场景设计参考图/空镜] 画面中不要出现任何角色，重点表现建筑、空间、光线色调。场景描述：{desc}"
        elif typ=="prop":
            p=f"[道具设计参考图] 道具居中、纯色背景、清晰展示外形材质。道具描述：{desc}"
        else: p=desc
        try:
            t0=time.time(); url=t2i(with_style(style, clean(p)))
            fn=save(url, f"sheet_{typ}_{name}.png")
            up=cupload(cgetb(url), f"ref_{uuid.uuid4().hex}.png")
            if typ=="character": reg[name]=up
            elif typ=="location": loc_by_name[name]=up; loc_list.append(up)
            elif typ=="prop": prop_by_name[name]=up
            log(f"   [{time.time()-t0:.0f}s] {typ} {name} -> {fn}")
        except Exception as e:
            log(f"   !! 资产 {name} 失败: {e}")

    log("[阶段5/5] 视频 VideoAgent -> 逐镜头关键帧 + i2v 视频")
    manifest=[]
    for i,s in enumerate(shots,1):
        scene=s.get('scene_num'); shot=s.get('shot_num')
        ffp=s.get('first_frame_prompt',''); vp=s.get('video_prompt','')
        desc=s.get('description',''); shot_text=f"{desc}\n{ffp}\n{vp}"
        present=chars_in_shot(cnames, shot_text)
        refs=select_refs(reg,cnames,loc_by_name,loc_list,prop_by_name,pnames,shot_text)
        # enhanced keyframe prompt (present chars only)
        cd="；".join(f"{n}:{next((a['description'] for a in assets if a['name']==n),'')}" for n in present)
        kp=clean((f"[本镜头出场角色（仅限）]{cd} " if cd else "")+f"[镜头画面]{desc} [详细]{ffp}")
        try:
            t0=time.time(); kurl=edit(with_style(style,kp), refs)
            kfn=save(kurl, f"shot{i:02d}_s{scene}_sh{shot}_kf.png")
            log(f"   关键帧 S{scene}-{shot} 出场[{'+'.join(present) or '无人物'}] refs={len(refs)} "
                f"[{time.time()-t0:.0f}s] -> {kfn}")
            up=cupload(cgetb(kurl), f"kf_{uuid.uuid4().hex}.png")
            dur=s.get('duration') or 4
            length=min(max(int(dur)*24+1, 25), 121)
            t0=time.time(); vurl_=i2v(with_style(style, clean(vp or desc)), up, length)
            vfn=save(vurl_, f"shot{i:02d}_s{scene}_sh{shot}.mp4")
            sz=os.path.getsize(os.path.join(OUT,vfn))
            log(f"   视频   S{scene}-{shot} length={length} [{time.time()-t0:.0f}s] -> {vfn} {sz}B")
            manifest.append({"scene":scene,"shot":shot,"present":present,"refs":len(refs),
                             "keyframe":kfn,"video":vfn,"bytes":sz})
        except Exception as e:
            log(f"   !! 镜头 S{scene}-{shot} 失败: {e}")
            manifest.append({"scene":scene,"shot":shot,"error":str(e)})

    json.dump({"brief":brief,"scenes":scenes,"assets":assets,"shots":shots,"manifest":manifest},
              open(os.path.join(OUT,"manifest.json"),"w",encoding="utf-8"),
              ensure_ascii=False, indent=2)
    ok=sum(1 for m in manifest if m.get("video"))
    log(f"================ DONE: {ok}/{len(shots)} 镜头出片 -> {OUT} ================")

if __name__=="__main__": main()
