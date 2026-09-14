#!/usr/bin/env bash

# Apply the KDE Plasma settings from systemsetup.txt.
# Run as the logged-in Plasma desktop user, after packagedump.sh.

set -uo pipefail

readonly SCRIPT_NAME=${0##*/}
FAILURES=()

ok()   { printf '\033[1;32m  OK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m  FAILED:\033[0m %s\n' "$*" >&2; FAILURES+=("$*"); }
die()  { printf '\033[1;31m[%s] ERROR: %s\033[0m\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run this as your logged-in desktop user, not with sudo."

writer=$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)
qdbus_cmd=$(command -v qdbus6 || command -v qdbus || true)
[[ -n $writer ]] || die "kwriteconfig was not found. Run packagedump.sh first."

printf '\n\033[1;34m[%s] Applying Oxygen Dark and the blue accent\033[0m\n' "$SCRIPT_NAME"
"$writer" --file kdeglobals --group General --key ColorScheme OxygenDark
"$writer" --file kdeglobals --group KDE --key widgetStyle oxygen
"$writer" --file plasmarc --group Theme --key name oxygen

# Apply the scheme first because doing so overwrites the accent. Then disable
# wallpaper-derived accents and apply KDE's standard light blue (#3daee9).
if command -v plasma-apply-colorscheme >/dev/null; then
    plasma-apply-colorscheme OxygenDark || \
        warn "OxygenDark was not listed; its configuration was written directly"
fi
"$writer" --file kdeglobals --group General --key accentColorFromWallpaper false
"$writer" --file kdeglobals --group General --key AccentColor '61,174,233'
if command -v plasma-apply-colorscheme >/dev/null && \
   plasma-apply-colorscheme --accent-color '#3daee9'; then
    ok "Oxygen Dark with light-blue accent applied"
else
    warn "accent helper was unavailable; light blue was saved for the next login"
fi

printf '\n\033[1;34m[%s] Applying Oxygen icons system-wide\033[0m\n' "$SCRIPT_NAME"
"$writer" --file kdeglobals --group Icons --key Theme oxygen
if command -v plasma-changeicons >/dev/null; then
    if plasma-changeicons oxygen; then
        ok "Oxygen icons applied to KDE and the application launcher"
    else
        fail "the Oxygen icon theme could not be applied"
    fi
else
    warn "icon-theme helper not found; Oxygen was written as the global theme for the next login"
fi

printf '\n\033[1;34m[%s] Applying Oxygen Zion pointers\033[0m\n' "$SCRIPT_NAME"
"$writer" --file kcminputrc --group Mouse --key cursorTheme Oxygen_Zion
if command -v plasma-apply-cursortheme >/dev/null; then
    if plasma-apply-cursortheme Oxygen_Zion; then
        ok "Oxygen Zion cursor applied"
    else
        fail "Oxygen Zion cursor could not be applied"
    fi
else
    warn "cursor helper not found; setting was written for the next login"
fi

printf '\n\033[1;34m[%s] Applying Air splash and Oxygen sounds\033[0m\n' "$SCRIPT_NAME"
"$writer" --file ksplashrc --group KSplash --key Engine --delete
if [[ -f /usr/share/plasma/look-and-feel/org.kde.air/contents/splash/Splash.qml ]]; then
    "$writer" --file ksplashrc --group KSplash --key Theme org.kde.air
    ok "Air post-login splash configured"
else
    fail "Air splash assets are missing; rerun packagedump.sh to install oxygen"
fi
"$writer" --file kdeglobals --group Sounds --key Theme oxygen
ok "Oxygen sound theme configured"

printf '\n\033[1;34m[%s] Configuring Plasma panels\033[0m\n' "$SCRIPT_NAME"
if [[ -z $qdbus_cmd ]] || ! "$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
    org.kde.PlasmaShell.evaluateScript 'print("ready")' >/dev/null 2>&1; then
    fail "Plasma is not running in this user session; panels were not changed"
else
    panel_script=$(cat <<'JAVASCRIPT'
for (const panel of panels()) {
    panel.alignment = "center";
    panel.lengthMode = "fit";
    panel.hiding = "dodgewindows";
    panel.opacity = "translucent";
    panel.floating = true;
    panel.height = 46;
}
JAVASCRIPT
)
    if "$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$panel_script"; then
        ok "panels centered, fit to content, dodge windows, translucent, floating, and set to 46 px"
    else
        fail "Plasma rejected the panel configuration"
    fi
fi

printf '\n\033[1mKDE configuration summary\033[0m\n'
if ((${#FAILURES[@]} == 0)); then
    printf '\033[1;32mAll KDE settings from systemsetup.txt were applied.\033[0m\n'
    printf 'Log out and back in to ensure every setting is visible.\n'
    exit 0
fi

printf '\033[1;33m%d item(s) need attention:\033[0m\n' "${#FAILURES[@]}"
printf '  - %s\n' "${FAILURES[@]}"
exit 1
