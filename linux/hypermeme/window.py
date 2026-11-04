"""The main window: every section, and the full editor with fonts, colors and draggable text."""

from __future__ import annotations

import tempfile
from pathlib import Path

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import inserter
from .browse import SECTIONS, BrowseModel
from .editor import MemeEditor
from .library import Library
from .models import FONT_LABELS, FONTS, MemeTemplate, SavedMeme
from .widgets import Grid, MemeCanvas, forget_thumbnail

ORDER = ["popular", "recent", "favorites", "uploads", "memes"]


def _rgba(hex_color: str) -> Gdk.RGBA:
    rgba = Gdk.RGBA()
    rgba.parse(hex_color)
    return rgba


def _hex(rgba: Gdk.RGBA) -> str:
    return "#{:02X}{:02X}{:02X}".format(*(round(c * 255) for c in (rgba.red, rgba.green, rgba.blue)))


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application):
        super().__init__(application=app, title="Hypermeme", default_width=1080, default_height=740)
        self.set_size_request(640, 480)
        self.browse = BrowseModel()
        self.browse.on_change = lambda: self.grid.reload()
        self.editor: MemeEditor | None = None
        self.canvas: MemeCanvas | None = None
        self._editor_listener = None
        self._syncing = False

        self.toasts = Adw.ToastOverlay()
        self.split = Adw.NavigationSplitView(min_sidebar_width=180, max_sidebar_width=240)
        self.toasts.set_child(self.split)
        self.set_content(self.toasts)

        # Sidebar
        sidebar = Adw.ToolbarView()
        sidebar.add_top_bar(Adw.HeaderBar(show_title=False))
        self.section_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.section_list.add_css_class("navigation-sidebar")
        for name in ORDER:
            title, icon = SECTIONS[name]
            row = Gtk.Box(spacing=10, margin_start=6, margin_top=6, margin_bottom=6)
            row.append(Gtk.Image(icon_name=icon))
            row.append(Gtk.Label(label=title, xalign=0))
            self.section_list.append(row)
        self.section_list.connect("row-selected", self._section_selected)
        sidebar.set_content(self.section_list)
        self.split.set_sidebar(Adw.NavigationPage(title="Hypermeme", child=sidebar))

        # Content
        content = Adw.ToolbarView()
        self.header = Adw.HeaderBar(show_back_button=False)
        self.search = Gtk.SearchEntry(placeholder_text="Search memes", width_chars=28)
        self.search.connect("search-changed", self._search_changed)
        self.search.connect("activate", lambda _e: self.grid.activate())
        self.header.set_title_widget(self.search)
        self.back = Gtk.Button(icon_name="go-previous-symbolic", tooltip_text="Back", visible=False)
        self.back.connect("clicked", lambda _b: self.close_editor())
        self.header.pack_start(self.back)
        add = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="Add an image (Ctrl+O)")
        add.connect("clicked", lambda _b: self.add_image())
        self.header.pack_start(add)
        self.add_button = add
        self.editor_actions = Gtk.Box(spacing=6, visible=False)
        for label, tip, action, suggested in (
            ("Download", "Save a PNG to Downloads (Ctrl+S)", self.download_editor, False),
            ("Copy", "Copy the meme (Ctrl+Shift+C)", self.copy_editor, False),
            ("Save", "Keep it in My Memes (Ctrl+Return)", self.save_editor, True),
        ):
            button = Gtk.Button(label=label, tooltip_text=tip)
            if suggested:
                button.add_css_class("suggested-action")
            button.connect("clicked", lambda _b, a=action: a())
            self.editor_actions.append(button)
        self.header.pack_end(self.editor_actions)
        content.add_top_bar(self.header)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, transition_duration=120)
        self.grid = Grid(self.browse, None, 150, lambda: self)
        self.grid.on_template = self.open_template
        self.grid.on_meme = self.edit_meme
        self.grid.on_edit_meme = self.edit_meme
        self.grid.on_toast = self.toast
        self.stack.add_named(self.grid, "grid")
        self.editor_page = Gtk.Box()
        self.stack.add_named(self.editor_page, "editor")
        content.set_content(self.stack)
        self.split.set_content(Adw.NavigationPage(title="Memes", child=content))
        self.section_list.select_row(self.section_list.get_row_at_index(0))

        # Dropping an image captions it.
        drop = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
        drop.connect("drop", self._dropped)
        self.add_controller(drop)

        keys = Gtk.EventControllerKey(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._key)
        self.add_controller(keys)

        Library.shared().listeners.append(lambda: GLib.idle_add(self._library_changed))
        self.grid.reload()

    # Browsing

    def _section_selected(self, _list, row) -> None:
        if row is None:
            return
        name = ORDER[row.get_index()]
        self.browse.section = name
        self.grid.selected = 0
        self.search.set_placeholder_text("Search your memes" if name == "memes" else "Search memes")
        self.close_editor()
        self.grid.reload()

    def _search_changed(self, entry) -> None:
        text = entry.get_text()
        if text and self.editor:
            self.close_editor()
        self.browse.query = text
        self.grid.selected = 0

    def show_section(self, name: str) -> None:
        self.section_list.select_row(self.section_list.get_row_at_index(ORDER.index(name)))

    def show_search(self, query: str | None) -> None:
        self.show_section("popular")
        self.search.set_text(query or "")
        self.present()
        self.search.grab_focus()

    def _library_changed(self) -> bool:
        if self.editor is None:
            self.grid.reload()
        return False

    def toast(self, text: str) -> None:
        self.toasts.add_toast(Adw.Toast(title=text, timeout=2))

    def _key(self, _c, keyval, _code, state) -> bool:
        ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(state & Gdk.ModifierType.SHIFT_MASK)
        if ctrl and keyval in (Gdk.KEY_o, Gdk.KEY_O):
            self.add_image()
            return True
        if ctrl and shift and keyval in (Gdk.KEY_V, Gdk.KEY_v) and not self._typing():
            self.add_from_clipboard()
            return True
        if ctrl and keyval in (Gdk.KEY_f, Gdk.KEY_F):
            self.search.grab_focus()
            return True
        if self.editor is not None:
            if keyval == Gdk.KEY_Escape:
                self.close_editor()
                return True
            if ctrl and keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
                self.save_editor()
                return True
            if ctrl and keyval in (Gdk.KEY_s, Gdk.KEY_S):
                self.download_editor()
                return True
            if ctrl and shift and keyval in (Gdk.KEY_C, Gdk.KEY_c):
                self.copy_editor()
                return True
            return False
        if keyval == Gdk.KEY_Escape and self.search.get_text():
            self.search.set_text("")
            return True
        if self.search.has_focus() or self.search.get_focus_child() is not None or self.get_focus() is self.search:
            columns = self.grid.columns
            moves = {Gdk.KEY_Up: -columns, Gdk.KEY_Down: columns}
            if keyval in moves:
                self.grid.move(moves[keyval])
                return True
        return False

    def _typing(self) -> bool:
        focus = self.get_focus()
        return isinstance(focus, (Gtk.Text, Gtk.TextView)) and focus is not None and self.editor is not None

    # Images of your own

    def add_image(self) -> None:
        dialog = Gtk.FileDialog(title="Add an Image")
        images = Gtk.FileFilter(name="Images")
        images.add_pixbuf_formats()
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(images)
        dialog.set_filters(filters)

        def chosen(dialog, result):
            try:
                file = dialog.open_finish(result)
            except GLib.Error:
                return
            self._add_upload(file.get_path())

        dialog.open(self, None, chosen)

    def _add_upload(self, path: str | None, name: str | None = None) -> None:
        if not path:
            return
        template = Library.shared().add_upload(path, name)
        if template is None:
            self.toast("That file isn't an image Hypermeme can read")
            return
        self.open_template(template)

    def add_from_clipboard(self) -> None:
        clipboard = self.get_clipboard()

        def read(clipboard, result):
            try:
                texture = clipboard.read_texture_finish(result)
            except GLib.Error:
                texture = None
            if texture is None:
                self.toast("There's no image on the clipboard")
                return
            path = Path(tempfile.mkstemp(suffix=".png")[1])
            texture.save_to_png(str(path))
            self._add_upload(str(path), "Pasted Image")
            path.unlink(missing_ok=True)

        clipboard.read_texture_async(None, read)

    def _dropped(self, _target, value, _x, _y) -> bool:
        files = value.get_files()
        if not files:
            return False
        self._add_upload(files[0].get_path())
        return True

    # Editing

    def open_template(self, template: MemeTemplate) -> None:
        editor = MemeEditor(template)
        editor.load()
        self.show_editor(editor)

    def edit_meme(self, meme: SavedMeme) -> None:
        editor = MemeEditor.from_meme(meme)
        if editor is None:
            self.toast("Its template is gone")
            return
        editor.load()
        self.show_editor(editor)

    def show_editor(self, editor: MemeEditor) -> None:
        self.close_editor(show_grid=False)
        self.editor = editor
        page = self.editor_page
        self.canvas = MemeCanvas(editor, editable=True)
        self.canvas.set_margin_start(18)
        self.canvas.set_margin_end(18)
        self.canvas.set_margin_top(18)
        self.canvas.set_margin_bottom(18)
        self.canvas.on_select = lambda _id: self._sync_inspector()
        page.append(self.canvas)
        page.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))
        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, width_request=340, hexpand=False)
        self.inspector = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, margin_start=16, margin_end=16, margin_top=16, margin_bottom=16)
        scroller.set_child(self.inspector)
        page.append(scroller)
        self._build_inspector()
        self._editor_listener = lambda what: self._editor_changed(what)
        editor.listeners.append(self._editor_listener)
        self.back.set_visible(True)
        self.add_button.set_visible(False)
        # The editor gets the whole window; the sidebar returns with the grid.
        self.split.set_collapsed(True)
        self.split.set_show_content(True)
        self.editor_actions.set_visible(True)
        self.set_title(editor.template.name)
        self.stack.set_visible_child_name("editor")
        self.present()
        if editor.preview is None and editor.image is not None:
            editor.changed()

    def _editor_changed(self, what: str) -> None:
        if what == "layout" and self.editor:
            self.set_title(self.editor.template.name)
            self._build_inspector()

    def close_editor(self, show_grid: bool = True) -> None:
        if self.editor is not None and self._editor_listener in self.editor.listeners:
            self.editor.listeners.remove(self._editor_listener)
        if self.canvas:
            self.canvas.detach()
        self.editor = None
        self.canvas = None
        while child := self.editor_page.get_first_child():
            self.editor_page.remove(child)
        self.back.set_visible(False)
        self.add_button.set_visible(True)
        self.split.set_collapsed(False)
        self.editor_actions.set_visible(False)
        self.set_title("Hypermeme")
        if show_grid:
            self.stack.set_visible_child_name("grid")
            self.grid.reload()

    def _build_inspector(self) -> None:
        editor = self.editor
        box_area = self.inspector
        # Building the controls sets their defaults, which mustn't be written into the meme.
        self._syncing = True
        while child := box_area.get_first_child():
            box_area.remove(child)

        texts = Adw.PreferencesGroup(title="Text")
        self.text_rows: dict[str, Adw.EntryRow] = {}
        for index, box in enumerate(editor.document.boxes):
            row = Adw.EntryRow(title=f"Text {index + 1}", text=box.text)
            row.connect("changed", lambda r, b=box: self._set(b, "text", r.get_text()))
            focus = Gtk.EventControllerFocus()
            focus.connect("enter", lambda _c, b=box: self._select(b.id))
            row.add_controller(focus)
            texts.add(row)
            self.text_rows[box.id] = row
        buttons = Gtk.Box(spacing=6, homogeneous=True, margin_top=6)
        add = Gtk.Button(label="Add Text")
        add.connect("clicked", lambda _b: editor.add_box())
        remove = Gtk.Button(label="Remove", sensitive=len(editor.document.boxes) > 0)
        remove.add_css_class("destructive-action")
        remove.connect("clicked", lambda _b: editor.selection and editor.remove(editor.selection))
        buttons.append(add)
        buttons.append(remove)
        box_area.append(texts)
        box_area.append(buttons)

        self.style_group = Adw.PreferencesGroup(title="Selected Text")
        self.font_row = Adw.ComboRow(title="Font", model=Gtk.StringList.new([FONT_LABELS[f] for f in FONTS]))
        self.font_row.connect("notify::selected", lambda r, _p: self._set_selected("font", FONTS[r.get_selected()]))
        self.style_group.add(self.font_row)

        self.color_button = Gtk.ColorDialogButton(dialog=Gtk.ColorDialog(with_alpha=False), valign=Gtk.Align.CENTER)
        self.color_button.connect("notify::rgba", lambda b, _p: self._set_selected("color", _hex(b.get_rgba())))
        color_row = Adw.ActionRow(title="Color")
        color_row.add_suffix(self.color_button)
        self.style_group.add(color_row)
        self.outline_button = Gtk.ColorDialogButton(dialog=Gtk.ColorDialog(with_alpha=False), valign=Gtk.Align.CENTER)
        self.outline_button.connect("notify::rgba", lambda b, _p: self._set_selected("outline", _hex(b.get_rgba())))
        outline_row = Adw.ActionRow(title="Outline")
        outline_row.add_suffix(self.outline_button)
        self.style_group.add(outline_row)

        self.align_group = Adw.ToggleGroup(valign=Gtk.Align.CENTER)
        for name, icon in (("left", "format-justify-left-symbolic"), ("center", "format-justify-center-symbolic"), ("right", "format-justify-right-symbolic")):
            self.align_group.add(Adw.Toggle(name=name, icon_name=icon, tooltip=name.title()))
        self.align_group.connect("notify::active-name", lambda g, _p: self._set_selected("align", g.get_active_name()))
        align_row = Adw.ActionRow(title="Align")
        align_row.add_suffix(self.align_group)
        self.style_group.add(align_row)

        self.valign_group = Adw.ToggleGroup(valign=Gtk.Align.CENTER)
        for name in ("top", "middle", "bottom"):
            self.valign_group.add(Adw.Toggle(name=name, label=name.title()))
        self.valign_group.connect("notify::active-name", lambda g, _p: self._set_selected("verticalAlign", g.get_active_name()))
        valign_row = Adw.ActionRow(title="Position")
        valign_row.add_suffix(self.valign_group)
        self.style_group.add(valign_row)

        self.caps_row = Adw.SwitchRow(title="All Caps")
        self.caps_row.connect("notify::active", lambda r, _p: self._set_selected("allCaps", r.get_active()))
        self.style_group.add(self.caps_row)
        self.shadow_row = Adw.SwitchRow(title="Soft Shadow")
        self.shadow_row.connect("notify::active", lambda r, _p: self._set_selected("shadow", r.get_active()))
        self.style_group.add(self.shadow_row)
        self.rotation_row = Adw.SpinRow.new_with_range(-180, 180, 1)
        self.rotation_row.set_title("Rotation")
        self.rotation_row.connect("notify::value", lambda r, _p: self._set_selected("rotation", r.get_value()))
        self.style_group.add(self.rotation_row)
        box_area.append(self.style_group)

        meme_group = Adw.PreferencesGroup(title="Meme")
        strip = Adw.SwitchRow(title="Caption Strip", subtitle="A white strip above the image", active=editor.document.captionStrip > 0)
        strip.connect("notify::active", lambda r, _p: editor.set_caption_strip(r.get_active()))
        meme_group.add(strip)
        if not editor.template.is_upload:
            star = Adw.SwitchRow(title="Favorite", active=Library.shared().is_favorite(editor.template))
            star.connect("notify::active", lambda r, _p: Library.shared().is_favorite(editor.template) != r.get_active() and Library.shared().toggle_favorite(editor.template))
            meme_group.add(star)
        box_area.append(meme_group)
        self._syncing = False
        self._sync_inspector()

    def _select(self, box_id: str) -> None:
        if self.editor and self.editor.selection != box_id:
            self.editor.selection = box_id
            self.canvas.queue_draw()
            self._sync_inspector()

    def _sync_inspector(self) -> None:
        editor = self.editor
        box = editor.box(editor.selection) if editor else None
        self.style_group.set_sensitive(box is not None)
        if box is None:
            return
        self._syncing = True
        self.font_row.set_selected(FONTS.index(box.font) if box.font in FONTS else 0)
        self.color_button.set_rgba(_rgba(box.color))
        self.outline_button.set_rgba(_rgba(box.outline))
        self.align_group.set_active_name(box.align)
        self.valign_group.set_active_name(box.verticalAlign)
        self.caps_row.set_active(box.allCaps)
        self.shadow_row.set_active(box.shadow)
        self.rotation_row.set_value((box.rotation + 180) % 360 - 180)
        self._syncing = False

    def _set(self, box, key: str, value) -> None:
        if getattr(box, key) == value:
            return
        setattr(box, key, value)
        self.editor.changed()

    def _set_selected(self, key: str, value) -> None:
        if self._syncing or self.editor is None or value is None:
            return
        box = self.editor.box(self.editor.selection)
        if box is not None:
            self._set(box, key, value)

    # Finishing

    def _finish(self) -> SavedMeme | None:
        if self.editor is None or self.editor.image is None:
            self.toast("The template is still loading")
            return None
        meme = self.editor.finish()
        if meme is None:
            self.toast("Couldn't save the meme")
        else:
            forget_thumbnail(f"m:{meme.id}")
        return meme

    def save_editor(self) -> None:
        if self._finish():
            self.toast("Saved to My Memes")

    def copy_editor(self) -> None:
        meme = self._finish()
        if meme:
            ok = inserter.copy(Library.shared().file(meme))
            self.toast("Copied" if ok else "Couldn't copy: install wl-clipboard")

    def download_editor(self) -> None:
        meme = self._finish()
        if meme:
            target = Library.shared().download(meme)
            self.toast(f"Saved {target.name} to Downloads")
