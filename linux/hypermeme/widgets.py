"""The template grid, its cells and the meme canvas, shared by the panel and the main window."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from typing import Callable

import math

import cairo
from gi.repository import Adw, Gdk, GdkPixbuf, GLib, Gtk, Pango

from .browse import BrowseModel
from .editor import MemeEditor
from .library import Library
from .models import MemeTemplate, SavedMeme

THUMB = 320

_textures: dict[str, Gdk.Texture] = {}
_waiting: dict[str, list[Callable]] = {}
_pool = ThreadPoolExecutor(max_workers=6)


def thumbnail(key: str, path_for: Callable[[], object], ready: Callable[[Gdk.Texture], None]) -> None:
    """Loads a small texture once, off the main thread, and hands it to every caller that asked."""
    if key in _textures:
        ready(_textures[key])
        return
    if key in _waiting:
        _waiting[key].append(ready)
        return
    _waiting[key] = [ready]

    def work():
        try:
            path = path_for()
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(path), THUMB, THUMB, True) if path else None
            texture = Gdk.Texture.new_for_pixbuf(pixbuf) if pixbuf else None
        except Exception:
            texture = None
        GLib.idle_add(finish, texture)

    def finish(texture):
        callbacks = _waiting.pop(key, [])
        if texture is not None:
            _textures[key] = texture
            for callback in callbacks:
                callback(texture)
        return False

    _pool.submit(work)


def forget_thumbnail(key: str) -> None:
    _textures.pop(key, None)


class Cell(Gtk.Box):
    def __init__(self, title: str, height: int):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.add_css_class("hm-cell")
        self.picture = Gtk.Picture(content_fit=Gtk.ContentFit.COVER, can_shrink=True)
        self.picture.add_css_class("hm-thumb")
        self.picture.set_size_request(-1, height)
        self.picture.set_overflow(Gtk.Overflow.HIDDEN)
        self.append(self.picture)
        label = Gtk.Label(label=title, ellipsize=Pango.EllipsizeMode.END, xalign=0, max_width_chars=1, hexpand=True)
        label.add_css_class("hm-cell-title")
        self.append(label)
        self.set_tooltip_text(title)

    def show(self, texture: Gdk.Texture) -> None:
        self.picture.set_paintable(texture)


class Grid(Gtk.Box):
    """A section's templates or memes, with a keyboard selection and endless scrolling."""

    def __init__(self, browse: BrowseModel, columns: int | None, cell_height: int, parent_window: Callable[[], Gtk.Window]):
        """With `columns` None, the grid fits as many columns as the width allows."""
        super().__init__(orientation=Gtk.Orientation.VERTICAL, vexpand=True)
        self.browse = browse
        self._columns = columns
        self.cell_height = cell_height
        self.parent_window = parent_window
        self.selected = 0
        self.on_template: Callable[[MemeTemplate], None] = lambda t: None
        self.on_meme: Callable[[SavedMeme], None] = lambda m: None
        self.on_edit_meme: Callable[[SavedMeme], None] = lambda m: None
        self.on_toast: Callable[[str], None] = lambda s: None
        self._keys: list[str] = []
        self._items: list = []
        self._cells: list[Cell] = []

        self.stack = Gtk.Stack(vexpand=True, transition_type=Gtk.StackTransitionType.CROSSFADE, transition_duration=100)
        self.scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
        self.flow = Gtk.FlowBox(
            homogeneous=True,
            min_children_per_line=columns or 2,
            max_children_per_line=columns or 12,
            selection_mode=Gtk.SelectionMode.NONE,
            row_spacing=6,
            column_spacing=6,
            valign=Gtk.Align.START,
            margin_start=10,
            margin_end=10,
            margin_top=10,
            margin_bottom=10,
        )
        self.flow.set_activate_on_single_click(True)
        self.flow.connect("child-activated", lambda _f, child: self.activate(child.get_index()))
        self.scroller.set_child(self.flow)
        self.scroller.get_vadjustment().connect("value-changed", self._scrolled)
        self.stack.add_named(self.scroller, "grid")

        self.empty = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
        self.empty_icon = Gtk.Image(pixel_size=40, opacity=0.6)
        self.empty_title = Gtk.Label()
        self.empty_title.add_css_class("hm-empty-title")
        self.empty_detail = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER, opacity=0.7)
        self.spinner = Adw.Spinner(width_request=32, height_request=32)
        for w in (self.spinner, self.empty_icon, self.empty_title, self.empty_detail):
            self.empty.append(w)
        self.stack.add_named(self.empty, "empty")
        self.append(self.stack)

    # Contents

    def reload(self) -> None:
        if self.browse.section == "memes":
            items = self.browse.memes()
            keys = [f"m:{m.id}" for m in items]
        else:
            items = self.browse.templates()
            keys = [f"t:{t.id}" for t in items]
        if keys == self._keys:
            self._items = items
            self._update_empty()
            return
        appended = len(keys) > len(self._keys) and keys[: len(self._keys)] == self._keys and self._keys
        if not appended:
            self.flow.remove_all()
            self._cells = []
            self.selected = min(self.selected, max(len(keys) - 1, 0))
        for item in items[len(self._cells):]:
            cell = self._make_cell(item)
            self._cells.append(cell)
            self.flow.append(cell)
        self._keys, self._items = keys, items
        if not appended:
            self.scroller.get_vadjustment().set_value(0)
        self._mark_selection()
        self._update_empty()

    @property
    def columns(self) -> int:
        if self._columns:
            return self._columns
        # Count the cells on the first row.
        tops = []
        for cell in self._cells[:13]:
            ok, bounds = cell.compute_bounds(self.flow)
            if not ok:
                break
            tops.append(round(bounds.get_y()))
        return max(1, tops.count(tops[0])) if tops else 1

    def _make_cell(self, item) -> Cell:
        library = Library.shared()
        if isinstance(item, SavedMeme):
            cell = Cell(item.title, self.cell_height)
            if not self._columns:
                cell.set_size_request(self.cell_height, -1)
            thumbnail(f"m:{item.id}", lambda: library.file(item), cell.show)
        else:
            cell = Cell(item.name, self.cell_height)
            if not self._columns:
                cell.set_size_request(self.cell_height, -1)
            thumbnail(f"t:{item.id}", lambda: library.thumbnail_path(item), cell.show)
        menu = Gtk.GestureClick(button=3)
        menu.connect("pressed", lambda g, n, x, y: self._menu(cell, item, x, y))
        cell.add_controller(menu)
        return cell

    def _menu(self, cell: Cell, item, x: float, y: float) -> None:
        library = Library.shared()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        popover = Gtk.Popover(child=box, has_arrow=False)
        popover.set_parent(cell)
        popover.set_pointing_to(Gdk.Rectangle(int(x), int(y), 1, 1))

        def entry(label: str, action: Callable, destructive: bool = False):
            button = Gtk.Button(label=label, has_frame=False)
            button.get_child().set_xalign(0)
            if destructive:
                button.add_css_class("destructive-action")

            def clicked(_b):
                popover.popdown()
                action()

            button.connect("clicked", clicked)
            box.append(button)

        if isinstance(item, SavedMeme):
            from . import inserter

            entry("Insert", lambda: self.on_meme(item))
            entry("Edit Again", lambda: self.on_edit_meme(item))
            entry("Copy", lambda: (inserter.copy(library.file(item)), self.on_toast("Copied")))
            entry("Download", lambda: self.on_toast(f"Saved to {library.download(item).parent.name}"))
            entry("Delete", lambda: (library.delete_meme(item), forget_thumbnail(f"m:{item.id}")), True)
        else:
            entry("Caption", lambda: self.on_template(item))
            star = "Remove from Favorites" if library.is_favorite(item) else "Add to Favorites"
            entry(star, lambda: library.toggle_favorite(item))
            if item.is_upload:
                entry("Delete Image", lambda: (library.delete_upload(item), forget_thumbnail(f"t:{item.id}")), True)
        popover.connect("closed", lambda p: GLib.idle_add(p.unparent))
        popover.popup()

    def _update_empty(self) -> None:
        browse = self.browse
        if self._items:
            self.stack.set_visible_child_name("grid")
            return
        busy, icon, title, detail = False, "", "", ""
        if browse.search_failed:
            icon, title, detail = "network-offline-symbolic", "Search Isn't Reachable", "Hypermeme couldn't reach imgflip."
        elif browse.query:
            if browse.searching:
                busy = True
            else:
                icon, title, detail = "system-search-symbolic", "No Matches", "Try another name for the meme."
        elif browse.section == "memes":
            icon, title, detail = "face-smile-big-symbolic", "No Memes Yet", "Memes you make stay here, ready to insert again."
        elif browse.section == "favorites":
            icon, title, detail = "starred-symbolic", "No Favorites", "Right-click a template to keep it here."
        elif browse.section == "recent":
            icon, title, detail = "document-open-recent-symbolic", "Nothing Recent", "Templates you use show up here."
        elif browse.section == "uploads":
            icon, title, detail = "image-x-generic-symbolic", "No Images", "Drop an image here, or press Ctrl+Shift+V to use the clipboard."
        elif Library.shared().load_failed:
            icon, title, detail = "network-offline-symbolic", "Offline", "Hypermeme couldn't reach imgflip."
        else:
            busy = True
        self.spinner.set_visible(busy)
        for w in (self.empty_icon, self.empty_title, self.empty_detail):
            w.set_visible(not busy)
        self.empty_icon.set_from_icon_name(icon or None)
        self.empty_title.set_label(title)
        self.empty_detail.set_label(detail)
        self.stack.set_visible_child_name("empty")

    # Selection

    def count(self) -> int:
        return len(self._items)

    def select(self, index: int) -> None:
        if not self._items:
            return
        self.selected = min(max(index, 0), len(self._items) - 1)
        self._mark_selection()
        self._scroll_to_selection()

    def move(self, delta: int) -> None:
        self.select(self.selected + delta)

    def _mark_selection(self) -> None:
        for index, cell in enumerate(self._cells):
            if index == self.selected:
                cell.add_css_class("selected-cell")
            else:
                cell.remove_css_class("selected-cell")

    def _scroll_to_selection(self) -> None:
        if not (0 <= self.selected < len(self._cells)):
            return
        ok, bounds = self._cells[self.selected].compute_bounds(self.flow)
        if not ok:
            return
        adjustment = self.scroller.get_vadjustment()
        top, bottom = bounds.get_y(), bounds.get_y() + bounds.get_height()
        if top < adjustment.get_value():
            adjustment.set_value(top - 10)
        elif bottom > adjustment.get_value() + adjustment.get_page_size():
            adjustment.set_value(bottom - adjustment.get_page_size() + 10)
        if self.selected >= len(self._items) - self.columns * 2:
            self.browse.load_more()

    def activate(self, index: int | None = None) -> None:
        index = self.selected if index is None else index
        if not (0 <= index < len(self._items)):
            return
        self.selected = index
        item = self._items[index]
        if isinstance(item, SavedMeme):
            self.on_meme(item)
        else:
            self.on_template(item)

    def _scrolled(self, adjustment: Gtk.Adjustment) -> None:
        if adjustment.get_value() + adjustment.get_page_size() >= adjustment.get_upper() - 400:
            self.browse.load_more()


