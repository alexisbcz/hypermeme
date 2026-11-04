"""One meme being captioned. The main window and the quick panel both work on this."""

from __future__ import annotations

import threading
from typing import Callable

from gi.repository import GLib

from . import renderer
from .library import Library
from .models import MemeDocument, MemeTemplate, SavedMeme, TextBox

PREVIEW_WIDTH = 1400.0


def run_async(work: Callable, done: Callable | None = None) -> None:
    """Runs `work` on a thread and hands its result (or exception) to `done` on the main loop."""

    def body():
        try:
            result, error = work(), None
        except Exception as e:  # noqa: BLE001
            result, error = None, e
        if done:
            GLib.idle_add(lambda: (done(result, error), False)[1])

    threading.Thread(target=body, daemon=True).start()


class MemeEditor:
    def __init__(self, template: MemeTemplate, document: MemeDocument | None = None):
        self.template = template
        self.document = document.copy() if document else MemeDocument(template.id, template.starting_boxes())
        self.image = None  # cairo.ImageSurface of the template
        self.preview = None  # rendered preview surface
        self.failed = False
        self.loaded = False
        self.selection: str | None = self.document.boxes[0].id if self.document.boxes else None
        self.prefilled: list[str] = []
        self.listeners: list[Callable[[str], None]] = []  # called with "layout" or "preview"
        self._render_generation = 0
        self._rendering = False
        self._dirty = False

    @staticmethod
    def from_meme(meme: SavedMeme) -> MemeEditor | None:
        template = Library.shared().template(meme.document.templateID)
        return MemeEditor(template, meme.document) if template else None

    def notify(self, what: str) -> None:
        for listener in list(self.listeners):
            listener(what)

    def load(self) -> None:
        library = Library.shared()
        untouched = self.document.is_empty and self.document.captionStrip == 0
        template = self.template

        def work():
            resolved = library.resolved(template)
            image = renderer.load_image(library.image_path(resolved))
            return resolved, image

        def done(result, error):
            if error is not None:
                # The layout may have resolved even if the image didn't; try the image alone next time.
                self.failed = True
                self.notify("layout")
                return
            resolved, image = result
            # A newer layout only replaces boxes nobody has typed in.
            if resolved.boxes is not None and self.template.boxes is None and untouched and self.document.is_empty:
                self.document.boxes = resolved.starting_boxes()
                self.selection = self.document.boxes[0].id if self.document.boxes else None
            self.template = resolved
            for index, text in enumerate(self.prefilled):
                if index < len(self.document.boxes):
                    self.document.boxes[index].text = text
            self.prefilled = []
            self.image = image
            self.loaded = True
            self.failed = False
            self.notify("layout")
            self.changed()

        run_async(work, done)

    def box(self, box_id: str | None) -> TextBox | None:
        return next((b for b in self.document.boxes if b.id == box_id), None)

    def changed(self) -> None:
        """Re-renders the preview after the document changed. Only one render runs at a time,
        and the last change always gets drawn."""
        if self.image is None:
            return
        if self._rendering:
            self._dirty = True
            return
        self._rendering = True
        self._dirty = False
        image, document = self.image, self.document.copy()
        width = min(max(image.get_width(), 800), PREVIEW_WIDTH)

        def done(result, error):
            self._rendering = False
            if result is not None:
                self.preview = result
                self.notify("preview")
            if self._dirty:
                self.changed()

        run_async(lambda: renderer.render(image, document, width), done)

    def add_box(self) -> None:
        box = TextBox(x=0.2, y=0.4, width=0.6, height=0.2)
        self.document.boxes.append(box)
        self.selection = box.id
        self.notify("layout")
        self.changed()

    def remove(self, box_id: str) -> None:
        self.document.boxes = [b for b in self.document.boxes if b.id != box_id]
        self.selection = self.document.boxes[0].id if self.document.boxes else None
        self.notify("layout")
        self.changed()

    def set_caption_strip(self, on: bool) -> None:
        self.document.set_caption_strip(on)
        if self.box(self.selection) is None:
            self.selection = self.document.boxes[0].id if self.document.boxes else None
        self.notify("layout")
        self.changed()

    def finish(self) -> SavedMeme | None:
        """Saves the meme to the library."""
        if self.image is None:
            return None
        return Library.shared().save_meme(self.document, self.image, self.template)
