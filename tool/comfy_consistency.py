#!/usr/bin/env python3
"""Prove the continuity fix: build clean character + location reference sheets
(style-locked), then generate per-shot keyframes that pull ONLY the references
actually present in each shot via Qwen-Image-Edit-2509. Mirrors the new Dart
VideoAgent selection logic on the user's test script (2000 Jiangnan town)."""
import json, sys, time, random, urllib.request, urllib.parse, io, os, uuid, tempfile

BASE = "http://172.16.116.208:8188"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TMP = tempfile.gettempdir()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "consistency_out")
os.makedirs(OUT, exist_ok=True)

QWEN_CLIP="qwen_2.5_vl_7b_fp8_scaled.safetensors"; QWEN_VAE="qwen_image_vae.safetensors"
QWEN_IMG="qwen_image_2512_fp8_e4m3fn.safetensors"
QWEN_EDIT="qwen_image_edit_2509_fp8_e4m3fn.safetensors"
NEG="blurry, low quality, distorted, watermark, text, deformed face, extra limbs"

# Global style lock — injected into EVERY prompt for cross-shot coherence.
STYLE = ("2000年中国江南小镇，初秋九月开学日，晴天暖阳，胶片质感，柔和暖色调，"
         "写实电影摄影，35mm 胶片颗粒，怀旧氛围")

def seed(): return random.randint(0, 0x7FFFFFFF)
def post(p,o):
    r=urllib.request.Request(BASE+p,data=json.dumps(o).encode(),headers={"Content-Type":"application/json"})
    return json.load(opener.open(r,timeout=60))
def getj(p): return json.load(opener.open(BASE+p,timeout=30))
def getb(u): return opener.open(u,timeout=120).read()
def upload(b,name):
    bnd="----sf"+uuid.uuid4().hex; body=io.BytesIO()
    w=lambda s: body.write(s if isinstance(s,bytes) else s.encode())
    w(f"--{bnd}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n")
    w(f"--{bnd}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n")
    w("Content-Type: image/png\r\n\r\n"); w(b); w("\r\n"); w(f"--{bnd}--\r\n")
    r=urllib.request.Request(BASE+"/upload/image",data=body.getvalue(),
        headers={"Content-Type":f"multipart/form-data; boundary={bnd}"})
    j=json.load(opener.open(r,timeout=120)); n,s=j["name"],j.get("subfolder","")
    return f"{s}/{n}" if s else n
def vurl(it):
    return BASE+"/view?"+urllib.parse.urlencode({"filename":it["filename"],
        "subfolder":it.get("subfolder",""),"type":it.get("type","output")})
def run(wf,timeout=300):
    pid=post("/prompt",{"prompt":wf,"client_id":f"sf_{int(time.time()*1e6)}"})["prompt_id"]
    end=time.time()+timeout
    while time.time()<end:
        time.sleep(2)
        try: h=getj(f"/history/{pid}")
        except Exception: continue
        e=h.get(pid)
        if not isinstance(e,dict): continue
        st=e.get("status",{})
        if st.get("status_str")=="error": raise RuntimeError(json.dumps(st.get("messages"))[:600])
        outs=e.get("outputs")
        if isinstance(outs,dict) and outs:
            for nd in outs.values():
                arr=nd.get("images")
                if isinstance(arr,list) and arr and arr[0].get("filename"): return vurl(arr[0])
            raise RuntimeError("no image")
    raise RuntimeError("timeout")

