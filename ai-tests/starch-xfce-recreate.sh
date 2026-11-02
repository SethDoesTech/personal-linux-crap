#!/usr/bin/env bash
# Recreate the lightweight Starch Xfce appearance on an existing Xfce install.
# Run as your desktop user: bash starch-xfce-recreate.sh
set -euo pipefail

if (( EUID == 0 )); then
  echo 'Run as your normal desktop user, not root.' >&2
  exit 1
fi

for cmd in pacman sudo xfconf-query xfce4-panel; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }
done

backup="$HOME/.local/share/starch-xfce-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
if [[ -d "$HOME/.config/xfce4" ]]; then
  cp -a "$HOME/.config/xfce4" "$backup/"
fi
for channel in xsettings xfwm4 xfce4-panel; do
  xfconf-query -c "$channel" -lv > "$backup/$channel.txt" 2>/dev/null || true
done
echo "Backup: $backup"

# All packages come from Arch's configured repos. No AUR, icon or font changes.
sudo pacman -S --needed materia-gtk-theme xfce4-docklike-plugin \
  xfce4-whiskermenu-plugin lightdm lightdm-slick-greeter

set_xfconf() {
  local channel="$1" prop="$2" type="$3" value="$4"
  if xfconf-query -c "$channel" -p "$prop" >/dev/null 2>&1; then
    xfconf-query -c "$channel" -p "$prop" -s "$value"
  else
    xfconf-query -c "$channel" -p "$prop" --create -t "$type" -s "$value"
  fi
}

if [[ "${XDG_CURRENT_DESKTOP:-}" == *XFCE* || "${XDG_CURRENT_DESKTOP:-}" == *Xfce* ]]; then
  set_xfconf xsettings /Net/ThemeName string Materia-dark
  set_xfconf xfwm4 /general/theme string Materia-dark
  set_xfconf xfwm4 /general/tile_on_move bool true
  set_xfconf xfwm4 /general/wrap_windows bool false
  set_xfconf xfwm4 /general/use_compositing bool true
  set_xfconf xfwm4 /general/show_frame_shadow bool true
  set_xfconf xfwm4 /general/show_popup_shadow bool false
  echo 'Materia-dark and native edge snapping configured.'
else
  echo 'Not currently in Xfce; skipped live appearance changes.'
fi

# The existing panel should be preserved rather than guessing at plugin IDs.
if [[ -n "${DISPLAY:-}" ]]; then
  if xfconf-query -c xfce4-panel -lv 2>/dev/null | grep -Eq '^/plugins/plugin-[0-9]+[[:space:]]+docklike([[:space:]]|$)'; then
    echo 'Docklike is already registered in an Xfce panel.'
  else
    echo 'Adding Docklike. Xfce may ask which panel to use.'
    xfce4-panel --add=docklike || echo 'Add Docklike through Panel Preferences > Items.'
  fi
fi

# Optional greeter configuration; never switch the active display manager here.
# WALLPAPER=/path/to/readable/image bash starch-xfce-recreate.sh
wallpaper="${WALLPAPER:-}"
if [[ -n "$wallpaper" && ( ! -f "$wallpaper" || ! -r "$wallpaper" ) ]]; then
  echo "WALLPAPER is not a readable image file: $wallpaper" >&2
  exit 1
fi
if [[ -n "$wallpaper" ]]; then
  if ! sudo -u nobody test -r "$wallpaper" 2>/dev/null; then
    echo 'Warning: wallpaper may not be readable by the LightDM greeter; using fallback color.' >&2
    wallpaper=""
  fi
fi

greeter_conf=/etc/lightdm/slick-greeter.conf
if sudo test -f "$greeter_conf"; then
  sudo cp -a "$greeter_conf" "$backup/slick-greeter.conf.original"
  sudo chown "$(id -u):$(id -g)" "$backup/slick-greeter.conf.original"
fi
if [[ -z "$wallpaper" ]]; then
  background='#242832'
else
  background="$wallpaper"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
[Greeter]
background=$background
background-color=#242832
draw-user-backgrounds=true
draw-grid=false
theme-name=Materia-dark
show-clock=true
show-power=true
EOF
sudo install -Dm644 "$tmp" "$greeter_conf"

lightdm_dropin=/etc/lightdm/lightdm.conf.d/70-starch-slick.conf
if sudo test -f "$lightdm_dropin"; then
  sudo cp -a "$lightdm_dropin" "$backup/70-starch-slick.conf.original"
  sudo chown "$(id -u):$(id -g)" "$backup/70-starch-slick.conf.original"
fi
printf '[Seat:*]\ngreeter-session=lightdm-slick-greeter\n' > "$tmp"
sudo install -Dm644 "$tmp" "$lightdm_dropin"

echo
echo 'Done. Your packages, icons, fonts, wallpaper and panel items were preserved.'
echo 'Open Panel Preferences > Items, move Docklike beside Whisker and your update utility,'
echo 'then REMOVE "Window Buttons" only after Docklike shows running applications.'
echo 'LightDM/Slick is configured, but your current display manager was NOT switched.'
echo 'On OpenRC, configure the LightDM service and disable SDDM only after testing.'
echo "Saved backups: $backup"
