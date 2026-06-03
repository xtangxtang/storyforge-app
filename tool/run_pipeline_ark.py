#!/usr/bin/env python3
"""Full Storyforge pipeline on the configured Ark backend (mirrors the Dart
ArkService + agents logic): qwen3.6-plus (brief->script->storyboard) -> Seedream
5.0 lite clean style-locked sheets -> per-shot keyframes (English, only the refs
present in the shot) -> Seedance 2.0 i2v (with t2v fallback on moderation)."""
import json, os, re, ssl, time, urllib.request, urllib.error

# Secrets/config come from the gitignored config.local.json (same file the app
# uses) or env vars — NEVER hardcode keys here (this file is committed).
_CFG = {}
_cfg_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.local.json")
if os.path.exists(_cfg_path):
    try: _CFG = json.load(open(_cfg_path, encoding="utf-8"))
    except Exception: _CFG = {}
def _cfg(env, key, default=""):
    return os.environ.get(env) or _CFG.get(key) or default

PROXY = _cfg("HTTPS_PROXY", "httpsProxy", "")
LLM = _cfg("LLM_BASE_URL", "llmBaseUrl", "https://coding.dashscope.aliyuncs.com/v1"); LKEY = _cfg("LLM_API_KEY", "llmApiKey")
ARK = _cfg("ARK_BASE_URL", "arkBaseUrl", "https://ark.cn-beijing.volces.com/api/plan/v3"); AKEY = _cfg("ARK_API_KEY", "arkApiKey")
IMG_MODEL = _cfg("ARK_IMAGE_MODEL", "arkImageModel", "doubao-seedream-5.0-lite"); VID_MODEL = _cfg("ARK_VIDEO_MODEL", "arkVideoModel", "doubao-seedance-2.0")
if not (LKEY and AKEY):
    raise SystemExit("缺少密钥:请在项目根目录 config.local.json 填 llmApiKey/arkApiKey(或设环境变量 LLM_API_KEY/ARK_API_KEY)")
VID_RES = os.environ.get("VID_RES", "720p")  # 720p default; drop to 480p when quota-limited
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generated"); os.makedirs(OUT, exist_ok=True)
_ctx = ssl.create_default_context(); _ctx.check_hostname = False; _ctx.verify_mode = ssl.CERT_NONE
_proxies = {"https": PROXY, "http": PROXY} if PROXY else {}
op = urllib.request.build_opener(urllib.request.ProxyHandler(_proxies),
                                 urllib.request.HTTPSHandler(context=_ctx))
def log(m): print(m, flush=True)

def post(url, key, body, to=180):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        return json.load(op.open(req, timeout=to))
    except urllib.error.HTTPError as e:
        # Surface the response body so the moderation fallback can read the
        # actual error code (e.g. PrivacyInformation), mirroring the Dart client
        # which reads resp.body on non-200.
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'ignore')[:300]}")
def getj(url, key, to=30):
    return json.load(op.open(urllib.request.Request(url, headers={"Authorization": "Bearer " + key}), timeout=to))
def getb(u): return op.open(u, timeout=180).read()

