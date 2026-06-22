from __future__ import annotations

import base64
import json
import mimetypes
import re
import time
from pathlib import Path
from typing import Any

from .config import StoryforgeConfig

try:
    import requests
except ModuleNotFoundError:
    requests = None  # type: ignore[assignment]


def require_requests():
    if requests is None:
        raise RuntimeError("Missing dependency: requests. Run `pip install -e .` or `pip install requests`.")
    return requests


class LLMClient:
    def __init__(self, config: StoryforgeConfig):
        self.config = config

    def chat_json(self, system: str, user: str, temperature: float = 0.2, tag: str = "llm") -> dict[str, Any]:
        text = self.chat(system, user, temperature=temperature, json_mode=True, tag=tag)
        return parse_json_object(text)

    def chat(self, system: str, user: str, temperature: float = 0.2, json_mode: bool = False, tag: str = "llm") -> str:
        if not self.config.llm_api_key:
            raise RuntimeError("Missing llmApiKey / LLM_API_KEY")
        body: dict[str, Any] = {
            "model": self.config.llm_model,
            "temperature": temperature,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
        if json_mode:
            body["response_format"] = {"type": "json_object"}
        http = require_requests()
        last_exc: Exception | None = None
        response = None
        for attempt in range(1, 3):  # 大段 JSON 生成偶发读超时/断连，重试一次
            try:
                response = http.post(
                    f"{self.config.llm_base_url}/chat/completions",
                    headers={"Authorization": f"Bearer {self.config.llm_api_key}", "Content-Type": "application/json"},
                    data=json.dumps(body),
                    proxies=self.config.proxies,
                    timeout=600,
                )
                break
            except http.exceptions.RequestException as exc:
                last_exc = exc
                if attempt >= 2:
                    raise RuntimeError(f"{tag} request failed after retries: {exc}") from exc
                time.sleep(3 * attempt)
        if response is None:
            raise RuntimeError(f"{tag} request failed: {last_exc}")
        if response.status_code != 200:
            raise RuntimeError(f"{tag} failed HTTP {response.status_code}: {response.text[:500]}")
        data = response.json()
        return data["choices"][0]["message"]["content"]

    def chat_vision_json(self, system: str, user: str, images: list[str], tag: str = "vision") -> dict[str, Any]:
        """多模态审图：把本地图/URL 作为 image_url 一起送给视觉 LLM，返回 JSON object。
        images 可为本地路径或 http(s) URL；本地路径会被 media_ref 转成 base64 data URI。"""
        vision_key = self.config.llm_vision_api_key or self.config.llm_api_key
        if not vision_key:
            raise RuntimeError("Missing vision api key (llmVisionApiKey / llmApiKey)")
        content: list[dict[str, Any]] = [{"type": "text", "text": user}]
        for img in images[:8]:
            ref = media_ref(str(img))
            if ref:
                content.append({"type": "image_url", "image_url": {"url": ref}})
        body: dict[str, Any] = {
            "model": self.config.llm_vision_model,
            "temperature": 0.1,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": content},
            ],
        }
        http = require_requests()
        response = http.post(
            f"{self.config.llm_vision_base_url}/chat/completions",
            headers={"Authorization": f"Bearer {vision_key}", "Content-Type": "application/json"},
            data=json.dumps(body),
            proxies=self.config.proxies,
            timeout=300,
        )
        if response.status_code != 200:
            raise RuntimeError(f"{tag} vision failed HTTP {response.status_code}: {response.text[:500]}")
        return parse_json_object(response.json()["choices"][0]["message"]["content"])

    def translate_visual_prompt(self, prompt: str) -> str:
        if not re.search(r"[\u4e00-\u9fff]", prompt):
            return prompt
        return self.chat(
            "Translate this image/video generation prompt into concise natural English. "
            "Preserve EXACTLY, never drop or soften: (1) which character wears which color and which bag, and on which side of frame each one stands; "
            "(2) screen-direction and axis — left/right and toward-or-away-from camera, and the 180-degree line; "
            "(3) camera height and angle (e.g. eye-level, low-angle, no overhead/bird's-eye) and shot size; "
            "(4) color temperature and main-light direction; "
            "(5) every negative / prohibition clause (no text, no overhead shot, no collage, do not change identity or clothing) — translate each 'do not / 避免 / 严禁 / 绝不' clause verbatim, do not omit or merge them; "
            "(6) character identity, prop state, and any required on-screen Chinese text verbatim in quotes. "
            "Output only the English prompt.",
            prompt,
            temperature=0.1,
            tag="translate_visual_prompt",
        ).strip()


