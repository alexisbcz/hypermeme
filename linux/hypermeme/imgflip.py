"""imgflip's public template catalog.

Its API lists only the 100 most popular templates and hides search behind a paid plan, so
browsing further and searching read the public pages. The generator pages also embed each
template's text layout, which is what makes a Drake caption land next to Drake.
"""

from __future__ import annotations

import html as htmllib
import json
import re
import urllib.parse
import urllib.request

from .models import MemeTemplate, TextBox, font_from_imgflip

USER_AGENT = "Hypermeme (+https://github.com/alexisbcz/hypermeme)"
TIMEOUT = 15


class Failure(Exception):
    """imgflip sent back something unexpected, or couldn't be reached."""


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            if response.status != 200:
                raise Failure(f"HTTP {response.status}")
            return response.read()
    except Failure:
        raise
    except Exception as error:  # network, TLS, timeouts
        raise Failure(str(error)) from error


# Requests


def popular() -> list[MemeTemplate]:
    return parse_api(fetch("https://api.imgflip.com/get_memes"))


def templates(page: int) -> list[MemeTemplate]:
    """Later pages of the most popular templates. Page 1 is the same list as popular()."""
    return parse_listing(fetch(f"https://imgflip.com/memetemplates?page={page}").decode("utf-8", "replace"))


def search(query: str, page: int = 1) -> list[MemeTemplate]:
    q = urllib.parse.urlencode({"q": query, "page": page})
    return parse_listing(fetch(f"https://imgflip.com/memesearch?{q}").decode("utf-8", "replace"))


def details(slug: str) -> list[MemeTemplate]:
    """One generator page lists the popular templates and the one it's for, with their layouts."""
    url = "https://imgflip.com/memegenerator/" + urllib.parse.quote(slug)
    return parse_generator(fetch(url).decode("utf-8", "replace"))


# Parsing


def parse_api(data: bytes) -> list[MemeTemplate]:
    try:
        memes = json.loads(data)["data"]["memes"]
    except (ValueError, KeyError, TypeError) as error:
        raise Failure("bad API response") from error
    result = []
    for meme in memes:
        path = urllib.parse.urlparse(meme["url"]).path.rsplit("/", 1)[-1]
        key, _, ext = path.rpartition(".")
        result.append(MemeTemplate(id=key, name=meme["name"], fileType=ext or "jpg", boxCount=int(meme.get("box_count", 2))))
    return result


_SLUG = re.compile(r'href="/memegenerator/([^"?]+)"')
_KEY = re.compile(r"i\.imgflip\.com/\d/([a-z0-9]+)\.[a-z]+")
_TITLE = re.compile(r'<h3 class="mt-title">\s*<a[^>]*>([^<]+)</a>')


def parse_listing(page: str) -> list[MemeTemplate]:
    """Reads the cards of a /memetemplates or /memesearch page, leaving out animated templates."""
    result = []
    for card in page.split('class="mt-box"')[1:]:
        if 'href="/memegenerator/' not in card:
            continue
        slug, key, name = _SLUG.search(card), _KEY.search(card), _TITLE.search(card)
        if not (slug and key and name):
            continue
        result.append(MemeTemplate(id=key.group(1), name=htmllib.unescape(name.group(1)).strip(), slug=slug.group(1)))
    return result


def parse_generator(page: str) -> list[MemeTemplate]:
    """Reads the `memes=` data of a generator page: an array, or an object when the page is for a
    template outside the popular ones."""
    start = page.find("memes=")
    if start < 0:
        return []
    raw = balanced_json(page[start + len("memes="):])
    if raw is None:
        return []
    try:
        value = json.loads(raw)
    except ValueError:
        return []
    if isinstance(value, dict):
        value = list(value.values())
    if not isinstance(value, list):
        return []
    return [t for t in (_template(e) for e in value if isinstance(e, dict)) if t]


def _template(entry: dict) -> MemeTemplate | None:
    if not isinstance(entry.get("id"), int) or not isinstance(entry.get("name"), str):
        return None
    template = MemeTemplate(
        id=_base36(entry["id"]),
        name=entry["name"],
        slug=entry.get("url_name"),
        fileType=entry.get("file_type") or "jpg",
        altNames=entry.get("altNames") or "",
    )
    width, height = _number(entry.get("w")), _number(entry.get("h"))
    settings = entry.get("default_settings")
    if isinstance(settings, str) and width and height and width > 0 and height > 0:
        try:
            raw = json.loads(settings)
        except ValueError:
            raw = None
        if isinstance(raw, list):
            boxes = [b for b in (_box(r, width, height) for r in raw if isinstance(r, dict)) if b]
            if boxes:
                template.boxes = boxes
                template.boxCount = len(boxes)
    return template


def _box(raw: dict, width: float, height: float) -> TextBox | None:
    if (raw.get("type") or "text") != "text":
        return None
    x, y, w, h = (_number(raw.get(k)) for k in "xywh")
    if None in (x, y, w, h):
        return None
    box = TextBox(x=x / width, y=y / height, width=w / width, height=h / height)
    box.rotation = _number(raw.get("rotation")) or 0.0
    box.font = font_from_imgflip(raw.get("font"))
    if isinstance(raw.get("font_color"), str):
        box.color = raw["font_color"].upper()
    if isinstance(raw.get("outline_color"), str):
        box.outline = raw["outline_color"].upper()
    box.allCaps = raw.get("force_caps", True) if isinstance(raw.get("force_caps", True), bool) else True
    if raw.get("text_align") in ("left", "center", "right"):
        box.align = raw["text_align"]
    if raw.get("vertical_align") in ("top", "middle", "bottom"):
        box.verticalAlign = raw["vertical_align"]
    box.shadow = bool(raw.get("font_shadow", False))
    size = _number(raw.get("font_max_size"))
    box.maxFontSize = size / height if size else None
    return box


def _number(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _base36(number: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if number == 0:
        return "0"
    out = ""
    while number:
        number, rest = divmod(number, 36)
        out = digits[rest] + out
    return out


def balanced_json(text: str) -> str | None:
    """The JSON array or object at the start of `text`, up to its matching close."""
    depth = 0
    in_string = escaped = False
    for offset, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "[{":
            depth += 1
        elif char in "]}":
            depth -= 1
            if depth == 0:
                return text[: offset + 1]
        elif depth == 0:
            return None
    return None