class MemeCanvas(Gtk.DrawingArea):
    """Shows the rendered meme. With `editable`, boxes can be selected, moved and resized."""

    HANDLE = 12

    def __init__(self, editor: MemeEditor, editable: bool):
        super().__init__(hexpand=True, vexpand=True)
        self.editor = editor
        self.editable = editable
        self.on_select: Callable[[str], None] = lambda box_id: None
        self.on_moved: Callable[[], None] = lambda: None
        self._drag = None
        self.set_draw_func(self._draw)
        self._listener = lambda what: self.queue_draw()
        editor.listeners.append(self._listener)
        if editable:
            drag = Gtk.GestureDrag()
            drag.connect("drag-begin", self._begin)
            drag.connect("drag-update", self._update)
            drag.connect("drag-end", lambda *_: self._end())
            self.add_controller(drag)

    def detach(self) -> None:
        if self._listener in self.editor.listeners:
            self.editor.listeners.remove(self._listener)

    def _frame(self) -> tuple[float, float, float, float] | None:
        """Where the meme is drawn, fitted into the widget."""
        surface = self.editor.preview
        if surface is None:
            return None
        width, height = self.get_width(), self.get_height()
        sw, sh = surface.get_width(), surface.get_height()
        scale = min(width / sw, height / sh)
        w, h = sw * scale, sh * scale
        return (width - w) / 2, (height - h) / 2, w, h

    def _draw(self, _area, ctx: cairo.Context, width: int, height: int) -> None:
        frame = self._frame()
        if frame is None:
            ctx.set_source_rgba(0.5, 0.5, 0.5, 0.12)
            ctx.rectangle(0, 0, width, height)
            ctx.fill()
            if self.editor.failed:
                self._message(ctx, width, height, "Couldn't load this template")
            else:
                self._message(ctx, width, height, "Loading…")
            return
        x, y, w, h = frame
        surface = self.editor.preview
        ctx.save()
        ctx.translate(x, y)
        ctx.scale(w / surface.get_width(), h / surface.get_height())
        ctx.set_source_surface(surface, 0, 0)
        ctx.get_source().set_filter(cairo.FILTER_GOOD)
        ctx.paint()
        ctx.restore()
        if not self.editable:
            return
        for box in self.editor.document.boxes:
            selected = box.id == self.editor.selection
            bx, by, bw, bh = x + box.x * w, y + box.y * h, box.width * w, box.height * h
            ctx.save()
            ctx.translate(bx + bw / 2, by + bh / 2)
            ctx.rotate(math.radians(box.rotation))
            ctx.rectangle(-bw / 2, -bh / 2, bw, bh)
            ctx.set_line_width(2 if selected else 1)
            ctx.set_dash([] if selected else [4, 3])
            ctx.set_source_rgba(0.2, 0.55, 1, 0.95 if selected else 0.6)
            ctx.stroke()
            if selected:
                ctx.set_source_rgba(0.2, 0.55, 1, 1)
                ctx.rectangle(bw / 2 - self.HANDLE / 2, bh / 2 - self.HANDLE / 2, self.HANDLE, self.HANDLE)
                ctx.fill()
            ctx.restore()

    def _message(self, ctx, width, height, text):
        layout = self.create_pango_layout(text)
        _, logical = layout.get_pixel_extents()
        color = self.get_color()
        ctx.set_source_rgba(color.red, color.green, color.blue, 0.6)
        ctx.move_to((width - logical.width) / 2, (height - logical.height) / 2)
        from gi.repository import PangoCairo

        PangoCairo.show_layout(ctx, layout)

    def _hit(self, px: float, py: float):
        frame = self._frame()
        if frame is None:
            return None, None
        x, y, w, h = frame
        selected = self.editor.box(self.editor.selection)
        if selected:
            hx, hy = x + (selected.x + selected.width) * w, y + (selected.y + selected.height) * h
            if abs(px - hx) <= self.HANDLE and abs(py - hy) <= self.HANDLE:
                return selected, "resize"
        for box in reversed(self.editor.document.boxes):
            if x + box.x * w <= px <= x + (box.x + box.width) * w and y + box.y * h <= py <= y + (box.y + box.height) * h:
                return box, "move"
        return None, None

    def _begin(self, _gesture, px, py):
        box, mode = self._hit(px, py)
        if box is None:
            self._drag = None
            return
        if box.id != self.editor.selection:
            self.editor.selection = box.id
            self.on_select(box.id)
        self._drag = (box, mode, box.x, box.y, box.width, box.height)
        self.queue_draw()

    def _update(self, _gesture, dx, dy):
        frame = self._frame()
        if self._drag is None or frame is None:
            return
        _, _, w, h = frame
        box, mode, x0, y0, w0, h0 = self._drag
        if mode == "move":
            box.x = min(max(x0 + dx / w, -w0 + 0.05), 0.95)
            box.y = min(max(y0 + dy / h, -h0 + 0.05), 0.95)
        else:
            box.width = max(0.05, w0 + dx / w)
            box.height = max(0.04, h0 + dy / h)
        self.editor.changed()
        self.queue_draw()

    def _end(self):
        if self._drag is not None:
            self._drag = None
            self.on_moved()
