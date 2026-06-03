#!/usr/bin/env python3
"""Quality A/B: regenerate the same character at the current low settings vs
improved settings (higher res 9:16, more steps, higher cfg) for a side-by-side."""
import json, time, random, urllib.request, urllib.parse, os, sys
BASE="http://172.16.116.208:8188"
op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),"quality_probe")
os.makedirs(OUT,exist_ok=True)
QI="qwen_image_2512_fp8_e4m3fn.safetensors"; CLIP="qwen_2.5_vl_7b_fp8_scaled.safetensors"; VAE="qwen_image_vae.safetensors"
NEG="blurry, low quality, lowres, jpeg artifacts, distorted, deformed, watermark, text, extra limbs, bad anatomy"
STYLE="2000年中国江南小镇，初秋开学日，晴天暖阳，写实电影摄影，35mm 胶片质感，柔和暖色调，高细节"
PROMPT=("一个16岁高一男生，圆脸短黑发浓眉，穿蓝白配色运动校服外套、白色T恤、深蓝运动裤、黑白帆布鞋，"
        "开朗自然站姿，单人全身，纯色中性背景，均匀柔和光照，五官清晰")
def seed(): return random.randint(0,0x7FFFFFFF)
def post(p,o):
    r=urllib.request.Request(BASE+p,data=json.dumps(o).encode(),headers={"Content-Type":"application/json"})
    return json.load(op.open(r,timeout=60))
def getj(p): return json.load(op.open(BASE+p,timeout=30))
def run(wf):
    pid=post("/prompt",{"prompt":wf,"client_id":f"q_{int(time.time()*1e6)}"})["prompt_id"]
    end=time.time()+300
    while time.time()<end:
        time.sleep(2)
        try:h=getj(f"/history/{pid}")
        except Exception:continue
        e=h.get(pid)
        if not isinstance(e,dict):continue
        if e.get("status",{}).get("status_str")=="error":raise RuntimeError("err")
        outs=e.get("outputs")
        if isinstance(outs,dict) and outs:
            for nd in outs.values():
                a=nd.get("images")
                if a and a[0].get("filename"):
                    it=a[0];return BASE+"/view?"+urllib.parse.urlencode({"filename":it["filename"],"subfolder":it.get("subfolder",""),"type":it.get("type","output")})
    raise RuntimeError("timeout")
def gen(w,h,steps,cfg,fn,sd):
    p=f"{STYLE}。{PROMPT}"
    wf={"1":{"class_type":"UNETLoader","inputs":{"unet_name":QI,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":p,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG,"clip":["2",0]}},
        "6":{"class_type":"EmptySD3LatentImage","inputs":{"width":w,"height":h,"batch_size":1}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.1}},
        "8":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":sd,"steps":steps,"cfg":cfg,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],"latent_image":["6",0],"denoise":1.0}},
        "9":{"class_type":"VAEDecode","inputs":{"samples":["8",0],"vae":["3",0]}},
        "10":{"class_type":"SaveImage","inputs":{"images":["9",0],"filename_prefix":"q"}}}
    t0=time.time();url=run(wf);open(os.path.join(OUT,fn),"wb").write(op.open(url,timeout=180).read())
    print(f"  [{time.time()-t0:.0f}s] {fn} ({w}x{h}, {steps}步, cfg{cfg})",flush=True)
sd=seed()
print("A 当前设置(低): 768x1024 / 20步 / cfg2.5",flush=True); gen(768,1024,20,2.5,"A_current.png",sd)
print("B 改进设置(高): 928x1664 / 30步 / cfg4.0",flush=True); gen(928,1664,30,4.0,"B_improved.png",sd)
print("DONE",flush=True)
