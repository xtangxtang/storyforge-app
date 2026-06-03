#!/usr/bin/env python3
"""End-to-end exercise of Storyforge's ComfyUI workflows against the A100 box.
Mirrors lib/services/comfyui_service.dart exactly: t2i -> edit(ref) -> i2v."""
import json, sys, time, random, urllib.request, urllib.parse, io, os, tempfile

BASE = "http://172.16.116.208:8188"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # bypass proxy
TMP = tempfile.gettempdir()

QWEN_CLIP = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
QWEN_VAE = "qwen_image_vae.safetensors"
QWEN_IMG = "qwen_image_2512_fp8_e4m3fn.safetensors"
QWEN_EDIT = "qwen_image_edit_2509_fp8_e4m3fn.safetensors"
WAN_CLIP = "umt5_xxl_fp8_e4m3fn_scaled.safetensors"
WAN_VAE = "wan2.2_vae.safetensors"
WAN_VIDEO = "wan2.2_ti2v_5B_fp16.safetensors"
NEG_IMG = "blurry, low quality, distorted, watermark, text"
NEG_VID = "static, blurry, distorted, low quality, watermark"

def seed(): return random.randint(0, 0x7FFFFFFF)

def post_json(path, obj):
    req = urllib.request.Request(BASE+path, data=json.dumps(obj).encode(),
                                 headers={"Content-Type":"application/json"})
    return json.load(opener.open(req, timeout=60))

def get_json(path):
    return json.load(opener.open(BASE+path, timeout=30))

def get_bytes(url):
    return opener.open(url, timeout=120).read()

