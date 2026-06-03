#!/usr/bin/env python3
"""Animate the consistency keyframes via Wan2.2-TI2V-5B (i2v) to close the full
pipeline loop: keyframe -> video. Proves motion preserves the locked identity."""
import json, sys, time, random, urllib.request, urllib.parse, io, os, uuid

BASE="http://172.16.116.208:8188"
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),"consistency_out")
WAN_CLIP="umt5_xxl_fp8_e4m3fn_scaled.safetensors"; WAN_VAE="wan2.2_vae.safetensors"
WAN_VIDEO="wan2.2_ti2v_5B_fp16.safetensors"
NEG="static, blurry, distorted, low quality, watermark"

def seed(): return random.randint(0,0x7FFFFFFF)
def post(p,o):
    r=urllib.request.Request(BASE+p,data=json.dumps(o).encode(),headers={"Content-Type":"application/json"})
    return json.load(opener.open(r,timeout=60))
def getj(p): return json.load(opener.open(BASE+p,timeout=30))
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
def vurl(it): return BASE+"/view?"+urllib.parse.urlencode({"filename":it["filename"],
    "subfolder":it.get("subfolder",""),"type":it.get("type","output")})
def run(wf,timeout=900):
    pid=post("/prompt",{"prompt":wf,"client_id":f"sf_{int(time.time()*1e6)}"})["prompt_id"]
    end=time.time()+timeout
    while time.time()<end:
        time.sleep(3)
        try: h=getj(f"/history/{pid}")
        except Exception: continue
        e=h.get(pid)
        if not isinstance(e,dict): continue
        st=e.get("status",{})
        if st.get("status_str")=="error": raise RuntimeError(json.dumps(st.get("messages"))[:600])
        outs=e.get("outputs")
        if isinstance(outs,dict) and outs:
            for nd in outs.values():
                for k in ("images","gifs","videos"):
                    arr=nd.get(k)
                    if isinstance(arr,list) and arr and arr[0].get("filename"): return vurl(arr[0])
            raise RuntimeError("no video")
    raise RuntimeError("timeout")
def i2v(prompt,img,length=81,fps=24):
    return {"1":{"class_type":"UNETLoader","inputs":{"unet_name":WAN_VIDEO,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":WAN_CLIP,"type":"wan"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":WAN_VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":prompt,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG,"clip":["2",0]}},
        "6":{"class_type":"LoadImage","inputs":{"image":img}},
        "7":{"class_type":"Wan22ImageToVideoLatent","inputs":{"vae":["3",0],"width":768,"height":1024,
              "length":length,"batch_size":1,"start_image":["6",0]}},
        "8":{"class_type":"ModelSamplingSD3","inputs":{"model":["1",0],"shift":8.0}},
        "9":{"class_type":"KSampler","inputs":{"model":["8",0],"seed":seed(),"steps":20,"cfg":5.0,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["7",0],"denoise":1.0}},
        "10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["3",0]}},
        "11":{"class_type":"CreateVideo","inputs":{"images":["10",0],"fps":float(fps)}},
        "12":{"class_type":"SaveVideo","inputs":{"video":["11",0],"filename_prefix":"sf_clip",
              "format":"mp4","codec":"h264"}}}

JOBS=[
  ("shot1_s1_陈振飞.png","陈振飞骑着旧自行车向前飞驰，双腿用力蹬踏板，镜头跟随，背景林荫道向后掠过"),
  ("shot2_s1_陈振飞_俞墨凡.png","自行车骤停，陈振飞与俞墨凡相撞踉跄，包子飞起，落叶飘动，手持镜头轻微晃动"),
]
for fn,prompt in JOBS:
    path=os.path.join(OUT,fn)
    nm=upload(open(path,"rb").read(), f"kf_{uuid.uuid4().hex}.png")
    t0=time.time(); url=run(i2v(prompt,nm))
    out=os.path.join(OUT, fn.replace(".png",".mp4"))
    open(out,"wb").write(opener.open(url,timeout=180).read())
    print(f"[{time.time()-t0:.0f}s] {fn} -> {os.path.basename(out)}  {os.path.getsize(out)} bytes",flush=True)
print("DONE",flush=True)
