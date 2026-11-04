"""Draws captions onto an image with Cairo and Pango. The preview and the export both come from
here, so what the editor shows is what gets pasted."""

from __future__ import annotations

import io
import math
import threading
from pathlib import Path

import cairo
import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, Pango, PangoCairo  # noqa: E402

from .models import FONT_BOLD, FONT_FAMILIES, MemeDocument, TextBox  # noqa: E402

# Small templates are enlarged to this width so the text stays sharp.
MINIMUM_EXPORT_WIDTH = 1000.0

FONTS_DIR = Path(__file__).parent / "fonts"
# PangoCairo's default font map belongs to the thread that asks for it, and previews render on
# worker threads, so each thread's map gets the bundled fonts the first time it draws.
_registered = threading.local()


def register_fonts() -> None:
    """Makes the bundled look-alikes of Impact, Comic Sans and Marker Felt available to Pango."""
    font_map = PangoCairo.FontMap.get_default()
    if getattr(_registered, "font_map", None) is font_map:
        return
    _registered.font_map = font_map
    for file in sorted(FONTS_DIR.glob("*.ttf")):
        try:
            font_map.add_font_file(str(file))
        except Exception:
            pass


def load_image(path: str | Path) -> cairo.ImageSurface:
    """Reads any image GdkPixbuf knows, applying EXIF rotation."""
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(path))
    return surface_from_pixbuf(pixbuf.apply_embedded_orientation() or pixbuf)


def surface_from_pixbuf(pixbuf: GdkPixbuf.Pixbuf) -> cairo.ImageSurface:
    ok, data = pixbuf.save_to_bufferv("png", [], [])
    if not ok:
        raise ValueError("couldn't read image")
    return cairo.ImageSurface.create_from_png(io.BytesIO(data))


def render(image: cairo.ImageSurface, document: MemeDocument, width: float | None = None) -> cairo.ImageSurface:
    """Draws at `width` pixels wide; None uses the export size."""
    register_fonts()
    image_width, image_height = image.get_width(), image.get_height()
    scale = (width or max(image_width, MINIMUM_EXPORT_WIDTH)) / image_width
    drawn_height = round(image_height * scale)
    canvas_w = round(image_width * scale)
    canvas_h = round(drawn_height * (1 + document.captionStrip))

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, canvas_w, canvas_h)
    ctx = cairo.Context(surface)
    ctx.set_source_rgb(1, 1, 1)
    ctx.paint()

    ctx.save()
    ctx.translate(0, canvas_h - drawn_height)
    ctx.scale(canvas_w / image_width, drawn_height / image_height)
    ctx.set_source_surface(image, 0, 0)
    ctx.get_source().set_filter(cairo.FILTER_GOOD)
    # Without padding, scaling blends the image's edges with the transparency around it.
    ctx.get_source().set_extend(cairo.EXTEND_PAD)
    ctx.rectangle(0, 0, image_width, image_height)
    ctx.fill()
    ctx.restore()

    for box in document.boxes:
        if box.text:
            _draw(box, ctx, canvas_w, canvas_h)
    surface.flush()
    return surface


def png_bytes(surface: cairo.ImageSurface) -> bytes:
    out = io.BytesIO()
    surface.write_to_png(out)
    return out.getvalue()


# Text

_measure = threading.local()


def _measure_ctx() -> cairo.Context:
    if not hasattr(_measure, "ctx"):
        _measure.ctx = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))
    return _measure.ctx


def _font_options() -> cairo.FontOptions:
    options = cairo.FontOptions()
    # Unhinted metrics, so a size measures the same at every scale.
    options.set_hint_metrics(cairo.HINT_METRICS_OFF)
    options.set_hint_style(cairo.HINT_STYLE_NONE)
    options.set_antialias(cairo.ANTIALIAS_GRAY)
    return options


