from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class StoryforgeConfig:
    llm_base_url: str = "https://coding.dashscope.aliyuncs.com/v1"
    llm_api_key: str = ""
    llm_model: str = "qwen3.6-plus"
    llm_vision_base_url: str = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    llm_vision_model: str = "qwen-vl-max"
    llm_vision_api_key: str = ""  # 留空则回退 llm_api_key；看图守门需要支持视觉模型的端点+key
    ark_base_url: str = "https://ark.cn-beijing.volces.com/api/plan/v3"
    ark_api_key: str = ""
    ark_image_model: str = "doubao-seedream-5.0-lite"
    ark_video_model: str = "doubao-seedance-2.0"
    https_proxy: str = ""

    @property
    def proxies(self) -> dict[str, str] | None:
        if not self.https_proxy:
            return None
        return {"http": self.https_proxy, "https": self.https_proxy}


def load_config(root: Path | None = None) -> StoryforgeConfig:
    root = root or Path.cwd()
    local = _read_local_config(root)

    def pick(env: str, key: str, default: str = "") -> str:
        return os.environ.get(env) or str(local.get(key) or default)

    return StoryforgeConfig(
        llm_base_url=pick("LLM_BASE_URL", "llmBaseUrl", StoryforgeConfig.llm_base_url).rstrip("/"),
        llm_api_key=pick("LLM_API_KEY", "llmApiKey"),
        llm_model=pick("LLM_MODEL", "llmModel", StoryforgeConfig.llm_model),
        llm_vision_base_url=pick("LLM_VISION_BASE_URL", "llmVisionBaseUrl", StoryforgeConfig.llm_vision_base_url).rstrip("/"),
        llm_vision_model=pick("LLM_VISION_MODEL", "llmVisionModel", StoryforgeConfig.llm_vision_model),
        llm_vision_api_key=pick("LLM_VISION_API_KEY", "llmVisionApiKey"),
        ark_base_url=pick("ARK_BASE_URL", "arkBaseUrl", StoryforgeConfig.ark_base_url).rstrip("/"),
        ark_api_key=pick("ARK_API_KEY", "arkApiKey"),
        ark_image_model=pick("ARK_IMAGE_MODEL", "arkImageModel", StoryforgeConfig.ark_image_model),
        ark_video_model=pick("ARK_VIDEO_MODEL", "arkVideoModel", StoryforgeConfig.ark_video_model),
        https_proxy=pick("HTTPS_PROXY", "httpsProxy"),
    )


def _read_local_config(root: Path) -> dict[str, object]:
    for path in [root / "config.local.json", Path.home() / ".storyforge" / "config.local.json"]:
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception:
            continue
    return {}
