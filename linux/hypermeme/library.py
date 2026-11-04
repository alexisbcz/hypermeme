"""The templates, favorites and finished memes, kept in $XDG_DATA_HOME/hypermeme.

Network calls block, so the app calls them from worker threads; a lock keeps the state whole.
"""

from __future__ import annotations

import json
import os
import shutil
import threading
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Callable

from . import imgflip, renderer
from .models import MemeDocument, MemeTemplate, SavedMeme


def data_dir() -> Path:
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return Path(base) / "hypermeme"


def cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return Path(base) / "hypermeme"


class Library:
    _shared: Library | None = None

    @classmethod
    def shared(cls) -> Library:
        if cls._shared is None:
            cls._shared = Library(data_dir())
        return cls._shared

    def __init__(self, folder: Path):
        self.folder = Path(folder)
        for name in ("Templates", "Memes"):
            (self.folder / name).mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.popular: list[MemeTemplate] = []
        self.uploads: list[MemeTemplate] = []
        self.memes: list[SavedMeme] = []
        self.favorites: list[str] = []
        self.recents: list[str] = []
        self.known: dict[str, MemeTemplate] = {}
        self.catalog_date = 0.0
        self.load_failed = False
        self.can_load_more = True
        self.next_page = 3  # page 3 of imgflip's listing is where the API's 100 run out
        self._loading_more = False
        # Called (from any thread) after anything changes.
        self.listeners: list[Callable[[], None]] = []
        self._load()

    def on_change(self) -> None:
        for listener in list(self.listeners):
            listener()

    @property
    def state_file(self) -> Path:
        return self.folder / "library.json"

    def _load(self) -> None:
        try:
            state = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            return
        try:
            self.popular = [MemeTemplate.from_json(t) for t in state.get("popular", [])]
            self.known = {k: MemeTemplate.from_json(t) for k, t in state.get("known", {}).items()}
            self.catalog_date = state.get("catalogDate", 0.0)
            self.uploads = [MemeTemplate.from_json(t) for t in state.get("uploads", [])]
            self.memes = [SavedMeme.from_json(m) for m in state.get("memes", [])]
            self.favorites = list(state.get("favorites", []))
            self.recents = list(state.get("recents", []))
        except (KeyError, TypeError):
            pass

    def save(self) -> None:
        with self.lock:
            state = {
                "popular": [t.to_json() for t in self.popular],
                "known": {k: t.to_json() for k, t in self.known.items()},
                "catalogDate": self.catalog_date,
                "uploads": [t.to_json() for t in self.uploads],
                "memes": [m.to_json() for m in self.memes],
                "favorites": self.favorites,
                "recents": self.recents,
            }
            temp = self.state_file.with_suffix(".tmp")
            temp.write_text(json.dumps(state))
            temp.replace(self.state_file)
        self.on_change()

    # Catalog

    def refresh(self, force: bool = False) -> None:
        """Fetches the popular templates, at most once a day. The cached list shows meanwhile."""
        if not force and self.popular and time.time() - self.catalog_date < 86_400:
            return
        try:
            listing = imgflip.popular()
        except imgflip.Failure:
            with self.lock:
                self.load_failed = not self.popular
            self.on_change()
            return
        with self.lock:
            self.popular = [self.merged(t) for t in listing]
            for t in self.popular:
                self.known.setdefault(t.id, t)
            self.catalog_date = time.time()
            self.load_failed = False
        # Any generator page carries the layouts and other names of the top templates.
        try:
            self._remember(imgflip.details("Drake-Hotline-Bling"))
        except imgflip.Failure:
            pass
        self.save()

    def load_more(self) -> None:
        with self.lock:
            if not self.can_load_more or self._loading_more or not self.popular:
                return
            self._loading_more = True
            page = self.next_page
        try:
            listing = imgflip.templates(page)
        except imgflip.Failure:
            listing = None
        with self.lock:
            self._loading_more = False
            if listing is None:
                return
            self.next_page += 1
            seen = {t.id for t in self.popular}
            self.popular += [self.merged(t) for t in listing if t.id not in seen]
            self.can_load_more = bool(listing)
        self.on_change()

    def merged(self, template: MemeTemplate) -> MemeTemplate:
        """Fills in what's already known about a template from a thinner listing."""
        known = self.known.get(template.id)
        if known is None:
            return template
        result = MemeTemplate(**{**template.__dict__})
        result.slug = template.slug or known.slug
        result.boxes = known.boxes
        result.altNames = known.altNames
        if known.boxes is not None:
            result.boxCount = known.boxCount
        return result

    def _remember(self, details: list[MemeTemplate]) -> None:
        with self.lock:
            for t in details:
                self.known[t.id] = t
            self.popular = [self.merged(t) for t in self.popular]

    def remember_results(self, results: list[MemeTemplate]) -> list[MemeTemplate]:
        with self.lock:
            merged = [self.merged(t) for t in results]
            for t in merged:
                self.known.setdefault(t.id, t)
            return merged

    def template(self, template_id: str) -> MemeTemplate | None:
        with self.lock:
            for t in self.uploads:
                if t.id == template_id:
                    return t
            if template_id in self.known:
                return self.known[template_id]
            return next((t for t in self.popular if t.id == template_id), None)

    def favorite_templates(self) -> list[MemeTemplate]:
        return [t for t in map(self.template, self.favorites) if t]

    def recent_templates(self) -> list[MemeTemplate]:
        return [t for t in map(self.template, self.recents) if t]

    def local_matches(self, query: str) -> list[MemeTemplate]:
        """Every template Hypermeme has seen that matches, best first."""
        with self.lock:
            popular_ids = {t.id for t in self.popular}
            everything = self.uploads + self.popular + [t for t in self.known.values() if t.id not in popular_ids]
        scored = [(t, s) for t in everything if (s := t.score(query)) is not None]
        # Stable sort keeps catalog order among equal scores.
        return [t for t, _ in sorted(scored, key=lambda pair: -pair[1])]

    def resolved(self, template: MemeTemplate) -> MemeTemplate:
        """Looks up imgflip's layout for a template, if it isn't known yet."""
        if template.is_upload or template.boxes is not None:
            return template
        slug = template.slug or template.name.replace(" ", "-")
        try:
            details = imgflip.details(slug)
        except imgflip.Failure:
            return template
        self._remember(details)
        found = next((t for t in details if t.id == template.id), None)
        if found is None:
            return template
        self.save()
        return found

    def template_file(self, template: MemeTemplate) -> Path:
        ext = "png" if template.is_upload else template.fileType
        return self.folder / "Templates" / f"{template.id}.{ext}"

    def image_path(self, template: MemeTemplate) -> Path:
        """The template's full image, downloaded the first time."""
        file = self.template_file(template)
        if not file.exists() and template.image_url:
            data = imgflip.fetch(template.image_url)
            temp = file.with_suffix(".part")
            temp.write_bytes(data)
            temp.replace(file)
        if not file.exists():
            raise imgflip.Failure("image missing")
        return file

    def thumbnail_path(self, template: MemeTemplate) -> Path | None:
        """A small image for the grid. Uploads and opened templates use the file they have."""
        full = self.template_file(template)
        if full.exists():
            return full
        if not template.thumbnail_url:
            return None
        folder = cache_dir() / "thumbnails"
        folder.mkdir(parents=True, exist_ok=True)
        file = folder / f"{template.id}.jpg"
        if not file.exists():
            request = urllib.request.Request(template.thumbnail_url, headers={"User-Agent": imgflip.USER_AGENT})
            with urllib.request.urlopen(request, timeout=imgflip.TIMEOUT) as response:
                data = response.read()
            temp = file.with_suffix(f".{uuid.uuid4().hex}.part")
            temp.write_bytes(data)
            temp.replace(file)
        return file

    # Favorites and recents

    def is_favorite(self, template: MemeTemplate) -> bool:
        return template.id in self.favorites

    def toggle_favorite(self, template: MemeTemplate) -> None:
        with self.lock:
            self.known.setdefault(template.id, template)
            if template.id in self.favorites:
                self.favorites.remove(template.id)
            else:
                self.favorites.insert(0, template.id)
        self.save()

    def note_used(self, template: MemeTemplate) -> None:
        with self.lock:
            if not template.is_upload:
                self.known.setdefault(template.id, template)
            self.recents = [template.id] + [r for r in self.recents if r != template.id]
            self.recents = self.recents[:60]

    # Your images

    def add_upload(self, path: str | Path, name: str | None = None) -> MemeTemplate | None:
        """Makes a template of an image file. EXIF rotation is applied, and huge photos scaled down."""
        try:
            pixbuf = renderer.GdkPixbuf.Pixbuf.new_from_file(str(path))
        except Exception:
            return None
        pixbuf = pixbuf.apply_embedded_orientation() or pixbuf
        longest = max(pixbuf.get_width(), pixbuf.get_height())
        if longest > 2400:
            factor = 2400 / longest
            pixbuf = pixbuf.scale_simple(
                round(pixbuf.get_width() * factor), round(pixbuf.get_height() * factor), renderer.GdkPixbuf.InterpType.HYPER
            )
        template = MemeTemplate(id=f"upload-{uuid.uuid4()}", name=name or Path(path).stem, fileType="png")
        try:
            pixbuf.savev(str(self.template_file(template)), "png", [], [])
        except Exception:
            return None
        with self.lock:
            self.uploads.insert(0, template)
        self.save()
        return template

    def delete_upload(self, template: MemeTemplate) -> None:
        with self.lock:
            self.uploads = [t for t in self.uploads if t.id != template.id]
            self.favorites = [f for f in self.favorites if f != template.id]
            self.recents = [r for r in self.recents if r != template.id]
        self.template_file(template).unlink(missing_ok=True)
        self.save()

    # Finished memes

    def file(self, meme: SavedMeme) -> Path:
        return self.folder / "Memes" / f"{meme.id}.png"

    def save_meme(self, document: MemeDocument, image, template: MemeTemplate) -> SavedMeme | None:
        """Writes the full-size PNG. Saving the same meme twice gives back the first copy."""
        self.note_used(template)
        with self.lock:
            existing = next((m for m in self.memes if m.document.same_content(document)), None)
        if existing and self.file(existing).exists():
            self.move_to_top(existing)
            return existing
        try:
            png = renderer.png_bytes(renderer.render(image, document))
        except Exception:
            return None
        meme = SavedMeme(name=template.name, document=document.copy())
        self.file(meme).write_bytes(png)
        with self.lock:
            self.memes.insert(0, meme)
        self.save()
        return meme

    def delete_meme(self, meme: SavedMeme) -> None:
        with self.lock:
            self.memes = [m for m in self.memes if m.id != meme.id]
        self.file(meme).unlink(missing_ok=True)
        self.save()

    def move_to_top(self, meme: SavedMeme) -> None:
        with self.lock:
            rest = [m for m in self.memes if m.id != meme.id]
            if len(rest) == len(self.memes):
                return
            self.memes = [meme] + rest
        self.save()

    def download(self, meme: SavedMeme, folder: Path | None = None) -> Path:
        """Copies the PNG into Downloads without replacing anything there."""
        folder = folder or downloads_dir()
        folder.mkdir(parents=True, exist_ok=True)
        target = free_file(meme.name, folder)
        shutil.copyfile(self.file(meme), target)
        return target


def free_file(name: str, folder: Path) -> Path:
    """"Name.png", or "Name 2.png" and so on when that's taken."""
    base = name.replace("/", "-").replace(":", "-").strip().strip(".").strip() or "Meme"
    target = folder / f"{base}.png"
    number = 2
    while target.exists():
        target = folder / f"{base} {number}.png"
        number += 1
    return target


def downloads_dir() -> Path:
    try:
        import subprocess

        out = subprocess.run(["xdg-user-dir", "DOWNLOAD"], capture_output=True, text=True, timeout=2).stdout.strip()
        if out and out != os.path.expanduser("~"):
            return Path(out)
    except Exception:
        pass
    return Path(os.path.expanduser("~/Downloads"))
