#!/usr/bin/env bash

# Fresh Arch workstation setup based on systemsetup.txt.
# Run as the desktop user from inside a logged-in Plasma session.

set -uo pipefail

readonly SCRIPT_NAME=${0##*/}
SKIP_CACHYOS=false
SKIP_KDE=false
FAILURES=()

log()  { printf '\n\033[1;34m[%s] %s\033[0m\n' "$SCRIPT_NAME" "$*"; }
ok()   { printf '\033[1;32m  OK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARNING:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m  FAILED:\033[0m %s\n' "$*" >&2; FAILURES+=("$*"); }
die()  { printf '\033[1;31m[%s] ERROR: %s\033[0m\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() { printf 'Usage: ./%s [--skip-cachyos] [--skip-kde]\n' "$SCRIPT_NAME"; }

while (($#)); do
    case $1 in
        --skip-cachyos) SKIP_CACHYOS=true ;;
        --skip-kde) SKIP_KDE=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] || die "Run this as your normal desktop user, not with sudo."
command -v pacman >/dev/null || die "pacman was not found; this script requires Arch Linux."
command -v flatpak >/dev/null || die "Install Flatpak before running this script."
command -v sudo >/dev/null || die "sudo is required."

log "Phase 1/7: preflight and administrator access"
sudo -v || die "Could not obtain sudo access."

install_arch_package() {
    local package=$1
    if pacman -Q "$package" >/dev/null 2>&1; then
        ok "$package is already installed"
    elif sudo pacman -S --needed --noconfirm "$package"; then
        ok "installed $package"
    else
        fail "could not install package: $package"
        return 1
    fi
}

install_replacing_package() {
    local package=$1
    if pacman -Q "$package" >/dev/null 2>&1; then
        ok "$package is already installed"
    # Question bit 4 approves removal of packages that conflict with the
    # requested replacement; other normally-negative questions stay negative.
    elif sudo pacman -S --needed --noconfirm --ask=4 "$package"; then
        ok "installed $package and replaced its stable counterpart"
    else
        fail "could not install replacement package: $package"
        return 1
    fi
}

add_cachyos_repositories() {
    if grep -Eq '^\[cachyos([[:alnum:]-]*)\]' /etc/pacman.conf; then
        ok "CachyOS repositories are already present"
        return 0
    fi

    command -v curl >/dev/null || install_arch_package curl || return 1

    local work_dir archive repo_dir
    work_dir=$(mktemp -d) || return 1
    archive="$work_dir/cachyos-repo.tar.xz"

    if ! curl --fail --location --proto '=https' --tlsv1.2 \
        https://mirror.cachyos.org/cachyos-repo.tar.xz --output "$archive"; then
        fail "could not download the official CachyOS repository installer"
        rm -rf -- "$work_dir"
        return 1
    fi
    if ! tar -xJf "$archive" -C "$work_dir"; then
        fail "could not extract the CachyOS repository installer"
        rm -rf -- "$work_dir"
        return 1
    fi

    repo_dir="$work_dir/cachyos-repo"
    if [[ ! -x $repo_dir/cachyos-repo.sh ]]; then
        fail "the CachyOS download did not contain cachyos-repo/cachyos-repo.sh"
        rm -rf -- "$work_dir"
        return 1
    fi

    # The upstream script uses relative files, so it must run from its directory.
    if (cd "$repo_dir" && sudo ./cachyos-repo.sh); then
        ok "CachyOS repositories added"
        rm -rf -- "$work_dir"
        return 0
    fi

    fail "the official CachyOS repository installer returned an error"
    rm -rf -- "$work_dir"
    return 1
}

log "Phase 2/7: CachyOS repositories"
if $SKIP_CACHYOS; then
    warn "CachyOS setup skipped by request"
else
    add_cachyos_repositories || true
fi

log "Phase 3/7: full system upgrade"
if sudo pacman -Syu --noconfirm; then
    ok "system upgraded"
else
    fail "full system upgrade failed; package installs will still be attempted"
fi

log "Phase 4/7: native applications and tools"
arch_packages=(amd-ucode archiso cmake code gnome-boxes oxygen oxygen-sounds)
for package in "${arch_packages[@]}"; do
    install_arch_package "$package" || true
done

log "Phase 5/7: experimental AMD graphics, OpenCL, DaVinci Resolve, and REAPER"
# CachyOS mesa-git replaces stable Mesa/Vulkan and provides opencl-mesa and
# opencl-driver. It must be installed before DaVinci Resolve.
install_replacing_package mesa-git || true

if pacman -Q lib32-mesa >/dev/null 2>&1 || pacman -Q lib32-mesa-git >/dev/null 2>&1; then
    install_replacing_package lib32-mesa-git || true
fi

if pacman -T opencl-driver >/dev/null 2>&1; then
    ok "an OpenCL driver is installed"
else
    fail "no OpenCL driver is installed after mesa-git"
fi

install_arch_package davinci-resolve || true
install_arch_package reaper || true

install_flatpak_app() {
    local app_id=$1
    if flatpak info --user "$app_id" >/dev/null 2>&1 || \
       flatpak info --system "$app_id" >/dev/null 2>&1; then
        ok "$app_id is already installed"
    elif flatpak install --user --noninteractive --or-update flathub "$app_id"; then
        ok "installed $app_id"
    else
        fail "could not install Flatpak: $app_id"
    fi
}

log "Phase 6/7: Flatpak applications and their required runtimes"
if flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo; then
    ok "Flathub is configured"
else
    fail "could not configure Flathub"
fi

flatpak_apps=(
    com.anydesk.Anydesk
    com.heroicgameslauncher.hgl
    com.usebottles.bottles
    com.valvesoftware.Steam
    org.prismlauncher.PrismLauncher
    org.vinegarhq.Sober
)
for app_id in "${flatpak_apps[@]}"; do
    install_flatpak_app "$app_id"
done

# The Freedesktop/GNOME/KDE platforms, Mesa/GL32, codecs, Wine Gecko/Mono,
# Breeze GTK theme, and AMD AMF entries are dependency-managed runtimes and
# extensions. Installing the apps resolves their correct current branches.
if flatpak update --user --noninteractive; then
    ok "Flatpak applications, runtimes, and extensions updated"
else
    fail "one or more Flatpak runtimes/extensions could not be updated"
fi

configure_plasma() {
    local writer qdbus_cmd panel_script
    writer=$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)
    qdbus_cmd=$(command -v qdbus6 || command -v qdbus || true)

    if [[ -z $writer ]]; then
        fail "kwriteconfig was not found; Plasma appearance could not be configured"
        return
    fi

    if command -v plasma-apply-colorscheme >/dev/null; then
        plasma-apply-colorscheme OxygenDark || \
            warn "OxygenDark was not listed; writing the setting directly"
    fi
    "$writer" --file kdeglobals --group General --key ColorScheme OxygenDark
    "$writer" --file kdeglobals --group General --key AccentColor '61,174,233'
    "$writer" --file kdeglobals --group KDE --key widgetStyle oxygen
    "$writer" --file plasmarc --group Theme --key name oxygen
    "$writer" --file kdeglobals --group Sounds --key Theme oxygen
    "$writer" --file ksplashrc --group KSplash --key Engine KSplashQML
    "$writer" --file ksplashrc --group KSplash --key Theme org.kde.air
    "$writer" --file kcminputrc --group Mouse --key cursorTheme Oxygen_Zion

    if command -v plasma-apply-cursortheme >/dev/null; then
        plasma-apply-cursortheme Oxygen_Zion || \
            warn "the cursor command did not recognize Oxygen_Zion; config was still written"
    fi

    if [[ -z $qdbus_cmd ]] || ! "$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript 'print("ready")' >/dev/null 2>&1; then
        fail "Plasma is not running in this user session; panel settings could not be applied"
        return
    fi

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
        ok "Plasma appearance and panels configured"
    else
        fail "Plasma rejected the panel configuration"
    fi
}

log "Phase 7/7: KDE Plasma appearance and panels"
if $SKIP_KDE; then
    warn "KDE setup skipped by request"
else
    configure_plasma
fi

printf '\n\033[1mSetup summary\033[0m\n'
if ((${#FAILURES[@]} == 0)); then
    printf '\033[1;32mEverything in systemsetup.txt completed successfully.\033[0m\n'
    printf 'Reboot to load the updated graphics stack and desktop settings.\n'
    exit 0
fi

printf '\033[1;33mCompleted all phases, but %d item(s) need attention:\033[0m\n' "${#FAILURES[@]}"
printf '  - %s\n' "${FAILURES[@]}"
printf 'Fix the listed item(s), then rerun this script; completed work will be skipped.\n'
exit 1
