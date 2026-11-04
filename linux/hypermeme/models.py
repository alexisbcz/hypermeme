"""Templates, text boxes and finished memes. Mirrors the macOS app's models."""

from __future__ import annotations

import time
import uuid
from dataclasses import asdict, dataclass, field, fields, replace

FONTS = ["impact", "arial", "helvetica", "comic", "georgia", "marker"]

FONT_LABELS = {
    "impact": "Impact",
    "arial": "Arial",
    "helvetica": "Helvetica",
    "comic": "Comic Sans",
    "georgia": "Georgia",
    "marker": "Marker",
}

# Pango families for each font, best first. Impact, Comic Sans and Marker Felt aren't on Linux,
# so open look-alikes ship with Hypermeme (see fonts/).
FONT_FAMILIES = {
    "impact": "Impact, Anton",
    "arial": "Arial, Liberation Sans, Noto Sans, DejaVu Sans",
    "helvetica": "Helvetica, Liberation Sans, Noto Sans, DejaVu Sans",
    "comic": "Comic Sans MS, Comic Neue",
    "georgia": "Georgia, Noto Serif, Liberation Serif, DejaVu Serif",
    "marker": "Permanent Marker",
}

# Anton and Permanent Marker have only one weight, which is already bold.
FONT_BOLD = {"impact": False, "marker": False}


def font_from_imgflip(name: str | None) -> str:
    """imgflip's names for its fonts."""
    match (name or "").lower() if name is not None else None:
        case "impact" | None:
            return "impact"
        case "helvetica":
            return "helvetica"
        case "comic sans ms":
            return "comic"
        case "georgia":
            return "georgia"
        case _:
            return "arial"