class ArkClient:
    def __init__(self, config: StoryforgeConfig, llm: LLMClient):
        self.config = config
        self.llm = llm

    @property
    def headers(self) -> dict[str, str]:
        if not self.config.ark_api_key:
            raise RuntimeError("Missing arkApiKey / ARK_API_KEY")
        return {"Authorization": f"Bearer {self.config.ark_api_key}", "Content-Type": "application/json"}

    def generate_image(self, prompt: str, refs: list[str] | None = None) -> str:
        prompt_en = self.llm.translate_visual_prompt(prompt)
        body: dict[str, Any] = {
            "model": self.config.ark_image_model,
            "prompt": prompt_en,
            "size": "1440x2560",
            "response_format": "url",
            "watermark": False,
        }
        if refs:
            body["image"] = refs[:14]
        http = require_requests()
        response = http.post(
            f"{self.config.ark_base_url}/images/generations",
            headers=self.headers,
            data=json.dumps(body),
            proxies=self.config.proxies,
            timeout=240,
        )
        if response.status_code != 200:
            raise RuntimeError(f"Ark image failed HTTP {response.status_code}: {response.text[:500]}")
        return response.json()["data"][0]["url"]

    def generate_video(
        self,
        prompt: str,
        first_frame_url: str,
        duration: int = 5,
        reference_video_urls: list[str] | None = None,
        reference_image_urls: list[str] | None = None,
    ) -> str:
        prompt_en = self.llm.translate_visual_prompt(prompt)
        first_frame_ref = media_ref(first_frame_url)
        content: list[dict[str, Any]] = [
            {"type": "text", "text": f"{prompt_en} --ratio 9:16 --resolution 720p --duration {max(5, min(10, duration))}"},
            {"type": "image_url", "image_url": {"url": first_frame_ref}, "role": "first_frame"},
        ]
        for url in (reference_video_urls or [])[:3]:
            content.append({"type": "video_url", "video_url": {"url": video_url_ref(url)}, "role": "reference_video"})
        for url in (reference_image_urls or [])[:3]:
            content.append({"type": "image_url", "image_url": {"url": media_ref(url)}, "role": "reference_image"})
        http = require_requests()
        response = http.post(
            f"{self.config.ark_base_url}/contents/generations/tasks",
            headers=self.headers,
            data=json.dumps({"model": self.config.ark_video_model, "content": content}),
            proxies=self.config.proxies,
            timeout=120,
        )
        if response.status_code != 200:
            raise RuntimeError(f"Ark video submit failed HTTP {response.status_code}: {response.text[:500]}")
        return self._poll_video(response.json()["id"])

    def generate_video_t2v(
        self,
        prompt: str,
        duration: int = 5,
        reference_image_urls: list[str] | None = None,
        reference_video_urls: list[str] | None = None,
    ) -> str:
        """纯文生视频（无首帧输入图，规避 i2v 的真实人脸 PrivacyInformation 审核）。
        可选传角色定妆图 / 地点 canon 基准图作 reference_image、前镜成片作 reference_video 维持身份/场景/动线一致。
        注意：Ark 限制 first_frame 与 reference 媒体互斥，所以参考媒体只能走本方法（无首帧），不能走 generate_video。"""
        prompt_en = self.llm.translate_visual_prompt(prompt)
        content: list[dict[str, Any]] = [
            {"type": "text", "text": f"{prompt_en} --ratio 9:16 --resolution 720p --duration {max(5, min(10, duration))}"},
        ]
        # 参考图上限放宽到 4（API 若拒收会在提交期 400，由调用方阶梯降级，不产生费用）。
        for url in (reference_image_urls or [])[:4]:
            content.append({"type": "image_url", "image_url": {"url": media_ref(url)}, "role": "reference_image"})
        for url in (reference_video_urls or [])[:3]:
            content.append({"type": "video_url", "video_url": {"url": video_url_ref(url)}, "role": "reference_video"})
        http = require_requests()
        response = http.post(
            f"{self.config.ark_base_url}/contents/generations/tasks",
            headers=self.headers,
            data=json.dumps({"model": self.config.ark_video_model, "content": content}),
            proxies=self.config.proxies,
            timeout=120,
        )
        if response.status_code != 200:
            raise RuntimeError(f"Ark t2v submit failed HTTP {response.status_code}: {response.text[:500]}")
        return self._poll_video(response.json()["id"])

    def _poll_video(self, task_id: str) -> str:
        http = require_requests()
        deadline = time.time() + 900
        consecutive_errors = 0
        while time.time() < deadline:
            time.sleep(6)
            try:
                response = http.get(
                    f"{self.config.ark_base_url}/contents/generations/tasks/{task_id}",
                    headers=self.headers,
                    proxies=self.config.proxies,
                    timeout=60,
                )
            except http.exceptions.RequestException as exc:
                # 代理/SSL 闪断等瞬时网络错误：任务已在服务端计费生成，轮询必须容错重试，
                # 否则会"丢失"已付费的任务（实测 2026-06-11 公司代理闪断导致两条已提交任务被误判失败）。
                consecutive_errors += 1
                if consecutive_errors >= 8:
                    raise RuntimeError(f"Ark video poll network failed after retries: {task_id} -> {exc}") from exc
                time.sleep(min(60, 5 * consecutive_errors))
                continue
            consecutive_errors = 0
            if response.status_code != 200:
                raise RuntimeError(f"Ark video poll failed HTTP {response.status_code}: {response.text[:500]}")
            data = response.json()
            status = data.get("status")
            if status == "succeeded":
                return data["content"]["video_url"]
            if status == "failed":
                raise RuntimeError(f"Ark video failed: {data.get('error')}")
        raise TimeoutError(f"Ark video task timeout: {task_id}")

    def download(self, url: str, path: Path, tries: int = 4) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        http = require_requests()
        last_exc: Exception | None = None
        for attempt in range(1, tries + 1):
            try:
                response = http.get(url, proxies=self.config.proxies, timeout=300)
                response.raise_for_status()
                path.write_bytes(response.content)
                return path
            except Exception as exc:  # noqa: BLE001 - Ark 下载偶发 SSL/EOF/超时，退避重试
                last_exc = exc
                if attempt < tries:
                    time.sleep(2 * attempt)
        raise RuntimeError(f"download failed after {tries} tries: {url} -> {last_exc}")


def parse_json_object(text: str) -> dict[str, Any]:
    cleaned = re.sub(r"^```(?:json)?", "", text.strip()).strip()
    cleaned = re.sub(r"```$", "", cleaned).strip()
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError:
        match = re.search(r"\{[\s\S]*\}", cleaned)
        if not match:
            raise
        data = json.loads(match.group(0))
    if not isinstance(data, dict):
        raise ValueError("Expected JSON object")
    return data


def media_ref(value: str) -> str:
    if value.startswith(("http://", "https://", "data:")):
        return value
    path = Path(value)
    if not path.exists():
        return value
    mime_type = mimetypes.guess_type(path.name)[0] or "image/png"
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime_type};base64,{encoded}"


def video_url_ref(value: str) -> str:
    """Ark 的 reference_video 只接受可访问的 web URL（base64/本地路径会被 400 拒：
    "reference_video must be provided as a web url"）。要复用前镜成片，需在渲染后 24h 内
    使用其 TOS video_url（持久化在 stages/06_videos.json）。"""
    if value.startswith(("http://", "https://")):
        return value
    raise ValueError(f"reference_video 必须是 web URL（Ark 不接受本地文件/base64）：{value[:120]}")
