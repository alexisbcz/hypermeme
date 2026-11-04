"""Follows the Omarchy theme: its colors.toml becomes libadwaita's palette, and switching themes
restyles Hypermeme while it runs."""

from __future__ import annotations

import os
import tomllib
from pathlib import Path

from gi.repository import Adw, Gdk, Gio, Gtk

STATE = Path(os.path.expanduser("~/.local/state/omarchy/current"))
COLORS = STATE / "theme" / "colors.toml"

BASE_CSS = """
.hm-panel {
  border-radius: 16px;
  border: 1px solid alpha(@window_fg_color, 0.18);
  background: @window_bg_color;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.45);
}
.hm-backdrop { background: transparent; }
.hm-search { font-size: 17px; background: transparent; border: none; box-shadow: none; outline: none; }
.hm-search > text { padding: 0; }
.hm-cell { border-radius: 10px; padding: 4px; border: 2px solid transparent; }
.hm-cell.selected-cell { border-color: @accent_bg_color; background: alpha(@accent_bg_color, 0.14); }
.hm-thumb { border-radius: 7px; background: alpha(@window_fg_color, 0.06); }
.hm-cell-title { font-size: 11px; }
.hm-hint { font-size: 11px; opacity: 0.7; }
.hm-empty-title { font-weight: bold; font-size: 15px; }
flowboxchild { padding: 0; background: none; outline: none; }
flowboxchild:selected { background: none; }
"""


def read_colors(path: Path = COLORS) -> dict[str, str]:
    try:
        return {k: v for k, v in tomllib.loads(path.read_text()).items() if isinstance(v, str)}
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def palette_css(colors: dict[str, str]) -> str:
    """libadwaita's named colors, from an Omarchy colors.toml."""
    if not colors.get("background") or not colors.get("foreground"):
        return ""
    bg = colors["background"]
    fg = colors["foreground"]
    accent = colors.get("accent") or colors.get("blue") or fg
    lifted = colors.get("lighter_background") or bg
    sunken = colors.get("dark_background") or bg
    pairs = {
        "window_bg_color": bg,
        "window_fg_color": fg,
        "view_bg_color": sunken,
        "view_fg_color": fg,
        "headerbar_bg_color": bg,
        "headerbar_fg_color": fg,
        "headerbar_backdrop_color": bg,
        "sidebar_bg_color": sunken,
        "sidebar_fg_color": fg,
        "sidebar_backdrop_color": sunken,
        "card_bg_color": lifted,
        "card_fg_color": fg,
        "dialog_bg_color": lifted,
        "dialog_fg_color": fg,
        "popover_bg_color": lifted,
        "popover_fg_color": fg,
        "accent_bg_color": accent,
        "accent_color": accent,
        "accent_fg_color": colors.get("darker_background") or bg,
    }
    if colors.get("red"):
        pairs["destructive_bg_color"] = colors["red"]
        pairs["destructive_color"] = colors["red"]
    return "\n".join(f"@define-color {k} {v};" for k, v in pairs.items())


class OmarchyTheme:
    def __init__(self):
        self.base = Gtk.CssProvider()
        self.base.load_from_string(BASE_CSS)
        self.palette = Gtk.CssProvider()
        display = Gdk.Display.get_default()
        Gtk.StyleContext.add_provider_for_display(display, self.base, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        Gtk.StyleContext.add_provider_for_display(display, self.palette, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self.apply()
        # Omarchy rewrites theme.name on every switch.
        self.monitor = Gio.File.new_for_path(str(STATE / "theme.name")).monitor_file(Gio.FileMonitorFlags.NONE, None)
        self.monitor.connect("changed", lambda *_: self.apply())

    def apply(self) -> None:
        colors = read_colors()
        manager = Adw.StyleManager.get_default()
        mode = colors.get("mode")
        if mode == "light":
            manager.set_color_scheme(Adw.ColorScheme.FORCE_LIGHT)
        elif mode == "dark" or colors:
            manager.set_color_scheme(Adw.ColorScheme.FORCE_DARK)
        else:
            manager.set_color_scheme(Adw.ColorScheme.DEFAULT)
        self.palette.load_from_string(palette_css(colors))
