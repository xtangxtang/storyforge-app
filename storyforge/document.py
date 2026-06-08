from __future__ import annotations

import hashlib
import re
import zipfile
from pathlib import Path
from typing import Any
from xml.etree import ElementTree


TEXT_SUFFIXES = {".txt", ".md", ".markdown", ".text"}
DOCX_SUFFIXES = {".docx"}
PDF_SUFFIXES = {".pdf"}


def extract_document_text(path: Path) -> dict[str, Any]:
    path = path.expanduser().resolve()
    if not path.exists():
        raise FileNotFoundError(path)
    suffix = path.suffix.lower()
    if suffix in TEXT_SUFFIXES:
        text = read_text_file(path)
        parser = "text"
    elif suffix in DOCX_SUFFIXES:
        text = extract_docx_text(path)
        parser = "docx-stdlib"
    elif suffix in PDF_SUFFIXES:
        text = extract_pdf_text(path)
        parser = "pypdf"
    elif suffix == ".doc":
        raise ValueError("Unsupported legacy .doc file. Convert it to .docx or .pdf first.")
    else:
        raise ValueError(f"Unsupported document type: {suffix or '(no extension)'}")
    cleaned = normalize_text(text)
    if not cleaned:
        raise ValueError(f"No readable text extracted from {path}")
    return {
        "source_path": str(path),
        "source_name": path.name,
        "suffix": suffix,
        "parser": parser,
        "text": cleaned,
        "character_count": len(cleaned),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def read_text_file(path: Path) -> str:
    for encoding in ["utf-8", "utf-8-sig", "gb18030"]:
        try:
            return path.read_text(encoding=encoding)
        except UnicodeDecodeError:
            continue
    return path.read_text(errors="replace")


def extract_docx_text(path: Path) -> str:
    paragraphs: list[str] = []
    with zipfile.ZipFile(path) as archive:
        xml_bytes = archive.read("word/document.xml")
    root = ElementTree.fromstring(xml_bytes)
    namespace = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    for paragraph in root.findall(".//w:p", namespace):
        parts = [node.text or "" for node in paragraph.findall(".//w:t", namespace)]
        text = "".join(parts).strip()
        if text:
            paragraphs.append(text)
    return "\n\n".join(paragraphs)


def extract_pdf_text(path: Path) -> str:
    try:
        from pypdf import PdfReader
    except ModuleNotFoundError as exc:
        raise RuntimeError("Missing dependency: pypdf. Run `pip install -e .` or `pip install pypdf`.") from exc
    reader = PdfReader(str(path))
    pages = []
    for page in reader.pages:
        pages.append(page.extract_text() or "")
    return "\n\n".join(pages)


def normalize_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{4,}", "\n\n\n", text)
    return text.strip()


def derive_project_id(source_name: str, text: str, existing_ids: set[str] | None = None) -> str:
    existing_ids = existing_ids or set()
    title = infer_title(source_name, text)
    base = safe_slug(title)
    digest = hashlib.sha1(text.encode("utf-8", errors="ignore")).hexdigest()[:8]
    candidate = f"{base}-{digest}" if base else f"story-{digest}"
    if candidate not in existing_ids:
        return candidate
    index = 2
    while f"{candidate}-{index}" in existing_ids:
        index += 1
    return f"{candidate}-{index}"


def infer_title(source_name: str, text: str) -> str:
    for line in text.splitlines()[:30]:
        cleaned = line.strip().strip("#").strip()
        if 2 <= len(cleaned) <= 40 and not re.match(r"^(scene|场|第[一二三四五六七八九十\d]+)", cleaned, re.I):
            return cleaned
    return Path(source_name).stem


def safe_slug(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"\s+", "-", value)
    value = re.sub(r"[^a-z0-9\-\u4e00-\u9fff]+", "", value)
    value = value.strip("-")
    return value[:48] or "story"
