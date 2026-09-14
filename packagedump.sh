#!/usr/bin/env bash

# Install the repositories, native packages, graphics stack, and Flatpaks from
# systemsetup.txt. Run as a normal user; sudo is used internally.

set -uo pipefail

readonly SCRIPT_NAME=${0##*/}
FAILURES=()

log()  { printf '\n\033[1;34m[%s] %s\033[0m\n' "$SCRIPT_NAME" "$*"; }
ok()   { printf '\033[1;32m  OK:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAILED:\033[0m %s\n' "$*" >&2; FAILURES+=("$*"); }
die()  { printf '\033[1;31m[%s] ERROR: %s\033[0m\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not with sudo."
command -v pacman >/dev/null || die "pacman was not found; this requires Arch Linux."
command -v flatpak >/dev/null || die "Install Flatpak before running this script."
command -v sudo >/dev/null || die "sudo is required."

log "Phase 1/6: administrator access"
sudo -v || die "Could not obtain sudo access."

install_package() {
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

install_replacement() {
    local package=$1
    if pacman -Q "$package" >/dev/null 2>&1; then
        ok "$package is already installed"
    # Question bit 4 approves removal of conflicting stable Mesa packages.
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

    command -v curl >/dev/null || install_package curl || return 1

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
        fail "the download did not contain cachyos-repo/cachyos-repo.sh"
        rm -rf -- "$work_dir"
        return 1
    fi

    # The upstream installer depends on files relative to its working directory.
    if (cd "$repo_dir" && sudo ./cachyos-repo.sh); then
        ok "CachyOS repositories added"
    else
        fail "the official CachyOS repository installer returned an error"
        rm -rf -- "$work_dir"
        return 1
    fi
    rm -rf -- "$work_dir"
}

log "Phase 2/6: CachyOS repositories"
add_cachyos_repositories || true

log "Phase 3/6: full system upgrade"
if sudo pacman -Syu --noconfirm; then
    ok "system upgraded"
else
    fail "full system upgrade failed; remaining installs will still be attempted"
fi

log "Phase 4/6: native applications, tools, and KDE theme packages"
packages=(amd-ucode archiso cmake code gnome-boxes oxygen oxygen-icons oxygen-sounds)
for package in "${packages[@]}"; do
    install_package "$package" || true
done

log "Phase 5/6: experimental AMD stack, OpenCL, DaVinci Resolve, and REAPER"
# CachyOS mesa-git provides Mesa, Radeon Vulkan, opencl-mesa, and opencl-driver.
install_replacement mesa-git || true

if pacman -Q lib32-mesa >/dev/null 2>&1 || pacman -Q lib32-mesa-git >/dev/null 2>&1; then
    install_replacement lib32-mesa-git || true
fi

if pacman -T opencl-driver >/dev/null 2>&1; then
    ok "an OpenCL driver is installed"
else
    fail "no OpenCL driver is installed after mesa-git"
fi
install_package davinci-resolve || true
install_package reaper || true

install_flatpak() {
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

log "Phase 6/6: Flatpak applications and runtimes"
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
    install_flatpak "$app_id"
done

# Platforms, Mesa/GL32, codecs, Gecko/Mono, Breeze GTK, and AMD AMF are
# dependency-managed runtimes/extensions pulled in at the appropriate branches.
if flatpak update --user --noninteractive; then
    ok "Flatpak applications, runtimes, and extensions updated"
else
    fail "one or more Flatpak runtimes/extensions could not be updated"
fi

printf '\n\033[1mPackage setup summary\033[0m\n'
if ((${#FAILURES[@]} == 0)); then
    printf '\033[1;32mAll package setup completed successfully.\033[0m\n'
    printf 'Reboot before running KDE configuration so the new graphics stack is loaded.\n'
    exit 0
fi

printf '\033[1;33mAll phases ran, but %d item(s) need attention:\033[0m\n' "${#FAILURES[@]}"
printf '  - %s\n' "${FAILURES[@]}"
printf 'Fix those items and rerun this script; completed work will be skipped.\n'
exit 1
