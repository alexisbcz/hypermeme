"""Puts a finished meme on the clipboard and pastes it into the window you were using.

On Hyprland the paste is a Ctrl+V sent by the compositor, the way Omarchy's universal paste
(Super+V) does it, so it reaches whatever had focus before the panel opened. Elsewhere wtype
types it, and without either the meme is only copied.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from gi.repository import GLib

# Pressing and releasing in two steps keeps Hyprland from leaving the key stuck.
_PASTE_LUA = (
    'hl.dispatch(hl.dsp.send_key_state({ mods = "CTRL", key = "V", state = "down" })) '
    'hl.timer(function() hl.dispatch(hl.dsp.send_key_state({ mods = "CTRL", key = "V", state = "up" })) end, '
    '{ timeout = 50, type = "oneshot" })'
)


def on_hyprland() -> bool:
    return bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")) and shutil.which("hyprctl") is not None


def focus_window(app_class: str) -> None:
    """Brings a window forward, switching to its workspace, as Omarchy's launch-or-focus does.
    Hyprland ignores a plain activation request from a window on another workspace."""
    if on_hyprland():
        subprocess.Popen(
            ["hyprctl", "dispatch", f'hl.dsp.focus({{ window = "class:^{app_class}$" }})'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def copy(file: Path) -> bool:
    """Copies the PNG as an image. wl-copy keeps serving it after Hypermeme moves on."""
    if shutil.which("wl-copy"):
        with open(file, "rb") as data:
            result = subprocess.run(["wl-copy", "--type", "image/png"], stdin=data, timeout=5)
        return result.returncode == 0
    return False


def paste_shortcut() -> bool:
    if on_hyprland():
        result = subprocess.run(["hyprctl", "eval", _PASTE_LUA], capture_output=True, text=True, timeout=3)
        if result.returncode == 0 and "error" not in result.stdout.lower():
            return True
    if shutil.which("wtype"):
        return subprocess.run(["wtype", "-M", "ctrl", "v", "-m", "ctrl"], timeout=3).returncode == 0
    return False


def insert(file: Path, delay_ms: int = 140) -> None:
    """Copies, then pastes once focus is back on the window underneath."""
    if not copy(file):
        notify("Couldn't copy the meme", "Install wl-clipboard: sudo pacman -S wl-clipboard")
        return

    def paste():
        if not paste_shortcut():
            notify("Copied", "Paste it with Ctrl+V.")
        return False

    GLib.timeout_add(delay_ms, paste)


def notify(title: str, body: str = "") -> None:
    if shutil.which("notify-send"):
        subprocess.Popen(
            ["notify-send", "--app-name=Hypermeme", "--icon=dev.alexis.Hypermeme", "--expire-time=2500", title, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