def t2i(prompt):
    p=f"{STYLE}。{prompt}"
    wf={"1":{"class_type":"UNETLoader","inputs":{"unet_name":QWEN_IMG,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":QWEN_CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":QWEN_VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":p,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG,"clip":["2",0]}},
        "6":{"class_type":"EmptySD3LatentImage","inputs":{"width":768,"height":1024,"batch_size":1}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.1}},
        "8":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":seed(),"steps":20,"cfg":2.5,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["6",0],"denoise":1.0}},
        "9":{"class_type":"VAEDecode","inputs":{"samples":["8",0],"vae":["3",0]}},
        "10":{"class_type":"SaveImage","inputs":{"images":["9",0],"filename_prefix":"sf_sheet"}}}
    return run(wf)

def edit(prompt, ref_names):
    """ref_names: list of already-uploaded ComfyUI input image names (<=3)."""
    p=f"{STYLE}。{prompt}"
    wf={"1":{"class_type":"UNETLoader","inputs":{"unet_name":QWEN_EDIT,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":QWEN_CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":QWEN_VAE}},
        "5":{"class_type":"TextEncodeQwenImageEditPlus","inputs":{"clip":["2",0],"prompt":NEG}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.0}},
        "8":{"class_type":"EmptySD3LatentImage","inputs":{"width":768,"height":1024,"batch_size":1}},
        "9":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":seed(),"steps":20,"cfg":2.5,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["8",0],"denoise":1.0}},
        "10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["3",0]}},
        "11":{"class_type":"SaveImage","inputs":{"images":["10",0],"filename_prefix":"sf_shot"}}}
    pos={"clip":["2",0],"prompt":p,"vae":["3",0]}
    for i,nm in enumerate(ref_names[:3]):
        lid=str(20+i); wf[lid]={"class_type":"LoadImage","inputs":{"image":nm}}
        pos[f"image{i+1}"]=[lid,0]
    wf["4"]={"class_type":"TextEncodeQwenImageEditPlus","inputs":pos}
    return run(wf)

def save(url, fn):
    open(os.path.join(OUT,fn),"wb").write(getb(url)); return fn

# ---- Story bible: characters + location for the test script ----
CHARS = {
  "陈振飞": "16岁高一男生，圆脸短黑发，浓眉，穿白色短袖校服衬衫配深蓝运动裤，开朗跳脱，单人全身角色设定图，纯白背景，中性均匀光照，正面站姿",
  "俞墨凡": "16岁高一女生，清秀鹅蛋脸，黑色齐肩直发，神情清冷淡然，穿白色校服衬衫配深蓝百褶裙，单人全身角色设定图，纯白背景，中性均匀光照，正面站姿",
  "周瑞":   "16岁高一男生，瘦高个，戴黑框眼镜，碎发，穿白色校服衬衫，机灵爱笑，单人全身角色设定图，纯白背景，中性均匀光照，正面站姿",
}
LOC = {"茅盾中学门口": "茅盾中学校门口空镜，1990年代末中式中学大门，灰砖门柱挂校牌，门内林荫道，初秋清晨暖阳，无人物，建立镜头广角"}

# ---- Shots (scene_num, present character names, description) ----
SHOTS = [
  (1, ["陈振飞"], "陈振飞骑旧自行车飞驰冲向校门，嘴里叼着半个包子，用力蹬脚踏板，全身中景，动感"),
  (1, ["陈振飞","俞墨凡"], "陈振飞的自行车刹不住，与睡眼惺忪的俞墨凡迎面相撞，包子飞出，两人特写，慌乱瞬间"),
  (1, ["俞墨凡"], "俞墨凡平静地拍了拍裙子上的土，神情淡然，半身特写"),
  (2, ["周瑞"], "二楼教室窗内，周瑞望着窗外，嘴角带笑，半身近景，逆光"),
]

def main():
    reg={}  # name -> uploaded input image name
    print("=== A. 角色/场景设定图（统一风格锁，纯背景干净锚点） ===",flush=True)
    for name,desc in {**CHARS,**LOC}.items():
        t0=time.time(); url=t2i(desc)
        fn=save(url, f"sheet_{name}.png")
        reg[name]=upload(getb(url), f"ref_{uuid.uuid4().hex}.png")
        print(f"  [{time.time()-t0:.0f}s] {name} -> {fn}",flush=True)

    print("=== B. 逐镜头关键帧：只选该镜头真正出现的角色(≤3, 角色优先, 场景补位) ===",flush=True)
    locname=list(LOC)[0]
    for i,(scene,present,desc) in enumerate(SHOTS,1):
        # selection logic == new Dart _selectRefsForShot
        refs=[reg[n] for n in present if n in reg][:3]
        if len(refs)<3 and locname in reg: refs.append(reg[locname])
        refs=refs[:3]
        label=("+".join(present) if present else "空镜")+f" @场景{scene}"
        t0=time.time(); url=edit(desc, refs)
        fn=save(url, f"shot{i}_s{scene}_{'_'.join(present) or 'empty'}.png")
        print(f"  [{time.time()-t0:.0f}s] 镜头{i} [{label}] refs={len(refs)} -> {fn}",flush=True)
    print(f"DONE -> {OUT}",flush=True)

if __name__=="__main__": main()