@dataclass
class TextBox:
    """One piece of text. Positions are fractions of the canvas, so a box means the same thing in
    a small preview and in the full-size export."""

    x: float
    y: float
    width: float
    height: float
    text: str = ""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    rotation: float = 0.0  # degrees clockwise
    font: str = "impact"
    color: str = "#FFFFFF"
    outline: str = "#000000"
    allCaps: bool = True
    align: str = "center"  # left, center, right
    verticalAlign: str = "middle"  # top, middle, bottom
    shadow: bool = False
    # As a fraction of the canvas height. None lets the text grow to fill its box.
    maxFontSize: float | None = None

    @staticmethod
    def top() -> TextBox:
        return TextBox(x=0.03, y=0.02, width=0.94, height=0.24, verticalAlign="top")

    @staticmethod
    def bottom() -> TextBox:
        return TextBox(x=0.03, y=0.74, width=0.94, height=0.24, verticalAlign="bottom")

    @staticmethod
    def defaults(count: int) -> list[TextBox]:
        """The boxes a template without a known layout starts with."""
        if count <= 1:
            return [TextBox.top()]
        if count == 2:
            return [TextBox.top(), TextBox.bottom()]
        height = 0.9 / count
        return [TextBox(x=0.03, y=0.05 + i * height, width=0.94, height=height) for i in range(count)]

    def copy(self, **changes) -> TextBox:
        return replace(self, **changes)

    def to_json(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_json(data: dict) -> TextBox:
        names = {f.name for f in fields(TextBox)}
        return TextBox(**{k: v for k, v in data.items() if k in names})


@dataclass
class MemeTemplate:
    """An image to caption: one of imgflip's templates, or a picture of the user's own."""

    id: str  # imgflip's image key (such as "30b1gx"), or "upload-…"
    name: str
    slug: str | None = None  # the name in imgflip's URLs, such as "Drake-Hotline-Bling"
    fileType: str = "jpg"
    boxCount: int = 2
    altNames: str = ""  # comma separated
    boxes: list[TextBox] | None = None

    @property
    def is_upload(self) -> bool:
        return self.id.startswith("upload-")

    @property
    def image_url(self) -> str | None:
        return None if self.is_upload else f"https://i.imgflip.com/{self.id}.{self.fileType}"

    @property
    def thumbnail_url(self) -> str | None:
        return None if self.is_upload else f"https://i.imgflip.com/4/{self.id}.jpg"

    def starting_boxes(self) -> list[TextBox]:
        boxes = self.boxes if self.boxes is not None else TextBox.defaults(self.boxCount)
        boxes = boxes or TextBox.defaults(2)
        # Fresh ids, so two memes of one template never share boxes.
        return [b.copy(id=str(uuid.uuid4())) for b in boxes]

    def score(self, query: str) -> int | None:
        """Matches every word of a query against the name and the other names.
        Higher is better; None means no match."""
        name = self.name.lower()
        haystack = name + " " + self.altNames.lower()
        words = query.lower().split()
        if not words or not all(w in haystack for w in words):
            return None
        if name == query.lower().strip():
            return 3
        if name.startswith(words[0]):
            return 2
        return 1 if all(w in name for w in words) else 0

    def to_json(self) -> dict:
        data = asdict(self)
        data["boxes"] = None if self.boxes is None else [b.to_json() for b in self.boxes]
        return data

    @staticmethod
    def from_json(data: dict) -> MemeTemplate:
        names = {f.name for f in fields(MemeTemplate)}
        values = {k: v for k, v in data.items() if k in names}
        if values.get("boxes") is not None:
            values["boxes"] = [TextBox.from_json(b) for b in values["boxes"]]
        return MemeTemplate(**values)


CAPTION_STRIP = 0.28


@dataclass
class MemeDocument:
    """Everything needed to draw a meme on top of its template."""

    templateID: str
    boxes: list[TextBox]
    # A white strip above the image for a caption, as a fraction of the image height.
    captionStrip: float = 0.0

    @property
    def caption(self) -> str:
        return " / ".join(b.text for b in self.boxes if b.text)

    @property
    def is_empty(self) -> bool:
        return all(not b.text.strip() for b in self.boxes)

    def set_caption_strip(self, on: bool) -> None:
        """Adds or removes the caption strip, keeping the boxes over the same part of the image."""
        if on == (self.captionStrip > 0):
            return
        if on:
            image = 1 / (1 + CAPTION_STRIP)
            for b in self.boxes:
                b.y = 1 - image + b.y * image
                b.height *= image
            self.captionStrip = CAPTION_STRIP
            caption = TextBox(x=0.03, y=0.01, width=0.94, height=(1 - image) - 0.02)
            caption.font = "helvetica"
            caption.color = "#000000"
            caption.outline = "#FFFFFF"
            caption.allCaps = False
            caption.align = "left"
            self.boxes.insert(0, caption)
        else:
            image = 1 / (1 + self.captionStrip)
            self.boxes = [b for b in self.boxes if not b.y + b.height <= 1 - image + 0.001]
            for b in self.boxes:
                b.y = (b.y - (1 - image)) / image
                b.height /= image
            self.captionStrip = 0.0

    def copy(self) -> MemeDocument:
        return MemeDocument(self.templateID, [b.copy() for b in self.boxes], self.captionStrip)

    def to_json(self) -> dict:
        return {"templateID": self.templateID, "boxes": [b.to_json() for b in self.boxes], "captionStrip": self.captionStrip}

    @staticmethod
    def from_json(data: dict) -> MemeDocument:
        return MemeDocument(data["templateID"], [TextBox.from_json(b) for b in data["boxes"]], data.get("captionStrip", 0.0))

    def same_content(self, other: MemeDocument) -> bool:
        """Equal apart from box ids."""
        def strip(doc):
            return [{k: v for k, v in b.to_json().items() if k != "id"} for b in doc.boxes], doc.captionStrip, doc.templateID
        return strip(self) == strip(other)


@dataclass
class SavedMeme:
    """A finished meme, saved as a PNG in the library."""

    name: str
    document: MemeDocument
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    created: float = field(default_factory=time.time)

    @property
    def caption(self) -> str:
        return self.document.caption

    @property
    def title(self) -> str:
        return self.caption or self.name

    def to_json(self) -> dict:
        return {"id": self.id, "name": self.name, "document": self.document.to_json(), "created": self.created}

    @staticmethod
    def from_json(data: dict) -> SavedMeme:
        return SavedMeme(data["name"], MemeDocument.from_json(data["document"]), data["id"], data.get("created", 0.0))
