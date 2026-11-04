"""What a search field and a section show. Local matches appear at once; imgflip's follow."""

from __future__ import annotations

from typing import Callable

from gi.repository import GLib

from . import imgflip
from .editor import run_async
from .library import Library
from .models import MemeTemplate, SavedMeme

SECTIONS = {
    "popular": ("Popular", "view-grid-symbolic"),
    "recent": ("Recent", "document-open-recent-symbolic"),
    "favorites": ("Favorites", "starred-symbolic"),
    "uploads": ("Your Images", "image-x-generic-symbolic"),
    "memes": ("My Memes", "face-smile-big-symbolic"),
}


class BrowseModel:
    def __init__(self):
        self._section = "popular"
        self._query = ""
        self.remote: list[MemeTemplate] = []
        self.searching = False
        self.search_failed = False
        self.on_change: Callable[[], None] = lambda: None
        self._generation = 0
        self._timer = 0
        self._page = 1
        self._has_more = False
        self._loading_page = False

    @property
    def section(self) -> str:
        return self._section

    @section.setter
    def section(self, value: str) -> None:
        if value != self._section:
            self._section = value
            self._search()

    @property
    def query(self) -> str:
        return self._query

    @query.setter
    def query(self, value: str) -> None:
        if value != self._query:
            self._query = value
            self._search()

    @property
    def trimmed(self) -> str:
        return self._query.strip()

    def templates(self) -> list[MemeTemplate]:
        library = Library.shared()
        query = self.trimmed
        if self._section == "popular":
            if not query:
                return list(library.popular)
            local = library.local_matches(query)
            seen = {t.id for t in local}
            return local + [t for t in self.remote if t.id not in seen]
        if self._section == "recent":
            return self._filtered(library.recent_templates())
        if self._section == "favorites":
            return self._filtered(library.favorite_templates())
        if self._section == "uploads":
            return self._filtered(list(library.uploads))
        return []

    def _filtered(self, templates: list[MemeTemplate]) -> list[MemeTemplate]:
        """A section's own matches, or imgflip's when it has none, so a search always reaches the catalog."""
        query = self.trimmed
        if not query:
            return templates
        matches = [t for t in templates if t.score(query) is not None]
        return matches or self.remote

    def memes(self) -> list[SavedMeme]:
        memes = list(Library.shared().memes)
        words = self.trimmed.lower().split()
        if not words:
            return memes
        return [m for m in memes if all(w in (m.caption + " " + m.name).lower() for w in words)]

    def item_count(self) -> int:
        return len(self.memes()) if self._section == "memes" else len(self.templates())

    def _search(self) -> None:
        self._generation += 1
        if self._timer:
            GLib.source_remove(self._timer)
            self._timer = 0
        self.remote = []
        self._page = 1
        self._has_more = False
        self.search_failed = False
        query = self.trimmed
        if self._section == "memes" or not query:
            self.searching = False
            self.on_change()
            return
        self.searching = True
        self.on_change()
        generation = self._generation

        def start():
            self._timer = 0

            def done(results, error):
                if generation != self._generation:
                    return
                self.searching = False
                if error is not None:
                    self.search_failed = True
                else:
                    self.remote = Library.shared().remember_results(results)
                    self._has_more = bool(results)
                self.on_change()

            run_async(lambda: imgflip.search(query), done)
            return False

        self._timer = GLib.timeout_add(250, start)

    def load_more(self) -> None:
        """Called when the grid scrolls near its end."""
        if self._section == "memes":
            return
        if not self.trimmed:
            if self._section == "popular":
                run_async(Library.shared().load_more)
            return
        if not self._has_more or self._loading_page:
            return
        self._loading_page = True
        self._page += 1
        query, page, generation = self.trimmed, self._page, self._generation

        def done(results, error):
            self._loading_page = False
            if generation != self._generation or error is not None:
                return
            seen = {t.id for t in self.remote}
            self.remote += [t for t in Library.shared().remember_results(results) if t.id not in seen]
            self._has_more = bool(results)
            self.on_change()

        run_async(lambda: imgflip.search(query, page), done)
