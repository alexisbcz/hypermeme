"""Hypermeme for Linux. One resident process owns the panel and the window; later invocations
(the Hyprland keybinding, hypermeme:// links, the launcher) hand it their command over D-Bus."""

from __future__ import annotations

import sys
import urllib.parse

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gdk", "4.0")
from gi.repository import Adw, Gio, GLib  # noqa: E402

from . import __version__  # noqa: E402
from .editor import MemeEditor, run_async  # noqa: E402
from .library import Library  # noqa: E402

APP_ID = "dev.alexis.Hypermeme"

USAGE = """Usage: hypermeme [command]

Commands:
  (none)               open the main window
  panel [query]        open the quick panel, searching for query
  toggle               open the quick panel, or close it
  search <query>       search in the main window
  edit <template> [text…] [--panel]
                       caption a template, filling its boxes in order
  hypermeme://…        open a link (panel, search, edit, window)
  quit                 stop the resident process
  --background         start without showing anything (for autostart)
  --version
"""


def parse(argv: list[str]) -> tuple[str, dict]:
    """Turns arguments or a hypermeme:// link into an action and its options."""
    args = list(argv)
    if not args:
        return "window", {}
    first = args[0]
    if first.startswith("hypermeme://"):
        url = urllib.parse.urlsplit(first)
        items = urllib.parse.parse_qs(url.query, keep_blank_values=True)
        value = lambda name: (items.get(name) or [None])[0]  # noqa: E731
        host = url.netloc or url.path.strip("/")
        if host == "panel":
            return "panel", {"query": value("q")}
        if host == "search":
            return "search", {"query": value("q")}
        if host == "edit":
            return "edit", {"template": value("template") or "", "texts": items.get("text", []), "panel": "panel" in items}
        return "window", {}
    if first in ("--background", "background", "daemon"):
        return "background", {}
    if first in ("panel", "toggle", "search"):
        query = " ".join(args[1:]) or None
        return first, {"query": query}
    if first == "edit":
        rest = [a for a in args[1:] if a != "--panel"]
        return "edit", {"template": rest[0] if rest else "", "texts": rest[1:], "panel": "--panel" in args}
    if first in ("window", "open", "show"):
        return "window", {}
    if first == "quit":
        return "quit", {}
    if first in ("-v", "--version", "version"):
        return "version", {}
    return "help", {}


class Application(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window = None
        self.panel = None
        self.theme = None
        self._held = False
        for name, callback in (
            ("toggle-panel", lambda *_: self.do("toggle", {})),
            ("panel", lambda *_: self.do("panel", {})),
            ("window", lambda *_: self.do("window", {})),
            ("quit", lambda *_: self.quit()),
        ):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", callback)
            self.add_action(action)

    def do_startup(self):
        Adw.Application.do_startup(self)
        from . import renderer
        from .theme import OmarchyTheme

        renderer.register_fonts()
        self.theme = OmarchyTheme()
        # Stay resident with no window open, so the keybinding opens the panel at once.
        self.hold()
        self._held = True
        run_async(Library.shared().refresh)

    def do_command_line(self, command_line: Gio.ApplicationCommandLine) -> int:
        argv = command_line.get_arguments()[1:]
        action, options = parse(argv)
        if action == "help":
            command_line.print_literal(USAGE)
            return 0 if argv and argv[0] in ("-h", "--help", "help") else 2
        if action == "version":
            command_line.print_literal(f"Hypermeme {__version__}\n")
            return 0
        self.do(action, options)
        return 0

    def do_activate(self):
        self.do("window", {})

    def _panel(self):
        if self.panel is None:
            from .panel import Panel

            self.panel = Panel(self)
            self.panel.on_open_in_window = lambda editor: self._show_window().show_editor(editor)
        return self.panel

    def _window(self):
        if self.window is None:
            from .window import MainWindow

            self.window = MainWindow(self)
            self.window.connect("close-request", self._window_closed)
        return self.window

    def _show_window(self):
        window = self._window()
        mapped = window.get_mapped()
        window.present()
        if mapped:
            from . import inserter

            inserter.focus_window(APP_ID)
        return window

    def _window_closed(self, _window) -> bool:
        self.window.set_visible(False)
        self.window.close_editor()
        return True

    def do(self, action: str, options: dict) -> None:
        if action == "background":
            return
        if action == "quit":
            self.quit()
        elif action == "toggle":
            self._panel().toggle()
        elif action == "panel":
            self._panel().present_with(query=options.get("query"))
        elif action == "search":
            self._show_window().show_search(options.get("query"))
        elif action == "edit":
            library = Library.shared()
            name = options.get("template", "")
            template = library.template(name) or next(iter(library.local_matches(name)), None) if name else None
            if template is None:
                from . import inserter

                inserter.notify("No such template", name)
                return
            editor = MemeEditor(template)
            editor.prefilled = list(options.get("texts", []))
            editor.load()
            if options.get("panel"):
                self._panel().present_with(editor=editor)
            else:
                self._show_window().show_editor(editor)
        else:
            self._show_window()


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv if argv is None else argv
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("Hypermeme")
    return Application().run(argv)
