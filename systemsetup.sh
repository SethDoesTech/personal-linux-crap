#!/usr/bin/env bash

# Set up Seth's usual Arch Linux workstation.
# Run this as the desktop user, not as root. The script is safe to rerun.

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
SKIP_CACHYOS=false
SKIP_KDE=false

log() {
    printf '\n[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
    printf '\n[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
    printf '\n[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: ./$SCRIPT_NAME [OPTIONS]

Options:
  --skip-cachyos  Do not add/update the CachyOS repositories
  --skip-kde      Do not change Plasma appearance or panel settings
  -h, --help      Show this help
EOF
}

while (($#)); do
    case "$1" in
        --skip-cachyos) SKIP_CACHYOS=true ;;
        --skip-kde) SKIP_KDE=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] || die "Run this as your normal desktop user; sudo is used only where needed."
command -v pacman >/dev/null || die "This script is intended for Arch Linux or an Arch-based system."
command -v flatpak >/dev/null || die "Flatpak must be installed before running this script."
command -v sudo >/dev/null || die "sudo is required."

sudo -v

install_cachyos_repositories() {
    if grep -Eq '^\[cachyos([]-]|])' /etc/pacman.conf; then
        log "CachyOS repositories are already configured."
        return
    fi

    log "Adding the official CachyOS repositories (the installer selects your CPU level)."
    local work_dir archive
    work_dir=$(mktemp -d)
    archive="$work_dir/cachyos-repo.tar.xz"
    trap 'rm -rf -- "$work_dir"' RETURN

    curl --fail --location --proto '=https' --tlsv1.2 \
        https://mirror.cachyos.org/cachyos-repo.tar.xz \
        --output "$archive"
    tar -xJf "$archive" -C "$work_dir"
    [[ -x $work_dir/cachyos-repo/cachyos-repo.sh ]] || \
        die "The downloaded CachyOS repository installer did not have the expected layout."
    sudo "$work_dir/cachyos-repo/cachyos-repo.sh"
}

if ! $SKIP_CACHYOS; then
    command -v curl >/dev/null || sudo pacman -S --needed --noconfirm curl
    install_cachyos_repositories
fi

log "Updating the system and installing native packages."
native_packages=(
    amd-ucode
    archiso
    cmake
    code
    davinci-resolve
    gnome-boxes
    # CachyOS mesa-git includes Radeon Vulkan and provides opencl-mesa/opencl-driver.
    mesa-git
    oxygen
    oxygen-sounds
    reaper
)
sudo pacman -Syu --needed --noconfirm "${native_packages[@]}"
if ! pacman -T opencl-driver >/dev/null 2>&1; then
    die "No OpenCL driver is installed; DaVinci Resolve will not work with the AMD GPU."
fi

log "Enabling Flathub and installing Flatpak applications."
flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

flatpak_apps=(
    com.anydesk.Anydesk
    com.heroicgameslauncher.hgl
    com.usebottles.bottles
    com.valvesoftware.Steam
    org.prismlauncher.PrismLauncher
    org.vinegarhq.Sober
)

for app_id in "${flatpak_apps[@]}"; do
    if ! flatpak install --user --noninteractive --or-update flathub "$app_id"; then
        warn "Could not install $app_id; continuing with the remaining applications."
    fi
done

configure_plasma() {
    [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]] || {
        warn "A KDE Plasma session was not detected; skipping desktop customization."
        return
    }

    log "Applying the Oxygen look, blue accent, cursor, splash screen, and sounds."

    if command -v plasma-apply-lookandfeel >/dev/null; then
        plasma-apply-lookandfeel --apply org.kde.oxygen.desktop || \
            warn "The Oxygen global theme could not be applied automatically."
    elif command -v lookandfeeltool >/dev/null; then
        lookandfeeltool -a org.kde.oxygen.desktop || \
            warn "The Oxygen global theme could not be applied automatically."
    fi

    if command -v plasma-apply-cursortheme >/dev/null; then
        plasma-apply-cursortheme Oxygen_Zion || \
            warn "Oxygen Zion was not found; choose it manually in System Settings."
    fi

    local config_writer
    config_writer=$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)
    if [[ -n $config_writer ]]; then
        "$config_writer" --file kdeglobals --group General --key AccentColor '61,174,233'
        "$config_writer" --file plasmarc --group Theme --key name oxygen
        "$config_writer" --file plasmarc --group Sounds --key Theme oxygen
        "$config_writer" --file ksplashrc --group KSplash --key Theme org.kde.air.desktop
        "$config_writer" --file ksplashrc --group KSplash --key Engine KSplashQML
    fi

    local qdbus_cmd
    qdbus_cmd=$(command -v qdbus6 || command -v qdbus || true)
    if [[ -z $qdbus_cmd ]]; then
        warn "qdbus was not found; panel settings must be applied manually."
        return
    fi

    log "Updating each Plasma panel: centered, fit-content, dodge windows, translucent, floating, 46 px."
    local panel_script
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
    "$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$panel_script" || \
        warn "Plasma rejected the panel update; apply those settings manually."
}

if ! $SKIP_KDE; then
    configure_plasma
fi

log "Setup complete. Log out and back in (or reboot) to ensure all desktop and driver changes take effect."