def _layout(ctx: cairo.Context, text: str, font: str, size: float, align: str, width: float | None) -> Pango.Layout:
    register_fonts()
    layout = PangoCairo.create_layout(ctx)
    PangoCairo.context_set_font_options(layout.get_context(), _font_options())
    layout.context_changed()
    description = Pango.FontDescription.from_string(FONT_FAMILIES.get(font, FONT_FAMILIES["arial"]))
    if FONT_BOLD.get(font, True):
        description.set_weight(Pango.Weight.BOLD)
    description.set_absolute_size(max(size, 1) * Pango.SCALE)
    layout.set_font_description(description)
    layout.set_text(text, -1)
    if width is not None:
        layout.set_width(int(width * Pango.SCALE))
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
    layout.set_alignment({"left": Pango.Alignment.LEFT, "right": Pango.Alignment.RIGHT}.get(align, Pango.Alignment.CENTER))
    return layout


def _size(layout: Pango.Layout) -> tuple[float, float]:
    _, logical = layout.get_extents()
    return logical.width / Pango.SCALE, logical.height / Pango.SCALE


def fitted_size(text: str, font: str, room_w: float, room_h: float, maximum: float) -> float:
    """The largest size at which `text` fits, without breaking a word across lines."""
    words = text.split()
    measure = _measure_ctx()

    def fits(size: float) -> bool:
        longest = max((_size(_layout(measure, w, font, size, "left", None))[0] for w in words), default=0)
        if longest > room_w:
            return False
        return _size(_layout(measure, text, font, size, "left", room_w))[1] <= room_h

    low, high = 4.0, max(maximum, 4.0)
    if fits(high):
        return high
    while high - low > 0.5:
        middle = (low + high) / 2
        if fits(middle):
            low = middle
        else:
            high = middle
    return low


def _rgb(hex_color: str) -> tuple[float, float, float]:
    """Reads "#RRGGBB"; anything else is black."""
    try:
        value = int(hex_color.lstrip("#")[:6], 16)
    except ValueError:
        value = 0
    return (value >> 16 & 0xFF) / 255, (value >> 8 & 0xFF) / 255, (value & 0xFF) / 255


def _draw(box: TextBox, ctx: cairo.Context, canvas_w: float, canvas_h: float) -> None:
    rx, ry = box.x * canvas_w, box.y * canvas_h
    rw, rh = box.width * canvas_w, box.height * canvas_h
    if rw <= 1 or rh <= 1:
        return
    text = box.text.upper() if box.allCaps else box.text
    inset = max(2.0, canvas_w * 0.006)
    room_w, room_h = rw - inset * 2, rh - inset * 2
    maximum = box.maxFontSize * canvas_h if box.maxFontSize else canvas_h / 3
    size = fitted_size(text, box.font, room_w, room_h, maximum)

    layout = _layout(ctx, text, box.font, size, box.align, room_w)
    _, needed_h = _size(layout)
    if box.verticalAlign == "top":
        top = ry + inset
    elif box.verticalAlign == "bottom":
        top = ry + rh - inset - needed_h
    else:
        top = ry + rh / 2 - needed_h / 2

    ctx.save()
    ctx.translate(rx + rw / 2, ry + rh / 2)
    ctx.rotate(math.radians(box.rotation))
    ctx.translate(rx + inset - (rx + rw / 2), top - (ry + rh / 2))
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)

    PangoCairo.update_layout(ctx, layout)
    PangoCairo.layout_path(ctx, layout)
    path = ctx.copy_path()
    ctx.new_path()
    outline = _rgb(box.outline)

    if box.shadow:
        # Cairo has no blur, so a few soft, widening strokes stand in for one.
        for step in range(4, 0, -1):
            ctx.append_path(path)
            ctx.set_source_rgba(*outline, 0.14)
            ctx.set_line_width(max(1, size * (0.11 + 0.07 * step)))
            ctx.stroke()

    ctx.append_path(path)
    ctx.set_source_rgb(*outline)
    ctx.set_line_width(max(1, size * 0.11))
    ctx.stroke()

    ctx.append_path(path)
    ctx.set_source_rgb(*_rgb(box.color))
    ctx.fill()
    ctx.restore()