def upload(b, name):
    import uuid
    boundary = "----sf"+uuid.uuid4().hex
    body = io.BytesIO()
    def w(s): body.write(s if isinstance(s,bytes) else s.encode())
    w(f"--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n")
    w(f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n")
    w("Content-Type: image/png\r\n\r\n"); w(b); w("\r\n")
    w(f"--{boundary}--\r\n")
    req = urllib.request.Request(BASE+"/upload/image", data=body.getvalue(),
        headers={"Content-Type":f"multipart/form-data; boundary={boundary}"})
    j = json.load(opener.open(req, timeout=120))
    n, sub = j["name"], j.get("subfolder","")
    return f"{sub}/{n}" if sub else n

def view_url(item):
    qs = urllib.parse.urlencode({"filename":item["filename"],
        "subfolder":item.get("subfolder",""),"type":item.get("type","output")})
    return f"{BASE}/view?{qs}"

def run(wf, timeout, keys):
    cid = f"storyforge_{int(time.time()*1e6)}"
    r = post_json("/prompt", {"prompt":wf,"client_id":cid})
    pid = r["prompt_id"]
    deadline = time.time()+timeout
    while time.time() < deadline:
        time.sleep(2)
        try: h = get_json(f"/history/{pid}")
        except Exception: continue
        e = h.get(pid)
        if not isinstance(e, dict): continue
        st = e.get("status",{})
        if st.get("status_str") == "error":
            raise RuntimeError("ComfyUI error: "+json.dumps(st.get("messages"))[:800])
        outs = e.get("outputs")
        if isinstance(outs, dict) and outs:
            for node in outs.values():
                for k in keys:
                    arr = node.get(k)
                    if isinstance(arr, list) and arr and arr[0].get("filename"):
                        return view_url(arr[0])
            raise RuntimeError("no output url, outputs="+json.dumps(outs)[:400])
    raise RuntimeError(f"timeout after {timeout}s")

def wf_t2i(prompt):
    return {
        "1":{"class_type":"UNETLoader","inputs":{"unet_name":QWEN_IMG,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":QWEN_CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":QWEN_VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":prompt,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG_IMG,"clip":["2",0]}},
        "6":{"class_type":"EmptySD3LatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.1}},
        "8":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":seed(),"steps":20,"cfg":2.5,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["6",0],"denoise":1.0}},
        "9":{"class_type":"VAEDecode","inputs":{"samples":["8",0],"vae":["3",0]}},
        "10":{"class_type":"SaveImage","inputs":{"images":["9",0],"filename_prefix":"storyforge_img"}},
    }

def wf_edit(prompt, names):
    wf = {
        "1":{"class_type":"UNETLoader","inputs":{"unet_name":QWEN_EDIT,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":QWEN_CLIP,"type":"qwen_image"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":QWEN_VAE}},
        "5":{"class_type":"TextEncodeQwenImageEditPlus","inputs":{"clip":["2",0],"prompt":NEG_IMG}},
        "7":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["1",0],"shift":3.0}},
        "8":{"class_type":"EmptySD3LatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
        "9":{"class_type":"KSampler","inputs":{"model":["7",0],"seed":seed(),"steps":20,"cfg":2.5,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["8",0],"denoise":1.0}},
        "10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["3",0]}},
        "11":{"class_type":"SaveImage","inputs":{"images":["10",0],"filename_prefix":"storyforge_img"}},
    }
    pos = {"clip":["2",0],"prompt":prompt,"vae":["3",0]}
    for i, nm in enumerate(names):
        lid = str(20+i)
        wf[lid] = {"class_type":"LoadImage","inputs":{"image":nm}}
        pos[f"image{i+1}"] = [lid,0]
    wf["4"] = {"class_type":"TextEncodeQwenImageEditPlus","inputs":pos}
    return wf

def wf_i2v(prompt, image_name, length, fps):
    return {
        "1":{"class_type":"UNETLoader","inputs":{"unet_name":WAN_VIDEO,"weight_dtype":"default"}},
        "2":{"class_type":"CLIPLoader","inputs":{"clip_name":WAN_CLIP,"type":"wan"}},
        "3":{"class_type":"VAELoader","inputs":{"vae_name":WAN_VAE}},
        "4":{"class_type":"CLIPTextEncode","inputs":{"text":prompt,"clip":["2",0]}},
        "5":{"class_type":"CLIPTextEncode","inputs":{"text":NEG_VID,"clip":["2",0]}},
        "6":{"class_type":"LoadImage","inputs":{"image":image_name}},
        "7":{"class_type":"Wan22ImageToVideoLatent","inputs":{"vae":["3",0],"width":1280,"height":704,
              "length":length,"batch_size":1,"start_image":["6",0]}},
        "8":{"class_type":"ModelSamplingSD3","inputs":{"model":["1",0],"shift":8.0}},
        "9":{"class_type":"KSampler","inputs":{"model":["8",0],"seed":seed(),"steps":20,"cfg":5.0,
              "sampler_name":"euler","scheduler":"simple","positive":["4",0],"negative":["5",0],
              "latent_image":["7",0],"denoise":1.0}},
        "10":{"class_type":"VAEDecode","inputs":{"samples":["9",0],"vae":["3",0]}},
        "11":{"class_type":"CreateVideo","inputs":{"images":["10",0],"fps":float(fps)}},
        "12":{"class_type":"SaveVideo","inputs":{"video":["11",0],"filename_prefix":"storyforge_vid",
              "format":"mp4","codec":"h264"}},
    }

def pj(name): return os.path.join(TMP, name)

stage = sys.argv[1] if len(sys.argv) > 1 else "all"

if stage in ("t2i","all"):
    t0=time.time()
    print("[1/3] t2i Qwen-Image ...", flush=True)
    url = run(wf_t2i("A lone lighthouse on a cliff at golden hour, cinematic, highly detailed"),
              300, ["images"])
    print(f"   OK ({time.time()-t0:.0f}s) -> {url}", flush=True)
    open(pj("sf_img_url.txt"),"w").write(url)

if stage in ("edit","all"):
    t0=time.time()
    print("[2/3] edit Qwen-Image-Edit-2509 (1 ref) ...", flush=True)
    src = open(pj("sf_img_url.txt")).read().strip()
    nm = upload(get_bytes(src), "storyforge_ref0.png")
    url = run(wf_edit("Same lighthouse, now at night with a glowing beam sweeping the sea, stars above",
                      [nm]), 300, ["images"])
    print(f"   OK ({time.time()-t0:.0f}s) -> {url}", flush=True)
    open(pj("sf_edit_url.txt"),"w").write(url)

if stage in ("i2v","all"):
    t0=time.time()
    print("[3/3] i2v Wan2.2-TI2V-5B ...", flush=True)
    src = open(pj("sf_img_url.txt")).read().strip()
    nm = upload(get_bytes(src), "storyforge_start.png")
    length = 5*24+1  # 121
    url = run(wf_i2v("The lighthouse beam slowly sweeps across the dark sea, waves moving gently",
                     nm, length, 24), 900, ["images","gifs","videos"])
    print(f"   OK ({time.time()-t0:.0f}s) -> {url}", flush=True)
    open(pj("sf_vid_url.txt"),"w").write(url)

print("DONE", flush=True)
