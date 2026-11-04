#!/bin/bash
#
# Installs Hypermeme on Linux, set up for Omarchy and Hyprland.
#
#   curl -fsSL https://raw.githubusercontent.com/alexisbcz/hypermeme/main/install.sh | bash
#
# (The top-level install.sh hands Linux over to this script.) From a checkout:
#
#   linux/install.sh
#
# Options (pass after `bash -s --` when piping):
#   --ref <branch|tag>   install another branch or tag (default: main)
#   --key "<keys>"       the panel's shortcut (default: "SUPER + CTRL + M")
#   --no-bind            don't add the Hyprland shortcut
#   --no-autostart       don't start Hypermeme at login
#   --no-open            don't open the main window when done
#   --uninstall          remove Hypermeme (your memes stay)
#
# Everything lives in main() so a half-downloaded script can't run.

set -euo pipefail

APP_NAME="Hypermeme"
APP_ID="dev.alexis.Hypermeme"
REPO="alexisbcz/hypermeme"

LIB_DIR="$HOME/.local/lib/hypermeme"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
BEGIN_MARK="-- >>> hypermeme >>>"
END_MARK="-- <<< hypermeme <<<"
CONF_BEGIN="# >>> hypermeme >>>"
CONF_END="# <<< hypermeme <<<"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

step() { printf '%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//' || true; }

# When piped from curl, stdin is the script, so sudo has to ask on the terminal.
have_tty() { (exec </dev/tty) 2>/dev/null; }

# Removes the lines between our markers (inclusive) from a file.
strip_block() {
  local file=$1 begin=$2 end=$3
  [[ -f $file ]] || return 0
  grep -qF -- "$begin" "$file" || return 0
  awk -v b="$begin" -v e="$end" '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$file" >"$file.hypermeme-tmp"
  # Drop the blank line the block was separated by, if it's now trailing.
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file.hypermeme-tmp"
  cat "$file.hypermeme-tmp" >"$file"
  rm -f "$file.hypermeme-tmp"
}

# Keeps a copy of a config before Hypermeme first touches it.
backup() {
  local file=$1
  [[ -f $file ]] || return 0
  grep -qF -- "$BEGIN_MARK" "$file" && return 0
  grep -qF -- "$CONF_BEGIN" "$file" && return 0
  cp "$file" "$file.bak.$(date +%s)-hypermeme"
  return 0
}

quit_running() {
  if command -v gdbus >/dev/null; then
    gdbus call --session --dest "$APP_ID" --object-path /dev/alexis/Hypermeme \
      --method org.freedesktop.Application.ActivateAction quit '[]' '{}' >/dev/null 2>&1 || true
  fi
  local tries=0
  while pgrep -f "python3 -m hypermeme" >/dev/null 2>&1 && ((tries++ < 25)); do sleep 0.2; done
  pkill -f "python3 -m hypermeme" 2>/dev/null || true
}

hypr_reload() {
  command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 0
  hyprctl reload >/dev/null 2>&1 || true
  local errors
  errors=$(hyprctl configerrors 2>/dev/null || true)
  if [[ -n $errors && $errors != *"no errors"* ]] && grep -qi hypermeme <<<"$errors"; then
    warn "Hyprland didn't accept Hypermeme's config:"
    printf '%s\n' "$errors" >&2
    return 1
  fi
  return 0
}