def llm(system, user, temp, tag):
    # Retry on transient network/read timeouts (long prompts make qwen slow; a
    # single stall shouldn't kill the whole run). Longer read timeout too.
    last = None
    for attempt in range(4):
        t0 = time.time()
        try:
            r = post(LLM + "/chat/completions", LKEY, {"model": "qwen3.6-plus", "temperature": temp,
                "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}, to=300)
            log(f"   [LLM {tag} {time.time()-t0:.0f}s]")
            return r["choices"][0]["message"]["content"]
        except (TimeoutError, urllib.error.URLError, ConnectionError) as e:
            last = e; log(f"   [LLM {tag} 超时/网络错误,重试{attempt+1}: {str(e)[:80]}]"); time.sleep(5)
    raise RuntimeError(f"LLM {tag} failed after retries: {last}")

_tcache = {}
def to_en(zh):
    zh = (zh or "").strip()
    if not zh or not re.search(r'[一-鿿]', zh): return zh
    if zh in _tcache: return _tcache[zh]
    SYS = "You translate image/video generation prompts into natural concise English for a t2i/t2v model. Preserve every visual detail: subject, appearance, clothing, action/pose, camera, composition, lighting, mood, style. Do NOT add or drop content. IMPORTANT: any on-screen text that must literally appear in the image (e.g. a school gate signboard) must be kept verbatim in the ORIGINAL Chinese characters inside quotes — e.g. a signboard reading \"茅盾中学\" — do not translate or romanize such on-screen text. Output ONLY the English prompt."
    last = None
    for attempt in range(3):
        try:
            r = post(LLM + "/chat/completions", LKEY, {"model": "qwen3.6-plus", "temperature": 0.2,
                "messages": [{"role": "system", "content": SYS}, {"role": "user", "content": zh}]}, to=300)
            en = r["choices"][0]["message"]["content"].strip() or zh
            _tcache[zh] = en; return en
        except (TimeoutError, urllib.error.URLError, ConnectionError) as e:
            last = e; time.sleep(5)
    log(f"   [翻译超时,回退中文原文: {str(last)[:60]}]")
    return zh  # best-effort: fall back to original so the run doesn't crash

def parse_json(s):
    s = re.sub(r"^```(json)?", "", s.strip()).strip(); s = re.sub(r"```$", "", s).strip()
    try: return json.loads(s)
    except Exception:
        m = re.search(r"[\{\[].*[\}\]]", s, re.S); return json.loads(m.group(0))

def norm_obj(d, list_key=None):
    """LLM sometimes returns a bare list; coerce to the expected object shape."""
    if isinstance(d, dict): return d
    if isinstance(d, list):
        for x in d:
            if isinstance(x, dict) and (list_key is None or list_key in x or "assets" in x or "scenes" in x):
                return x
        return {list_key: d} if list_key else (d[0] if d and isinstance(d[0], dict) else {})
    return {}

def seedream(prompt_en, refs=None):
    # watermark ON: keeps the "AI生成" mark so Seedance accepts these images as
    # reference_image inputs (realistic-human photos without it get moderation-blocked).
    body = {"model": IMG_MODEL, "prompt": prompt_en, "size": "1440x2560", "response_format": "url", "watermark": True}
    if refs: body["image"] = refs[:3]
    return post(ARK + "/images/generations", AKEY, body)["data"][0]["url"]

def _poll_task(tid):
    end = time.time() + 900
    while time.time() < end:
        time.sleep(6)
        d = getj(ARK + f"/contents/generations/tasks/{tid}", AKEY)
        s = d.get("status")
        if s == "succeeded": return d["content"]["video_url"]
        if s == "failed": raise RuntimeError(json.dumps(d.get("error"))[:200])
    raise RuntimeError("timeout")

def _submit_video(text, ref_urls):
    # t2v: subject anchoring via reference_image (no first frame)
    content = [{"type": "text", "text": text}]
    for u in (ref_urls or [])[:3]:
        content.append({"type": "image_url", "image_url": {"url": u}, "role": "reference_image"})
    tid = post(ARK + "/contents/generations/tasks", AKEY, {"model": VID_MODEL, "content": content}, to=60)["id"]
    return _poll_task(tid)

def _submit_i2v(text, first_frame):
    # i2v: the Seedream keyframe is the controlled first frame (role first_frame);
    # composition/staging come from it, motion from the text. Identity is already
    # baked into the keyframe. NOTE: Seedance rejects first_frame mixed with
    # reference_image in one request (InvalidParameter), so first_frame ONLY.
    content = [{"type": "text", "text": text},
               {"type": "image_url", "image_url": {"url": first_frame}, "role": "first_frame"}]
    tid = post(ARK + "/contents/generations/tasks", AKEY, {"model": VID_MODEL, "content": content}, to=60)["id"]
    return _poll_task(tid)

def _is_mod(e):
    m = str(e).lower(); return any(k in m for k in ("sensitive", "privacy", "moderation", "policyviolation"))

def _is_rate(e):
    m = str(e).lower(); return any(k in m for k in ("429", "quota", "toomanyrequests", "rate limit"))

def _is_transient(e):
    m = str(e).lower(); return any(k in m for k in ("internalserviceerror", "http 500", "http 502", "http 503", "http 504", "internal error", "timeout"))

def seedance(prompt_en, ref_urls, dur):
    """t2v with reference_image subject anchoring (mirrors ArkService)."""
    text = f"{prompt_en} --ratio 9:16 --resolution {VID_RES} --duration {dur}"
    last = None; drop_refs = False
    for i in range(6):
        try:
            # keep refs unless a moderation block forced us to drop them
            return _submit_video(text, [] if drop_refs else ref_urls)
        except Exception as e:
            last = e
            if _is_rate(e):           # quota/RPM limit: back off and retry, keep refs
                log(f"      限流 429,等待 40s 重试 {i+1}: {str(e)[:80]}"); time.sleep(40); continue
            if _is_transient(e):      # transient 5xx/internal/timeout: short backoff, keep refs
                log(f"      服务端瞬时错误,等待 15s 重试 {i+1}: {str(e)[:80]}"); time.sleep(15); continue
            if _is_mod(e):            # moderation block: drop refs and retry pure t2v
                drop_refs = True; log(f"      视频审核重试 {i+1}: {str(e)[:80]}"); continue
            raise
    raise RuntimeError(f"blocked/quota after retries: {last}")

def seedance_i2v(prompt_en, first_frame_url, ref_urls, dur):
    """i2v: a controlled Seedream keyframe is the first frame (composition/logic),
    the text prompt drives motion. The watermarked keyframe passes moderation.
    first_frame only — Seedance forbids mixing it with reference_image."""
    text = f"{prompt_en} --ratio 9:16 --resolution {VID_RES} --duration {dur}"
    last = None
    for i in range(6):
        try:
            return _submit_i2v(text, first_frame_url)
        except Exception as e:
            last = e
            if _is_rate(e):      log(f"      限流 429,等待 40s 重试 {i+1}: {str(e)[:80]}"); time.sleep(40); continue
            if _is_transient(e): log(f"      服务端瞬时错误,等待 15s 重试 {i+1}: {str(e)[:80]}"); time.sleep(15); continue
            if _is_mod(e):       log(f"      i2v 审核重试(重新采样首帧种子) {i+1}: {str(e)[:80]}"); continue
            raise
    # last resort so the beat still produces something (t2v can use refs)
    log(f"      i2v 持续失败,降级为 t2v+参考图: {str(last)[:80]}")
    return seedance(prompt_en, ref_urls, dur)

def _submit_refvideo(text, ref_video_urls):
    # Pass up to 3 prior beat videos as reference_video (consistency references;
    # subject/world/style/lighting carry forward). Per-character selection upstream
    # decides which clips to pass so each present character's look is inherited.
    # Video input requires role=reference_video and a web url. NO image inputs
    # (image moderation is stricter and blocks realistic faces).
    content = [{"type": "text", "text": text}]
    for u in (ref_video_urls or [])[:3]:
        content.append({"type": "video_url", "video_url": {"url": u}, "role": "reference_video"})
    tid = post(ARK + "/contents/generations/tasks", AKEY, {"model": VID_MODEL, "content": content}, to=120)["id"]
    return _poll_task(tid)

def seedance_chain(prompt_en, ref_video_urls, dur):
    """Render a beat inheriting up to 3 prior beat videos (one per present
    character, most recent) as reference_video. Empty list = pure t2v."""
    text = f"{prompt_en} --ratio 9:16 --resolution {VID_RES} --duration {dur}"
    last = None; refs = list(ref_video_urls or [])[:3]
    for i in range(6):
        try:
            return _submit_refvideo(text, refs)
        except Exception as e:
            last = e
            if _is_rate(e):      log(f"      限流429 等40s 重试{i+1}"); time.sleep(40); continue
            if _is_transient(e): log(f"      瞬时5xx 等15s 重试{i+1}"); time.sleep(15); continue
            if _is_mod(e):
                # one reference video likely tripped "real person"; drop the last
                # one and retry (preserve the rest). Empty -> pure t2v.
                if refs: refs.pop(); log(f"      参考视频被审核拦,丢1段重试{i+1}(剩{len(refs)}段): {str(e)[:60]}"); continue
                log(f"      纯文生仍被审核拦 重试{i+1}: {str(e)[:60]}"); continue
            raise
    raise RuntimeError(f"fail after retries: {last}")

def _can_anchor(vurl):
    # A minimal task using vurl as reference_video is rejected AT SUBMIT (HTTP 400
    # PrivacyInformation) iff the video reads as a real person — a cheap pre-check
    # of whether vurl can anchor the chain. The API has no task-cancel (DELETE is a
    # no-op), so if accepted we poll the throwaway task to completion to free the
    # single concurrency slot before the real beats continue.
    try:
        r = post(ARK + "/contents/generations/tasks", AKEY, {"model": VID_MODEL, "content": [
            {"type": "text", "text": "an empty quiet street, static shot --ratio 9:16 --resolution 480p --duration 5"},
            {"type": "video_url", "video_url": {"url": vurl}, "role": "reference_video"}]}, to=60)
        tid = r.get("id")
        if tid:
            try: _poll_task(tid)   # drain the throwaway so it doesn't hog the slot
            except Exception: pass
        return True
    except Exception as e:
        if _is_mod(e): return False
        return True  # rate/transient/other: don't penalize, assume anchorable

# 锚 beat(无前置片段的纯文生段)若太写实当不了 reference_video,逐级加重风格化重出。
ANCHOR_EXTRA = ["",
    "。【画面务必明显风格化、降低真实度】加重2000年代电影胶片插画感:可见手绘描边与平涂笔触、更重胶片颗粒与漏光,确保是影视/插画画面而非真实人物照片,柔化写实人脸细节",
    "。【画风强烈风格化,接近手绘动画电影定帧】明显赛璐璐/水彩插画质感、平涂上色与清晰描边,绝非真实照片,人脸明显非写实"]

def gen_anchor_beat(vtext, dur):
    """Generate an anchor beat (no prior refs) and ensure its video can serve as
    reference_video, escalating stylization until it passes (or tries exhausted)."""
    vurl = None
    for t in range(len(ANCHOR_EXTRA)):
        vurl = seedance_chain(to_en(vtext + ANCHOR_EXTRA[t]), [], dur)
        if _can_anchor(vurl):
            log(f"      锚验证通过(可作 reference_video){' (加重风格化x%d)'%t if t else ''}")
            return vurl
        log(f"      锚不可作参考,加重风格化重出 {t+1}/{len(ANCHOR_EXTRA)}")
    log("      锚验证仍未通过,沿用最后一次(下游该角色可能失锚)")
    return vurl

BRIEF_SYS = "你是专业影视策划人。根据创意生成短剧 Brief。输出严格 JSON：{\"genre\":\"\",\"duration\":数字,\"aspect_ratio\":\"9:16\",\"mood\":\"\",\"visual_style\":\"中文视觉风格\",\"story_outline\":\"中文大纲\"}"
SCRIPT_SYS = "你是专业影视编剧。输出严格 JSON：{\"scenes\":[{\"scene_num\":1,\"location\":\"\",\"description\":\"\",\"action\":\"\",\"dialogue\":[],\"duration\":15}],\"assets\":[{\"type\":\"character|location|prop\",\"name\":\"\",\"description\":\"中文详细外貌/服装/光线/材质\"}]}。2-4场景,提取所有角色/场景/道具。"
# 全片唯一校服:跨镜头不统一的根因是每个角色被编了不同校服并各自出图。先定一套全校唯一校服,所有学生强制一致。
UNIFORM_SYS = ("你是影视服装指导。本片所有学生角色必须穿**同一套**校服(同款同色)。根据剧本的年代、季节、地点,"
               "设计**唯一一套**男款校服,全体男生完全一致。输出严格 JSON:"
               "{\"uniform\":\"一句话精确描述这套统一校服:上衣款式与颜色、裤子款式与颜色、鞋子,要具体且唯一,不要给选项\"}")
SB_SYS = ("你是专业分镜师。把剧本切成若干【连续 beat】,每个 beat 会被生成为一整段连续视频。输出严格 JSON："
          "{\"storyboards\":[{\"scene_num\":1,\"shot_num\":1,\"continuous_camera\":true,\"shot_type\":\"\",\"camera_move\":\"\",\"characters\":[\"角色原名\"],\"description\":\"中文\",\"first_frame_prompt\":\"中文,这段beat开场第一帧的静态画面:在场角色各自的位置/姿态/表情、关键道具此刻的状态、景别与构图、光线;写的是动作即将发生的那一刻(如:主体A 正做某动作冲入画面、主体B 在画面某位置某姿态),不是动作结束后\",\"video_prompt\":\"中文,整段连续运镜:起始→连续过程→结束,含道具连续状态\",\"duration\":10}]}。"
          "【beat 概念】一个 beat=一个不间断的一镜到底,会整段生成,所以 beat 内动作/道具/位置/人物天然连续。"
          "**同一时空里连续发生的事件必须合并进同一个 beat,绝不拆成多段**。"
          "【关键:多人互动事件不可拆】两个角色之间一次连续的互动(碰撞、对话、递东西、搀扶等),从起因到反应到收尾,是一个完整 beat,必须把**所有参与角色都放进同一个 beat**同框演完。"
          "**即使剧本把这次连续互动拆到了不同场景(如:碰撞在场景1、对方的反应/离开在场景2),只要时间地点连续,就必须合并成同一个 beat**,characters 列出事件中全部在场角色。"
          "抽象示例(仅示范原则,勿照搬内容):【主体A 朝主体B 移动→与 B 发生连续互动(碰撞/对话/递物等)→B 作出反应→A、B 完成各自收尾】=一个 beat,characters 同列 A 与 B,绝不能把 B 的反应单独拆成另一个 beat。"
          "只有真正换地点、明显时间跳跃、或必须切到无法连续衔接的全新视角时,才开新 beat。不要把连续动作切碎,也不要把跨地点内容硬塞进一个 beat。"
          "【专有名词逐字照搬】人名/地名/机构名/品牌等必须与剧本原文逐字一致,严禁改写或另起名;画面中出现的招牌/牌匾/标识文字必须写成剧本里的原文。"
          "【机位/构图】户外动作或碰撞 beat 必须用清晰无遮挡的机位(平视或低角度跟拍,主体完整入画),**严禁隔着窗户/门框/栏杆/前景障碍物拍摄**;隔窗/门框/前景遮挡的构图只允许用在「室内人物向外观望」这类 beat。"
          "【首帧 first_frame_prompt】写动作**即将发生的那一刻**的静态构图:谁在画面什么位置、什么姿态/表情、关键道具此刻状态、景别与光线;不要写成动作结束后的画面。它和 video_prompt 的【起始状态】必须一致。"
          "【角色】characters 列本 beat 实际出现的角色原名(空镜=[]);description/first_frame_prompt/video_prompt 一律用角色原名,禁用他/她/路人。"
          "【video_prompt 必须严格按此结构写,一镜到底,按①~⑥顺序组织成一段连贯中文】"
          "①【主体起始】开场画面里每个在场角色的外貌/服装/表情 + 此刻的姿态(与 first_frame 一致);"
          "②【连续动作链】这是最关键的部分:用「先…→紧接着…→随后…→最后…」把整段动作写成一条不间断的时间线,显式写出动作之间的物理因果(抽象示例:「主体A 做动作并因某原因导致后果X→触发主体B 的反应Y→同一瞬间道具Z 因受力发生状态变化→各自收尾」),关键道具全程连续不能凭空有无;"
          "③【单一运镜】整段只用一种主运镜,单独成句(如「镜头始终低角度侧面跟拍主体,随其移动平稳横摇」),绝不要在一个 beat 里切换多种机位或描述剪切;"
          "④【环境】地点、年代、天气、前景/背景关键元素;"
          "⑤【光影】光源方向、色温、胶片质感;"
          "⑥【负面约束】结尾固定加一句:「避免人物变形、肢体粘连穿模、人物瞬移或凭空出现消失、画面跳切闪烁、违反重力与惯性、画面出现任何字幕/文字/水印、动画或CG插画感」。"
          "【动作必须真的发生,不能呆站】凡剧本写到某角色『离开/进入/前往某处』,video_prompt 必须把它写成**实际完成的连续位移**:转身→迈步→走向目标→穿过/进入→远去,明确人物移动并最终离开画面或抵达目标;绝不能写成站在原地不动或只给一个静态结束姿势。"
          "【写法要点】动作要具体可拍、符合物理与重力;一个 beat 只承载一条连续动作链,不要塞过多事件。"
          "【场景模式规则库 — 按 beat 类型挂载适用模块,与题材无关;下列示例均为抽象占位】"
          "〔物理碰撞/剧烈接触〕碰撞瞬间分解到帧级让冲击可见:接触前(主体A 高速接近、对方未察觉)→接触瞬间(写明 A 的哪个部位撞到 B 的哪个部位、B 如何反应:上身前倾/侧倾、踉跄迈出一步、双臂张开找平衡)→接触后(B 晃动后才站稳;A 因惯性前冲、急停)。力度真实可信(踉跄而非夸张飞出),但必须明确『发生了实打实的接触』,不要写成擦肩而过或提前停下。被携带/被持的道具要在撞击那一刻因冲击被猛地弹飞、划抛物线落地,而非缓缓滑落。"
          "〔随身道具持续〕角色随身携带/操作的物品或交通工具,在 beat 内和跨 beat 必须被合理处置:人物移动/换场景时带着它一起,绝不能凭空消失、不能无故丢弃在原地(除非剧本明确要求);如推/扶着某物移动,要写明『一手扶着…一边移动』。"
          "【剪切点必须接得上 — 相邻 beat 衔接,最高优先级】每个 beat(除第1个)的开场必须**严格承接上一个 beat 的结尾状态**:上一镜结尾时主角在画面什么位置、什么景别(远景/中景/近景)、朝向哪、正在做什么动作、镜头在什么状态,本镜**开场就从那个状态接着开始**。"
          "**同一主体、同一地点的连续动作尤其要对齐**:景别、人物在画面里的大小与位置、朝向、正在进行的动作,都要和上一镜结尾一致,像同一条连续镜头被切成两段。"
          "抽象示例:上一镜结尾若是『主体背对镜头、由近及远走向远处(远景、人物很小)』,则本镜开场必须是『主体背对镜头、继续由近及远朝同一方向走(同样远景、人物很小、同样朝向)』,**绝不能突然切成他的近景侧脸**。"
          "只有真正换场景/换地点时才允许换景别,且要用建立镜头平滑过渡(如先给新地点空镜再带出人物)。"
          "在每个 beat 的 first_frame_prompt 和 video_prompt 的【主体起始】里都要显式写出『承接上一镜结尾:……(上一镜结尾的景别/人物位置/朝向/动作)』。"
          "【目睹类镜头 + 跨 beat 衔接,关键 — 机位务必正确,否则物理逻辑会塌】当某 beat 是一个角色从二楼/高处透过窗户目睹楼下另一个角色时,必须按下列方式写,否则模型会拍错:"
          "(1)**机位用『过肩俯视』**:摄影机放在观望者斜后方,越过其肩膀/侧脸朝窗外**向下俯视**;观望者**半背对或侧对镜头、面朝窗外**(绝不是正对镜头的肖像),前景是其肩头与侧脸,中后景透过窗框是楼下;"
          "(2)**俯视透视**:从高处往下看,楼下的被目睹者在画面中**位置偏低、个头较小、呈俯视压缩**,脚下是楼下地面而不是与观望者同高的屋顶;窗外即上一镜那个场景;"
          "(3)被目睹角色必须真实出现且**与上一个 beat 结尾状态严丝合缝衔接**(同款外观、同样动作),不能换装换动作;"
          "(4)观望者明确在**室内**:画面里要有室内景物线索(家具一角、墙面、窗框);"
          "(5)characters 同时列出『观望者』和『被目睹者』;(6)两 beat 时间紧接、光线天气季节一致。"
          "video_prompt 要分别交代:观望者在窗内的姿态/神情变化,与楼下被目睹者的连续动作。"
          "【方向与空间一致,关键】凡涉及『进入/前往某地』的动作,必须把运动方向写死且正确:主体朝目标由远及近地接近并穿过、进入,越走越深入目标内部;**绝不能把『进入某地』拍成背对目标、朝相反方向越走越远**。用镜头与朝向关系消歧(如『目标在主体正前方、他朝里走』,或『镜头在入口内侧朝外、主体从外面朝镜头走来并穿过入口进入』)。"
          "【背景生活感】公共场所(街道、广场、校园、车站等)的 beat,要在环境里写出可信的背景人物活动,让画面有生活气息;但背景人物只能是模糊的次要群众,不抢主体、不与主角互动、不得是剧本里的具名角色。"
          "duration 覆盖整段,多人互动 beat 建议 8-10 秒。"
          "【综合示例(抽象占位,仅示范结构与原则,切勿照搬内容)】某 beat 是一次连续碰撞互动:主体A 快速移动、来不及避让而撞上主体B;B 踉跄一步、A 随身携带的小物件因冲击弹飞落地;A 急停、伸手致意;B 站稳后转身离开、走向远处并最终离开画面。镜头全程低角度跟拍 A 并随其移动平稳横摇,撞击后转固定记录二人互动。下一 beat 开场承接上一镜结尾(B 已离开、A 留在原地的同一景别与位置),从该状态接着演下去。")

CREATIVE = ("2000年江南小镇,茅盾中学门口,九月一号开学,晴天炎热。校门口人来人往,三三两两背书包的学生陆续走进校门,很有开学的热闹生活气。"
            "陈振飞骑自行车飞驰,嘴叼半个包子,快迟到。刹不住车,自行车前轮重重撞上睡眼惺忪的俞墨凡,俞墨凡被撞得踉跄,嘴里的包子(陈振飞的)因冲击飞出。"
            "陈振飞慌忙刹停道歉要扶他,俞墨凡只平静拍掉裤子上的土说没事,随即转身迈步、头也不回地走向校门、穿过校门走进校园,背影渐渐远去(俞墨凡不是呆站在原地,而是明确地一步步走进了学校)。"
            "陈振飞呆立,上课铃响才回神,赶紧推着自己的自行车、朝校门里冲,穿过校门进入校园、朝校内教学楼方向快步跑去(注意:① 他始终推着自行车一起进校,绝不能把车扔在门外;② 方向必须是『从校门外进入校内』,越跑越深入校园、离教学楼越近,绝不能背对校门往校外街道跑)。"
            "镜头来到二楼教室:周瑞靠在窗边,从二楼俯视楼下校园林荫道,**亲眼目睹刚进校门的陈振飞正推着那辆自行车一路小跑、由门口往教学楼方向跑来**(陈振飞穿着和门口那场完全一样的校服、推着同一辆二八自行车,衔接上一镜),周瑞看着他狼狈又有活力的样子,嘴角缓缓带笑。\n"
            "【重要人物设定,必须遵守】陈振飞、俞墨凡、周瑞三人都是男生(高一男同学),全部穿男款校服;"
            "俞墨凡是男生,不是女生,不要写成女性、不要穿裙子。")

def style_lock(brief):
    # Style lock must carry LOOK (era/palette/texture/lighting), NOT shot
    # composition. Baking camera/composition gimmicks (e.g. "窗框构图/手持跟拍")
    # into the global style forced every shot through a window — composition
    # belongs per-beat, so strip those clauses here.
    raw = brief.get("visual_style", "").strip()
    # drop composition/camera words (belong per-beat) AND photoreal words: a
    # "纪实/超写实/真实" cue pushes the render over the "real person" line and gets
    # the beat's video blocked when fed back as reference_video. REALISM below
    # then sets the safe cinematic-semi-real look.
    drop = ("窗框", "构图", "机位", "运镜", "跟拍", "手持", "景别", "推拉",
            "摇镜", "俯拍", "仰拍", "视角", "镜头运动", "分屏",
            "纪实", "写实", "超写实", "逼真", "真实感", "真人", "实拍", "高清写真")
    clauses = [c for c in re.split(r"[、，。/；;,]", raw) if c.strip()]
    kept = [c for c in clauses if not any(d in c for d in drop)]
    style = "、".join(kept) if kept else raw
    parts = [x for x in [style,
             ("情绪基调:"+brief.get("mood", "").strip()) if brief.get("mood") else ""] if x]
    parts.append(REALISM)  # global photoreal directive on every image + video prompt
    return "；".join(parts)

# 全局画风:电影半写实。必须压在"真实人脸"审核线之下,否则上一段视频做
# reference_video 续写会被 InputVideoSensitiveContentDetected 拦(全写实实测被拦,
# 此电影半写实实测过审)。看起来仍是写实电影剧照感,不是动画。
REALISM = ("整体为2000年代怀旧电影胶片质感:粗颗粒胶片、轻微漏光与电影感暖调调色,"
           "半写实电影质感(介于写实与手绘之间、明显是影视画面而非真实人物照片),"
           "实景电影摄影感、自然光影与景深;非动画、非卡通、非3D渲染")

def main():
    log("===== Storyforge 完整流程 (Ark: Seedream + Seedance) =====")
    log("[1/5] 策划"); brief = norm_obj(parse_json(llm(BRIEF_SYS, "创意:"+CREATIVE, 0.8, "brief")))
    log(f"   {brief.get('genre')} {brief.get('duration')}s style={brief.get('visual_style','')[:50]}")
    log("[2/5] 编剧")
    script = {}; assets = []; scenes = []; chars = []
    for attempt in range(4):  # LLM occasionally returns an empty/degenerate script
        script = norm_obj(parse_json(llm(SCRIPT_SYS, "创意:"+CREATIVE, 0.8, "script")))
        assets = script.get("assets", []); scenes = script.get("scenes", [])
        chars = [a for a in assets if a.get("type")=="character"]
        if chars and scenes: break
        log(f"   script 不完整,重试 {attempt+1}")
    log(f"   场景{len(scenes)} 角色{len(chars)} 道具{sum(1 for a in assets if a['type']=='prop')}")
    # 唯一校服:所有角色设定图共用,保证跨镜头服装统一。
    uniform = ""
    try:
        uniform = norm_obj(parse_json(llm(UNIFORM_SYS, "剧本:"+json.dumps(script, ensure_ascii=False), 0.3, "uniform"))).get("uniform", "").strip()
    except Exception as e: log(f"   ✗ 校服设定失败,回退各角色自带描述: {str(e)[:80]}")
    log(f"   统一校服: {uniform[:60] or '(无)'}")
    log("[3/5] 分镜")
    sb = norm_obj(parse_json(llm(SB_SYS, "剧本:"+json.dumps(script, ensure_ascii=False), 0.3, "storyboard")), "storyboards")
    shots = sorted(sb.get("storyboards", []), key=lambda s: ((s.get('scene_num') or 0),(s.get('shot_num') or 0)))
    log(f"   分镜{len(shots)}")
    style = style_lock(brief)

    # 设定图(reference_image)链路已弃用:图片输入(写实真人首帧/参考图)被 Seedance
    # 图片审核稳定拦截。改用 reference_video 链——不需要设定图。
    cnames = [c["name"] for c in chars]

    sty = (style + "。") if style else ""
    unif = ("全体男生穿统一校服:" + uniform + "。") if uniform else ""

    # [4a] 角色锚段:每个角色单独出一个"单人、简单动作、风格化"的片段作其身份锚点。
    # 关键洞见:热闹的多角色剧情忙镜当不了 reference_video(被审核当真人拦),但
    # 单人风格化片段稳过审(已实测)。所以用干净单人锚段当"视频版角色设定图",
    # 所有剧情 beat 都引用它们 → 跨 beat 身份一致 + 多角色同台。
    log("[4a/4] 角色锚段 (单人风格化片段,作各角色身份锚点)")
    anchor = {}  # 角色名 -> 锚段 url
    for c in chars:
        name, desc = c.get("name", "").strip(), c.get("description", "")
        if not name: continue
        atext = (sty + unif + f"角色锚段,画面里只有这一个角色(单人,绝无其他人物):{desc}。"
                 "该角色在与剧本相符的环境中由远及近、神情自然地走向镜头,平视中近景,看清面部与全身,动作平缓自然")
        try:
            t0 = time.time()
            url = seedance_chain(to_en(atext), [], 5)  # 单人锚段,稳过审
            anchor[name] = url
            afn = f"anchor_{name}.mp4"; open(os.path.join(OUT, afn), "wb").write(getb(url))
            log(f"   ✓ 锚段 {name} [{time.time()-t0:.0f}s]")
        except Exception as e:
            log(f"   ✗ 锚段 {name}: {str(e)[:100]}")

    # [4b] 剧情 beat:按在场角色引用其锚段(≤3),身份从锚段继承。
    log("[4b/4] 剧情逐镜头: 引用在场角色的锚段 (跨beat身份一致)")
    manifest = []
    for i, s in enumerate(shots, 1):
        scene, shot = s.get("scene_num"), s.get("shot_num")
        vp = s.get("video_prompt", "") or s.get("description", "")
        present = [n for n in (s.get("characters") or []) if n in cnames] or \
                  [n for n in cnames if n and n in (s.get("description", "") + vp)]
        # 引用在场角色的锚段(去重,≤3)
        refs = []
        for n in present:
            u = anchor.get(n)
            if u and u not in refs:
                refs.append(u)
        refs = refs[:3]
        vtext = sty + unif + vp
        dur = min(max(int(s.get("duration") or 8), 5), 10)
        covered = [n for n in present if anchor.get(n) in refs]
        mode = f"引用锚段[{'+'.join(covered) or '无'}]" if refs else "无锚段(纯文生)"
        try:
            t0 = time.time()
            vurl = seedance_chain(to_en(vtext), refs, dur)
            vfn = f"shot{i:02d}_s{scene}_sh{shot}.mp4"; open(os.path.join(OUT, vfn), "wb").write(getb(vurl))
            sz = os.path.getsize(os.path.join(OUT, vfn))
            log(f"   ✓ 镜头{i} S{scene}-{shot} 出场[{'+'.join(present) or '空'}] {mode} [{time.time()-t0:.0f}s] {sz}B")
            manifest.append({"shot": i, "scene": scene, "present": present, "refs": len(refs), "video": vfn, "bytes": sz})
        except Exception as e:
            log(f"   ✗ 镜头{i} S{scene}-{shot}: {str(e)[:140]}")
            manifest.append({"shot": i, "scene": scene, "error": str(e)[:200]})
    json.dump({"brief": brief, "scenes": scenes, "assets": assets, "shots": shots, "manifest": manifest},
              open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    ok = sum(1 for m in manifest if m.get("video"))
    log(f"===== DONE: {ok}/{len(shots)} 镜头出片 -> {OUT} =====")

if __name__ == "__main__": main()
