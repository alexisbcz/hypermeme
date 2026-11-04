"""The quick panel: a layer-shell overlay, like Omarchy's own menus, that opens over whatever you're
doing and gives focus back to it when it closes, so Insert pastes in the right place."""

from __future__ import annotations

from typing import Callable

from gi.repository import Adw, Gdk, GLib, Gtk

from . import inserter
from .browse import BrowseModel
from .editor import MemeEditor
from .library import Library
from .models import MemeTemplate, SavedMeme
from .widgets import Grid, MemeCanvas

try:
    import gi

    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gtk4LayerShell as LayerShell
except (ImportError, ValueError):
    LayerShell = None

WIDTH, HEIGHT = 460, 620
COLUMNS = 3
SECTIONS = ["popular", "recent", "favorites", "memes"]
TITLES = {"popular": "Popular", "recent": "Recent", "favorites": "Favorites", "memes": "My Memes"}


def layer_shell_works() -> bool:
    return LayerShell is not None and LayerShell.is_supported()


class Panel(Gtk.ApplicationWindow):
    def __init__(self, app: Adw.Application):
        super().__init__(application=app, title="Hypermeme", decorated=False)
        self.add_css_class("hm-backdrop")
        self.on_open_in_window: Callable[[MemeEditor], None] = lambda e: None
        self.browse = BrowseModel()
        self.browse.on_change = self._browse_changed
        self.editor: MemeEditor | None = None
        self.canvas: MemeCanvas | None = None
        self.entries: list[Gtk.Entry] = []
        self._library_listener = None

        self.layered = layer_shell_works()
        if self.layered:
            LayerShell.init_for_window(self)
            LayerShell.set_namespace(self, "hypermeme")
            LayerShell.set_layer(self, LayerShell.Layer.OVERLAY)
            LayerShell.set_keyboard_mode(self, LayerShell.KeyboardMode.EXCLUSIVE)
            # Covering the screen lets a click beside the panel close it.
            for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM, LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
                LayerShell.set_anchor(self, edge, True)
            LayerShell.set_exclusive_zone(self, -1)
        else:
            self.set_default_size(WIDTH, HEIGHT)

        backdrop = Gtk.Overlay()
        catcher = Gtk.Box(hexpand=True, vexpand=True)
        if self.layered:
            click = Gtk.GestureClick()
            click.connect("pressed", self._backdrop_clicked)
            catcher.add_controller(click)
        backdrop.set_child(catcher)

        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        self.card.add_css_class("hm-panel")
        self.card.set_size_request(WIDTH, HEIGHT)
        self.card.set_overflow(Gtk.Overflow.HIDDEN)
        if not self.layered:
            self.card.set_halign(Gtk.Align.FILL)
            self.card.set_valign(Gtk.Align.FILL)
        backdrop.add_overlay(self.card)
        self.set_child(backdrop)

        self.pages = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, transition_duration=120, vexpand=True)
        self.card.append(self.pages)
        self.pages.add_named(self._build_browser(), "browse")
        self.editor_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.pages.add_named(self.editor_page, "editor")

        keys = Gtk.EventControllerKey(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._key)
        self.add_controller(keys)
        self.connect("close-request", self._close_request)

        self._library_listener = lambda: GLib.idle_add(self._library_changed)

    # Browser

    def _build_browser(self) -> Gtk.Widget:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        row = Gtk.Box(spacing=10, margin_start=16, margin_end=16, margin_top=12, margin_bottom=10)
        row.append(Gtk.Image(icon_name="system-search-symbolic", opacity=0.7))
        self.search = Gtk.Text(hexpand=True, placeholder_text="Search memes")
        self.search.add_css_class("hm-search")
        self.search.connect("changed", lambda e: self._query_changed(e.get_text()))
        self.search.connect("activate", lambda _e: self.grid.activate())
        row.append(self.search)
        self.busy = Adw.Spinner(visible=False)
        row.append(self.busy)
        page.append(row)

        self.sections = Adw.ToggleGroup(margin_start=14, margin_end=14, margin_bottom=10, homogeneous=True)
        for name in SECTIONS:
            self.sections.add(Adw.Toggle(name=name, label=TITLES[name]))
        self.sections.set_active_name("popular")
        self.sections.connect("notify::active-name", lambda g, _p: self._section_changed(g.get_active_name()))
        page.append(self.sections)
        page.append(Gtk.Separator())

        self.grid = Grid(self.browse, COLUMNS, 112, lambda: self)
        self.grid.on_template = self.open_template
        self.grid.on_meme = self.insert_meme
        self.grid.on_edit_meme = self.edit_again
        self.grid.on_toast = lambda text: inserter.notify(text)
        page.append(self.grid)
        page.append(Gtk.Separator())

        footer = Gtk.Box(spacing=14, margin_start=14, margin_end=14, margin_top=8, margin_bottom=8)
        self.enter_hint = Gtk.Label(label="↩ Caption")
        footer.append(self.enter_hint)
        footer.append(Gtk.Label(label="⇥ Switch section"))
        footer.append(Gtk.Label(label="⎋ Close", hexpand=True, xalign=1))
        for child in (self.enter_hint, footer.get_last_child(), self.enter_hint.get_next_sibling()):
            child.add_css_class("hm-hint")
        page.append(footer)
        return page

    def _query_changed(self, text: str) -> None:
        self.browse.query = text
        self.grid.selected = 0

    def _section_changed(self, name: str | None) -> None:
        if not name:
            return
        self.browse.section = name
        self.grid.selected = 0
        self.search.set_placeholder_text("Search your memes" if name == "memes" else "Search memes")
        self.enter_hint.set_label("↩ Insert" if name == "memes" else "↩ Caption")
        self.grid.reload()

    def _browse_changed(self) -> None:
        self.busy.set_visible(self.browse.searching)
        self.grid.reload()

    def _library_changed(self) -> bool:
        if self.get_visible():
            self.grid.reload()
        return False

    # Showing and hiding

    def present_with(self, query: str | None = None, editor: MemeEditor | None = None) -> None:
        library = Library.shared()
        if self._library_listener not in library.listeners:
            library.listeners.append(self._library_listener)
        from .editor import run_async

        run_async(library.refresh)
        self.close_editor()
        self.sections.set_active_name("popular")
        self.search.set_text(query or "")
        self.browse.query = query or ""
        self.grid.reload()
        self.grid.select(0)
        self.present()
        self.search.grab_focus()
        if editor:
            self._show_editor(editor)

    def toggle(self) -> None:
        if self.get_visible():
            self.dismiss()
        else:
            self.present_with()

    def dismiss(self) -> None:
        self.set_visible(False)
        self.close_editor()

    def _close_request(self, _w) -> bool:
        self.dismiss()
        return True

    def _backdrop_clicked(self, gesture, _n, x, y) -> None:
        ok, bounds = self.card.compute_bounds(self)
        if ok and bounds.contains_point(self._point(x, y)):
            return
        self.dismiss()

    @staticmethod
    def _point(x, y):
        from gi.repository import Graphene

        return Graphene.Point().init(x, y)

    # Keys

    def _key(self, _controller, keyval, _code, state) -> bool:
        ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(state & Gdk.ModifierType.SHIFT_MASK)
        if self.editor is not None:
            if keyval == Gdk.KEY_Escape:
                self.close_editor()
                return True
            if ctrl and keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
                self.insert_editor()
                return True
            if ctrl and shift and keyval in (Gdk.KEY_C, Gdk.KEY_c):
                self.copy_editor()
                return True
            if ctrl and keyval in (Gdk.KEY_s, Gdk.KEY_S):
                self.download_editor()
                return True
            return False
        if keyval == Gdk.KEY_Escape:
            if self.search.get_text():
                self.search.set_text("")
            else:
                self.dismiss()
            return True
        if keyval == Gdk.KEY_Up:
            self.grid.move(-COLUMNS)
            return True
        if keyval == Gdk.KEY_Down:
            self.grid.move(COLUMNS)
            return True
        if keyval in (Gdk.KEY_Left, Gdk.KEY_Right) and not self.search.get_text():
            self.grid.move(-1 if keyval == Gdk.KEY_Left else 1)
            return True
        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab):
            index = SECTIONS.index(self.browse.section) if self.browse.section in SECTIONS else 0
            step = -1 if shift or keyval == Gdk.KEY_ISO_Left_Tab else 1
            self.sections.set_active_name(SECTIONS[(index + step) % len(SECTIONS)])
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self.grid.activate()
            return True
        return False

    # Actions

    def open_template(self, template: MemeTemplate) -> None:
        editor = MemeEditor(template)
        editor.load()
        self._show_editor(editor)

    def edit_again(self, meme: SavedMeme) -> None:
        editor = MemeEditor.from_meme(meme)
        if editor:
            editor.load()
            self._show_editor(editor)

    def insert_meme(self, meme: SavedMeme) -> None:
        library = Library.shared()
        library.move_to_top(meme)
        self.dismiss()
        inserter.insert(library.file(meme))

    def _finish(self):
        return self.editor.finish() if self.editor else None

    def insert_editor(self) -> None:
        meme = self._finish()
        if meme:
            self.dismiss()
            inserter.insert(Library.shared().file(meme))

    def copy_editor(self) -> None:
        meme = self._finish()
        if meme:
            inserter.copy(Library.shared().file(meme))
            self.dismiss()
            inserter.notify("Copied")

    def download_editor(self) -> None:
        meme = self._finish()
        if meme:
            target = Library.shared().download(meme)
            self.dismiss()
            inserter.notify("Saved to Downloads", target.name)

    # Editor

    def _show_editor(self, editor: MemeEditor) -> None:
        self.close_editor(show_browser=False)
        self.editor = editor
        page = self.editor_page
        header = Gtk.Box(spacing=8, margin_start=10, margin_end=10, margin_top=6, margin_bottom=6)
        back = Gtk.Button(icon_name="go-previous-symbolic", has_frame=False, tooltip_text="Back to templates (Esc)")
        back.connect("clicked", lambda _b: self.close_editor())
        header.append(back)
        self.editor_title = Gtk.Label(label=editor.template.name, hexpand=True, xalign=0)
        self.editor_title.add_css_class("heading")
        header.append(self.editor_title)
        expand = Gtk.Button(icon_name="view-fullscreen-symbolic", has_frame=False, tooltip_text="Open in the full editor, for fonts, colors and more text")
        expand.connect("clicked", lambda _b: self._open_in_window())
        header.append(expand)
        page.append(header)
        page.append(Gtk.Separator())

        self.canvas = MemeCanvas(editor, editable=True)
        self.canvas.set_margin_start(12)
        self.canvas.set_margin_end(12)
        self.canvas.set_margin_top(12)
        self.canvas.set_margin_bottom(12)
        self.canvas.on_select = self._focus_box
        page.append(self.canvas)
        page.append(Gtk.Separator())

        self.fields = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7, margin_start=14, margin_end=14, margin_top=10, margin_bottom=10)
        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, propagate_natural_height=True, max_content_height=150)
        scroller.set_child(self.fields)
        page.append(scroller)
        page.append(Gtk.Separator())

        footer = Gtk.Box(spacing=8, margin_start=14, margin_end=14, margin_top=8, margin_bottom=8)
        hint = Gtk.Label(label="⎋ Back", hexpand=True, xalign=0)
        hint.add_css_class("hm-hint")
        footer.append(hint)
        self.actions = []
        for label, tip, action, suggested in (
            ("Download", "Save a PNG to Downloads (Ctrl+S)", self.download_editor, False),
            ("Copy", "Copy without pasting (Ctrl+Shift+C)", self.copy_editor, False),
            ("Insert", "Paste into the window you were using (↩)", self.insert_editor, True),
        ):
            button = Gtk.Button(label=label, tooltip_text=tip, sensitive=editor.image is not None)
            if suggested:
                button.add_css_class("suggested-action")
            button.connect("clicked", lambda _b, a=action: a())
            footer.append(button)
            self.actions.append(button)
        page.append(footer)

        self._editor_listener = lambda what: self._editor_changed(what)
        editor.listeners.append(self._editor_listener)
        self._build_fields()
        self.pages.set_visible_child_name("editor")
        GLib.idle_add(lambda: (self.entries and self.entries[0].grab_focus(), False)[1])

    def _build_fields(self) -> None:
        editor = self.editor
        while child := self.fields.get_first_child():
            self.fields.remove(child)
        self.entries = []
        for index, box in enumerate(editor.document.boxes):
            entry = Gtk.Entry(placeholder_text=f"Text {index + 1}", text=box.text)
            entry.connect("changed", lambda e, b=box: self._text_changed(b, e.get_text()))
            entry.connect("activate", lambda _e: self.insert_editor())
            focus = Gtk.EventControllerFocus()
            focus.connect("enter", lambda _c, b=box: self._selected(b.id))
            entry.add_controller(focus)
            self.fields.append(entry)
            self.entries.append(entry)

    def _text_changed(self, box, text: str) -> None:
        box.text = text
        self.editor.changed()

    def _selected(self, box_id: str) -> None:
        if self.editor and self.editor.selection != box_id:
            self.editor.selection = box_id
            self.canvas.queue_draw()

    def _focus_box(self, box_id: str) -> None:
        for box, entry in zip(self.editor.document.boxes, self.entries, strict=False):
            if box.id == box_id:
                entry.grab_focus()

    def _editor_changed(self, what: str) -> None:
        if what != "layout" or self.editor is None:
            return
        self.editor_title.set_label(self.editor.template.name)
        self._build_fields()
        for button in self.actions:
            button.set_sensitive(self.editor.image is not None)
        index = next((i for i, b in enumerate(self.editor.document.boxes) if b.id == self.editor.selection), 0)
        if self.entries:
            entry = self.entries[min(index, len(self.entries) - 1)]
            entry.grab_focus()
            entry.set_position(-1)

    def close_editor(self, show_browser: bool = True) -> None:
        if self.editor is not None:
            if self._editor_listener in self.editor.listeners:
                self.editor.listeners.remove(self._editor_listener)
            if self.canvas:
                self.canvas.detach()
        self.editor = None
        self.canvas = None
        self.entries = []
        while child := self.editor_page.get_first_child():
            self.editor_page.remove(child)
        if show_browser:
            self.pages.set_visible_child_name("browse")
            self.search.grab_focus()

    def _open_in_window(self) -> None:
        editor = self.editor
        if editor is None:
            return
        if self._editor_listener in editor.listeners:
            editor.listeners.remove(self._editor_listener)
        if self.canvas:
            self.canvas.detach()
        self.editor = None
        self.dismiss()
        self.on_open_in_window(editor)