# Arch package names for what Hypermeme needs.
check_dependencies() {
  local missing=()
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null || missing+=(python)
  python3 -c 'import gi' 2>/dev/null || missing+=(python-gobject)
  python3 -c 'import cairo' 2>/dev/null || missing+=(python-cairo)
  python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' 2>/dev/null || missing+=(gtk4)
  python3 -c 'import gi; gi.require_version("Adw", "1"); from gi.repository import Adw; assert Adw.MINOR_VERSION >= 7' 2>/dev/null || missing+=(libadwaita)
  python3 -c 'import gi; gi.require_version("Gtk4LayerShell", "1.0")' 2>/dev/null || missing+=(gtk4-layer-shell)
  command -v wl-copy >/dev/null || missing+=(wl-clipboard)
  command -v notify-send >/dev/null || missing+=(libnotify)
  command -v git >/dev/null || missing+=(git)
  ((${#missing[@]} == 0)) && { info "Everything Hypermeme needs is installed"; return; }

  info "Missing: ${missing[*]}"
  if command -v pacman >/dev/null; then
    have_tty || die "Install them first: sudo pacman -S --needed ${missing[*]}"
    step "Installing ${missing[*]} (needs your password)"
    sudo pacman -S --needed --noconfirm "${missing[@]}" </dev/tty
  else
    die "Install these with your package manager, then run this again: ${missing[*]} (names are Arch's)"
  fi
}

install_files() {
  local src=$1
  step "Installing to $LIB_DIR"
  quit_running
  rm -rf "$LIB_DIR"
  mkdir -p "$LIB_DIR" "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
  cp -r "$src/linux/bin" "$src/linux/hypermeme" "$src/linux/data" "$LIB_DIR/"
  find "$LIB_DIR" -name __pycache__ -type d -prune -exec rm -rf {} +
  chmod +x "$LIB_DIR/bin/hypermeme"
  ln -sf "$LIB_DIR/bin/hypermeme" "$BIN_DIR/hypermeme"
  info "Command: $BIN_DIR/hypermeme"

  sed "s|@BIN@|$BIN_DIR/hypermeme|g" "$LIB_DIR/data/$APP_ID.desktop" >"$APPS_DIR/$APP_ID.desktop"
  cp "$LIB_DIR/data/$APP_ID.png" "$ICON_DIR/$APP_ID.png"
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "${ICON_DIR%/512x512/apps}" 2>/dev/null || true
  command -v xdg-mime >/dev/null && xdg-mime default "$APP_ID.desktop" x-scheme-handler/hypermeme 2>/dev/null || true
  info "Launcher entry and hypermeme:// links"
}

# Whether another binding (not Hypermeme's own) uses the keys. Omarchy lists
# "SUPER + CTRL + M" as "SUPER CTRL + M → Description".
key_taken() {
  command -v omarchy >/dev/null || return 1
  local mods=${1% + *} last=${1##* + }
  local printed="${mods//+ /} + $last"
  omarchy menu keybindings --print 2>/dev/null | awk -F' → ' -v k="$printed" '
    { name = $1; sub(/[ \t]+$/, "", name) }
    toupper(name) == toupper(k) && $2 != "Hypermeme" { found = 1 }
    END { exit !found }'
}

# Omarchy configures Hyprland in Lua; older setups use hyprland.conf.
setup_hyprland() {
  local key=$1 bind=$2 autostart=$3 command="$BIN_DIR/hypermeme"
  [[ -d $HYPR_DIR ]] || { info "No Hyprland config found; add a shortcut for: $command toggle"; return; }

  if [[ -f $HYPR_DIR/bindings.lua ]]; then
    if ((bind)); then
      backup "$HYPR_DIR/bindings.lua"
      strip_block "$HYPR_DIR/bindings.lua" "$BEGIN_MARK" "$END_MARK"
      if key_taken "$key"; then
        warn "$key is already bound; skipping the shortcut. Pick another with --key."
      else
        printf '\n%s\no.bind("%s", "Hypermeme", "%s toggle")\n%s\n' "$BEGIN_MARK" "$key" "$command" "$END_MARK" >>"$HYPR_DIR/bindings.lua"
        info "Shortcut: $key, in $HYPR_DIR/bindings.lua"
      fi
    fi
    if ((autostart)) && [[ -f $HYPR_DIR/autostart.lua ]]; then
      backup "$HYPR_DIR/autostart.lua"
      strip_block "$HYPR_DIR/autostart.lua" "$BEGIN_MARK" "$END_MARK"
      printf '\n%s\no.launch_on_start("%s --background")\n%s\n' "$BEGIN_MARK" "$command" "$END_MARK" >>"$HYPR_DIR/autostart.lua"
      info "Starts at login, from $HYPR_DIR/autostart.lua"
    fi
  else
    local conf=$HYPR_DIR/hyprland.conf
    [[ -f $HYPR_DIR/bindings.conf ]] && conf=$HYPR_DIR/bindings.conf
    backup "$conf"
    strip_block "$conf" "$CONF_BEGIN" "$CONF_END"
    # "SUPER + CTRL + M" becomes "SUPER CTRL, M".
    local mods=${key% + *} last=${key##* + }
    {
      printf '\n%s\n' "$CONF_BEGIN"
      ((bind)) && printf 'bindd = %s, %s, Hypermeme, exec, %s toggle\n' "${mods//+ /}" "$last" "$command"
      ((autostart)) && printf 'exec-once = %s --background\n' "$command"
      printf '%s\n' "$CONF_END"
    } >>"$conf"
    info "Shortcut and autostart in $conf"
  fi

  if ! hypr_reload; then
    strip_block "$HYPR_DIR/bindings.lua" "$BEGIN_MARK" "$END_MARK"
    strip_block "$HYPR_DIR/autostart.lua" "$BEGIN_MARK" "$END_MARK"
    hypr_reload || true
    warn "Removed Hypermeme's Hyprland lines again. Bind \"$command toggle\" yourself."
  fi
}

start_app() {
  local open=$1
  step "Starting $APP_NAME"
  if command -v uwsm-app >/dev/null; then
    setsid uwsm-app -- "$BIN_DIR/hypermeme" --background >/dev/null 2>&1 </dev/null &
  else
    setsid "$BIN_DIR/hypermeme" --background >/dev/null 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
  local tries=0
  until gdbus introspect --session --dest "$APP_ID" --object-path /dev/alexis/Hypermeme >/dev/null 2>&1 || ((tries++ > 40)); do
    sleep 0.25
  done
  ((open)) && "$BIN_DIR/hypermeme" >/dev/null 2>&1 &
  return 0
}

uninstall() {
  quit_running
  rm -rf "$LIB_DIR"
  rm -f "$BIN_DIR/hypermeme" "$APPS_DIR/$APP_ID.desktop" "$ICON_DIR/$APP_ID.png"
  for file in "$HYPR_DIR/bindings.lua" "$HYPR_DIR/autostart.lua"; do
    strip_block "$file" "$BEGIN_MARK" "$END_MARK"
  done
  for file in "$HYPR_DIR/bindings.conf" "$HYPR_DIR/hyprland.conf"; do
    strip_block "$file" "$CONF_BEGIN" "$CONF_END"
  done
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
  hypr_reload || true
  step "Removed $APP_NAME"
  info "Your memes stay in ${XDG_DATA_HOME:-$HOME/.local/share}/hypermeme; delete it for a clean slate."
}

main() {
  local ref=main bind=1 autostart=1 open=1 remove=0 key="SUPER + CTRL + M"
  while (($#)); do
    case $1 in
      --ref) ref=${2:?--ref needs a branch or tag}; shift 2 ;;
      --key) key=${2:?--key needs keys, like "SUPER + CTRL + M"}; shift 2 ;;
      --no-bind) bind=0; shift ;;
      --no-autostart) autostart=0; shift ;;
      --no-open) open=0; shift ;;
      --uninstall) remove=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
  [[ "$(uname -s)" == Linux ]] || die "This installer is for Linux. On a Mac, use the top-level install.sh."
  if ((remove)); then
    uninstall
    return
  fi

  printf '\n%sInstalling %s%s\n\n' "$BOLD" "$APP_NAME" "$RESET"
  step "Checking your system"
  [[ -n ${WAYLAND_DISPLAY:-} ]] || warn "No Wayland session found. Hypermeme is made for Wayland (Hyprland, Omarchy)."
  command -v omarchy >/dev/null && info "Omarchy $(omarchy version 2>/dev/null || true)"
  check_dependencies

  # A checkout installs itself; a piped script fetches the source first.
  local here src
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)
  if [[ -n $here && -d $here/hypermeme && -x $here/bin/hypermeme ]]; then
    src=$(dirname "$here")
    info "Installing from $src"
  else
    WORK=$(mktemp -d -t hypermeme-install.XXXXXX)
    trap 'rm -rf "$WORK"' EXIT
    step "Fetching the source ($ref)"
    git clone --quiet --depth 1 --branch "$ref" "https://github.com/$REPO.git" "$WORK/src" ||
      die "Couldn't clone $REPO at $ref."
    info "$(git -C "$WORK/src" log -1 --format='%h %s')"
    src=$WORK/src
  fi

  install_files "$src"
  step "Setting up Hyprland"
  setup_hyprland "$key" "$bind" "$autostart"
  start_app "$open"

  printf '\n%s%s is installed.%s ' "$GREEN$BOLD" "$APP_NAME" "$RESET"
  if ((bind)); then printf 'Press %s anywhere to open the panel.\n\n' "$key"; else printf 'Run "hypermeme toggle" to open the panel.\n\n'; fi
}

main "$@"
