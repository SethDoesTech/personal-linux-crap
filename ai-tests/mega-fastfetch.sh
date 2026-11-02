#!/usr/bin/env bash
# mega-fastfetch: a read-only, dependency-tolerant Linux inventory report.
# No sudo, network access, package installation, or configuration changes.
set -uo pipefail
export LC_ALL=C

VERSION='1.0.0'
COLOR=1
SHOW_ALL=1
SHOW_PRIVATE=0
OUTPUT='text'
WIDTH=78

usage() {
  cat <<'HELP'
Usage: mega-fastfetch.sh [OPTIONS]
  --no-color       Disable ANSI colors
  --compact        Show only primary hardware and software sections
  --private        Include potentially identifying host/network details
  --json           Output a structured JSON object (requires python3)
  --help           Show this help
Examples:
  bash mega-fastfetch.sh
  bash mega-fastfetch.sh --compact --no-color
  bash mega-fastfetch.sh --private --json > system-report.json
The script does not require root and does not modify the system.
HELP
}

for arg in "$@"; do
  case "$arg" in
    --no-color) COLOR=0 ;;
    --compact) SHOW_ALL=0 ;;
    --private) SHOW_PRIVATE=1 ;;
    --json) OUTPUT='json'; COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then COLOR=0; fi
if [[ "$OUTPUT" == json ]] && ! command -v python3 >/dev/null 2>&1; then
  printf 'JSON output requires python3.\n' >&2
  exit 2
fi

if (( COLOR )); then
  C_TITLE=$'\033[1;36m'
  C_KEY=$'\033[1;34m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_TITLE='' C_KEY='' C_DIM='' C_RESET=''
fi

# All record values are held as alternating section/key/value entries.
declare -a SECTIONS=()
declare -a KEYS=()
declare -a VALUES=()
CURRENT_SECTION='System'

has() { command -v "$1" >/dev/null 2>&1; }
trim() {
  local text=${1:-}
  text=${text//$'\r'/}
  text=${text//$'\n'/ }
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}
first_line() {
  local line=''
  IFS= read -r line || true
  trim "$line"
}
file_value() {
  local file=$1 line=''
  [[ -r "$file" ]] || return 1
  IFS= read -r line < "$file" || true
  trim "$line"
}
add() {
  local key=$1 value=${2:-}
  value=$(trim "$value")
  [[ -n "$value" ]] || value='Not available'
  SECTIONS+=("$CURRENT_SECTION")
  KEYS+=("$key")
  VALUES+=("$value")
}
section() { CURRENT_SECTION=$1; }
read_os_release() {
  local key=$1 line name value
  [[ -r /etc/os-release ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] || continue
    value=${line#*=}
    value=${value#\"}
    value=${value%\"}
    printf '%s' "$value"
    return 0
  done < /etc/os-release
  return 1
}
format_bytes() {
  local n=${1:-0}
  [[ "$n" =~ ^[0-9]+$ ]] || { printf 'Unknown'; return; }
  if has numfmt; then
    numfmt --to=iec --suffix=B "$n" 2>/dev/null || printf '%s B' "$n"
  else
    awk -v n="$n" 'BEGIN { split("B KiB MiB GiB TiB PiB",u); i=1; while (n>=1024 && i<6) {n/=1024;i++} printf "%.1f %s", n,u[i] }'
  fi
}
join_lines() {
  awk 'NF {gsub(/^[ \t]+|[ \t]+$/, ""); if (n++) printf "; "; printf "%s", $0} END {print ""}'
}
safe_capture() {
  # A timeout prevents stalled hardware queries when coreutils is available.
  if has timeout; then timeout 4 "$@" 2>/dev/null || true
  else "$@" 2>/dev/null || true
  fi
}

collect_system() {
  section 'System'
  add 'Operating system' "$(read_os_release PRETTY_NAME || uname -s)"
  add 'OS ID' "$(read_os_release ID || true)"
  add 'Architecture' "$(uname -m)"
  add 'Kernel' "$(uname -r)"
  add 'Kernel build' "$(uname -v)"
  add 'Boot mode' "$(if [[ -d /sys/firmware/efi ]]; then echo UEFI; else echo BIOS/legacy; fi)"
  if has uptime; then add 'Uptime' "$(safe_capture uptime -p | first_line)"; fi
  if [[ -r /proc/uptime ]]; then
    local uptime_seconds
    uptime_seconds=$(awk '{printf "%.0f",$1}' /proc/uptime)
    add 'Uptime seconds' "$uptime_seconds"
  fi
  if (( SHOW_PRIVATE )); then
    add 'Hostname' "$(hostname 2>/dev/null || true)"
    add 'User' "${USER:-$(id -un)}"
  else
    add 'Identity' 'Hidden (use --private to show hostname and user)'
  fi
  add 'Shell' "${SHELL:-Unknown}"
  add 'Locale' "${LANG:-Unknown}"
  add 'Timezone' "$(date +%Z 2>/dev/null || true)"
}

collect_platform() {
  section 'Platform'
  local vendor product version bios
  vendor=$(file_value /sys/class/dmi/id/sys_vendor || true)
  product=$(file_value /sys/class/dmi/id/product_name || true)
  version=$(file_value /sys/class/dmi/id/product_version || true)
  bios=$(file_value /sys/class/dmi/id/bios_version || true)
  [[ -n "$vendor$product" ]] && add 'Machine' "$vendor $product"
  [[ -n "$version" ]] && add 'Product revision' "$version"
  [[ -n "$bios" ]] && add 'Firmware version' "$bios"
  if has systemd-detect-virt; then
    local virt
    virt=$(safe_capture systemd-detect-virt | first_line)
    [[ "$virt" == none || -z "$virt" ]] && virt='Physical / not detected'
    add 'Virtualization' "$virt"
  elif grep -qi hypervisor /proc/cpuinfo 2>/dev/null; then
    add 'Virtualization' 'Hypervisor detected'
  fi
}

collect_cpu() {
  section 'CPU'
  local model sockets cores threads mhz cache flags
  model=$(awk -F: '/^(model name|Hardware|Processor)[[:space:]]*:/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [[ -n "$model" ]] && add 'Processor' "$model"
  threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  [[ -n "$threads" ]] && add 'Online logical CPUs' "$threads"
  if has lscpu; then
    sockets=$(safe_capture lscpu | awk -F: '/^Socket\(s\):/ {gsub(/ /,"",$2);print $2;exit}')
    cores=$(safe_capture lscpu | awk -F: '/^Core\(s\) per socket:/ {gsub(/ /,"",$2);print $2;exit}')
    [[ -n "$sockets" ]] && add 'Sockets' "$sockets"
    [[ -n "$cores" ]] && add 'Cores per socket' "$cores"
    cache=$(safe_capture lscpu | awk -F: '/^L3 cache:/ {sub(/^[ \t]+/,"",$2);print $2;exit}')
    [[ -n "$cache" ]] && add 'L3 cache' "$cache"
  fi
  mhz=$(awk -F: '/^cpu MHz/ {sum+=$2;n++} END {if(n)printf "%.0f MHz (average)",sum/n}' /proc/cpuinfo 2>/dev/null)
  [[ -n "$mhz" ]] && add 'Current frequency' "$mhz"
  flags=$(awk -F: '/^(flags|Features)[[:space:]]*:/ {print $2;exit}' /proc/cpuinfo 2>/dev/null)
  if [[ "$flags" == *' vmx '* || "$flags" == *' svm '* ]]; then
    add 'Hardware virtualization' 'CPU flag detected'
  fi
  local governor
  governor=$(file_value /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor || true)
  [[ -n "$governor" ]] && add 'CPU governor' "$governor"
}

collect_gpu() {
  section 'GPU and display'
  local found='' driver card line path status
  if has lspci; then
    found=$(safe_capture lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' | join_lines)
    [[ -n "$found" ]] && add 'PCI graphics devices' "$found"
    found=$(safe_capture lspci -k | awk '
      /VGA compatible controller|3D controller|Display controller/ {device=$0; want=1; next}
      want && /Kernel driver in use:/ {sub(/^[ \t]+/,"",$0); print device " -> " $0;want=0}
      want && /^[^ \t]/ {want=0}
    ' | join_lines)
    [[ -n "$found" ]] && add 'Kernel GPU drivers' "$found"
  fi
  found=''
  for path in /sys/class/drm/card[0-9]*; do
    [[ -e "$path" ]] || continue
    card=${path##*/}
    driver=$(readlink -f "$path/device/driver" 2>/dev/null || true)
    [[ -n "$driver" ]] && found+="${card}: ${driver##*/}; "
  done
  [[ -n "$found" ]] && add 'DRM drivers' "${found%; }"
  if has glxinfo && [[ -n "${DISPLAY:-}" ]]; then
    line=$(safe_capture glxinfo -B | awk -F: '/OpenGL renderer string:/ {sub(/^[ \t]+/,"",$2);print $2;exit}')
    [[ -n "$line" ]] && add 'OpenGL renderer' "$line"
  fi
  if has vulkaninfo; then
    line=$(safe_capture vulkaninfo --summary | awk -F= '/deviceName[[:space:]]*=/ {gsub(/^[ \t]+/,"",$2); print $2}' | join_lines)
    [[ -n "$line" ]] && add 'Vulkan devices' "$line"
  fi
  add 'Display server' "${XDG_SESSION_TYPE:-Unknown}"
  add 'Desktop environment' "${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-Unknown}}"
  if has xrandr && [[ "${XDG_SESSION_TYPE:-}" == x11 ]]; then
    line=$(safe_capture xrandr --current | awk '/ connected( primary)? / {print $1 " " $3}' | join_lines)
    [[ -n "$line" ]] && add 'Displays' "$line"
  fi
}

collect_memory() {
  section 'Memory'
  [[ -r /proc/meminfo ]] || return
  local total available swap_total swap_free used
  total=$(awk '/^MemTotal:/ {print $2*1024}' /proc/meminfo)
  available=$(awk '/^MemAvailable:/ {print $2*1024}' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal:/ {print $2*1024}' /proc/meminfo)
  swap_free=$(awk '/^SwapFree:/ {print $2*1024}' /proc/meminfo)
  used=$(( ${total%.*} - ${available%.*} ))
  add 'RAM total' "$(format_bytes "${total%.*}")"
  add 'RAM used (estimated)' "$(format_bytes "$used")"
  add 'RAM available' "$(format_bytes "${available%.*}")"
  add 'Swap total' "$(format_bytes "${swap_total%.*}")"
  add 'Swap used' "$(format_bytes "$(( ${swap_total%.*} - ${swap_free%.*} ))")"
  if has free; then
    add 'Memory summary' "$(safe_capture free -h | awk '/^Mem:/ {print "used " $3 " of " $2 ", available " $7}')"
  fi
}

collect_storage() {
  section 'Storage'
  local disks mounts rootfs
  if has lsblk; then
    disks=$(safe_capture lsblk -dn -o NAME,SIZE,TYPE,MODEL | awk '$3=="disk" {name=$1;size=$2;$1=$2=$3="";sub(/^[ \t]+/,"",$0);print name " (" size ") " $0}' | join_lines)
    [[ -n "$disks" ]] && add 'Physical/virtual disks' "$disks"
    mounts=$(safe_capture lsblk -rno NAME,FSTYPE,MOUNTPOINTS | awk '$3=="/" {print $1 " (" $2 ")";exit}')
    [[ -n "$mounts" ]] && add 'Root block device' "$mounts"
  fi
  if has df; then
    rootfs=$(safe_capture df -hPT / | awk 'NR==2 {print $2 " / " $3 " total / " $4 " used / " $5 " free (" $6 " used)"}')
    [[ -n "$rootfs" ]] && add 'Root filesystem' "$rootfs"
  fi
  if (( SHOW_ALL )) && has findmnt; then
    mounts=$(safe_capture findmnt -rno TARGET,FSTYPE | awk '$1=="/" || $1=="/home" || $1=="/boot" || $1=="/boot/efi" {print $1 "=" $2}' | join_lines)
    [[ -n "$mounts" ]] && add 'Key mount types' "$mounts"
  fi
  local zram=''
  for path in /sys/block/zram[0-9]*; do
    [[ -d "$path" ]] || continue
    zram+="${path##*/} "
  done
  [[ -n "$zram" ]] && add 'ZRAM devices' "${zram% }"
}

collect_init() {
  section 'Init and services'
  local init comm version service_count
  comm=$(ps -p 1 -o comm= 2>/dev/null | first_line)
  init=$(readlink -f /proc/1/exe 2>/dev/null || true)
  add 'PID 1' "${comm:-Unknown}${init:+ ($init)}"
  if [[ "$comm" == systemd ]] && has systemctl; then
    version=$(safe_capture systemctl --version | first_line)
    add 'Init version' "$version"
    if (( SHOW_ALL )); then
      service_count=$(safe_capture systemctl list-units --type=service --state=running --no-legend --no-pager | awk '/\.service[[:space:]]/ {n++} END {print n+0}')
      add 'Running systemd services' "$service_count"
    fi
  elif [[ "$comm" == init ]] && has rc-status; then
    add 'OpenRC' "$(safe_capture rc-status --version | first_line)"
  elif has dinitctl; then
    add 'Dinit utility' 'Installed'
  fi
  if [[ -e /run/systemd/system ]]; then add 'systemd runtime' 'Present'; fi
}

package_count() {
  local manager=$1 result=''
  case "$manager" in
    pacman) result=$(safe_capture pacman -Qq | awk 'END {print NR}') ;;
    dpkg) result=$(safe_capture dpkg-query -W -f='${db:Status-Abbrev}\n' | awk '$1 ~ /^ii/ {n++} END {print n+0}') ;;
    rpm) result=$(safe_capture rpm -qa | awk 'END {print NR}') ;;
    apk) result=$(safe_capture apk info | awk 'END {print NR}') ;;
    xbps) result=$(safe_capture xbps-query -l | awk '$1=="ii" {n++} END {print n+0}') ;;
    flatpak) result=$(safe_capture flatpak list --columns=application | awk 'NF {n++} END {print n+0}') ;;
    snap) result=$(safe_capture snap list | awk 'NR>1 && NF {n++} END {print n+0}') ;;
    nix) result=$(safe_capture nix profile list --json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d.get("elements",{})))' 2>/dev/null || true) ;;
    brew) result=$(safe_capture brew list --formula | awk 'NF {n++} END {print n+0}') ;;
    emerge) result=$(safe_capture qlist -I | awk 'END {print NR}') ;;
    zypper) result=$(safe_capture rpm -qa | awk 'END {print NR}') ;;
    *) return ;;
  esac
  [[ -n "$result" ]] && add "$manager packages" "$result"
}

collect_packages() {
  section 'Package management'
  local manager found=''
  for manager in pacman apt dnf yum zypper apk xbps-install emerge nix brew flatpak snap; do
    if has "$manager"; then found+="$manager, "; fi
  done
  add 'Detected managers' "${found%, }"
  for manager in pacman dpkg rpm apk xbps flatpak snap nix brew; do
    if has "$manager"; then package_count "$manager"; fi
  done
  if has emerge && has qlist; then package_count emerge; fi
  if has pacman && (( SHOW_ALL )); then
    add 'Explicit pacman packages' "$(safe_capture pacman -Qeq | awk 'END {print NR}')"
  fi
  if has flatpak && (( SHOW_ALL )); then
    add 'Flatpak applications' "$(safe_capture flatpak list --app --columns=application | awk 'NF {n++} END {print n+0}')"
  fi
  # Counts represent installed records and may overlap between managers.
}

collect_network() {
  section 'Network'
  local interfaces='' line
  if has ip; then
    interfaces=$(safe_capture ip -br link | awk '$1!="lo" {print $1 " (" $2 ")"}' | join_lines)
    add 'Interfaces' "$interfaces"
    if (( SHOW_PRIVATE )); then
      line=$(safe_capture ip -br -4 addr | awk '$1!="lo" && $3!="" {print $1 " " $3}' | join_lines)
      [[ -n "$line" ]] && add 'IPv4 addresses' "$line"
      line=$(safe_capture ip route show default | join_lines)
      [[ -n "$line" ]] && add 'Default route' "$line"
    fi
  fi
  if has nmcli; then
    line=$(safe_capture nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$3=="connected" {print $1 " (" $2 ")"}' | join_lines)
    [[ -n "$line" ]] && add 'NetworkManager links' "$line"
  fi
  if has resolvectl && (( SHOW_PRIVATE )); then
    line=$(safe_capture resolvectl dns | join_lines)
    [[ -n "$line" ]] && add 'DNS servers' "$line"
  fi
}

collect_power() {
  section 'Power and temperature'
  local bat path capacity status temp sensor_count=0
  for path in /sys/class/power_supply/BAT*; do
    [[ -d "$path" ]] || continue
    bat=${path##*/}
    capacity=$(file_value "$path/capacity" || true)
    status=$(file_value "$path/status" || true)
    add "$bat battery" "${capacity:-?}% (${status:-unknown})"
  done
  if has sensors; then
    temp=$(safe_capture sensors | awk '/Package id 0:|Tctl:|edge:/ {print;exit}' | first_line)
    [[ -n "$temp" ]] && add 'CPU/GPU temperature' "$temp"
  fi
  if (( SHOW_ALL )); then
    for path in /sys/class/thermal/thermal_zone*/temp; do
      [[ -r "$path" ]] || continue
      temp=$(file_value "$path" || true)
      [[ "$temp" =~ ^[0-9]+$ ]] || continue
      (( temp < 1000 || temp > 150000 )) && continue
      add "Thermal zone $sensor_count" "$(awk -v t="$temp" 'BEGIN {printf "%.1f C",t/1000}')"
      sensor_count=$((sensor_count + 1))
      (( sensor_count >= 4 )) && break
    done
  fi
}

collect_extra() {
  (( SHOW_ALL )) || return
  section 'Additional software'
  local app version
  for app in bash fish zsh python3 gcc clang git docker podman; do
    has "$app" || continue
    case "$app" in
      bash) version="${BASH_VERSION%%(*}" ;;
      fish) version=$(safe_capture fish --version | first_line) ;;
      zsh) version=$(safe_capture zsh --version | first_line) ;;
      python3) version=$(safe_capture python3 --version | first_line) ;;
      gcc) version=$(safe_capture gcc -dumpversion | first_line) ;;
      clang) version=$(safe_capture clang --version | first_line) ;;
      git) version=$(safe_capture git --version | first_line) ;;
      docker) version=$(safe_capture docker --version | first_line) ;;
      podman) version=$(safe_capture podman --version | first_line) ;;
    esac
    add "$app" "$version"
  done
  section 'Session'
  add 'Terminal' "${TERM:-Unknown}"
  add 'Wayland display' "${WAYLAND_DISPLAY:+Available}"
  add 'X11 display' "${DISPLAY:+Available}"
  add 'Session desktop' "${XDG_SESSION_DESKTOP:-Unknown}"
  if has loginctl && [[ -n "${XDG_SESSION_ID:-}" ]]; then
    add 'Session ID' "$XDG_SESSION_ID"
  fi
}

collect_security() {
  (( SHOW_ALL )) || return
  section 'Security and kernel capabilities'
  local value
  if [[ -r /sys/kernel/security/lsm ]]; then
    add 'Active Linux security modules' "$(file_value /sys/kernel/security/lsm || true)"
  fi
  if has getenforce; then
    add 'SELinux status' "$(safe_capture getenforce | first_line)"
  fi
  if has aa-status; then
    value=$(safe_capture aa-status --enabled)
    [[ -n "$value" ]] && add 'AppArmor' 'Enabled'
  fi
  if [[ -r /proc/sys/kernel/randomize_va_space ]]; then
    value=$(file_value /proc/sys/kernel/randomize_va_space || true)
    add 'Address-space randomization' "$value (0=off, 1=partial, 2=full)"
  fi
  if [[ -r /proc/sys/kernel/kptr_restrict ]]; then
    add 'Kernel pointer restriction' "$(file_value /proc/sys/kernel/kptr_restrict || true)"
  fi
  if [[ -r /proc/sys/kernel/modules_disabled ]]; then
    add 'Kernel module loading disabled' "$(file_value /proc/sys/kernel/modules_disabled || true)"
  fi
  if has mokutil && [[ -d /sys/firmware/efi ]]; then
    add 'Secure Boot' "$(safe_capture mokutil --sb-state | first_line)"
  fi
  if [[ -r /proc/sys/kernel/osrelease ]]; then
    add 'Kernel release (procfs)' "$(file_value /proc/sys/kernel/osrelease || true)"
  fi
}
render_text() {
  local index previous='' section_name key value
  printf '%b%s%b\n' "$C_TITLE" 'MEGA FASTFETCH — Linux system inventory' "$C_RESET"
  printf '%b%s%b\n' "$C_DIM" "$(printf '%*s' "$WIDTH" '' | tr ' ' '=')" "$C_RESET"
  for index in "${!KEYS[@]}"; do
    section_name=${SECTIONS[index]}
    key=${KEYS[index]}
    value=${VALUES[index]}
    if [[ "$section_name" != "$previous" ]]; then
      printf '\n%b[%s]%b\n' "$C_TITLE" "$section_name" "$C_RESET"
      previous=$section_name
    fi
    printf '  %b%-27s%b %s\n' "$C_KEY" "$key" "$C_RESET" "$value"
  done
  printf '\n%b%s%b\n' "$C_DIM" 'Read-only report; unavailable fields depend on installed tools and permissions.' "$C_RESET"
}

render_json() {
  local index
  # Encode records as NUL-delimited fields so quotes and newlines are safe.
  # Names and values never contain NUL (Bash strings cannot contain NUL).
  {
    for index in "${!KEYS[@]}"; do
      printf '%s\0%s\0%s\0' "${SECTIONS[index]}" "${KEYS[index]}" "${VALUES[index]}"
    done
  } | python3 -c '
import json,sys
parts=sys.stdin.buffer.read().split(b"\0")
if parts and not parts[-1]: parts.pop()
result={"name":"mega-fastfetch","version":"1.0.0","sections":{}}
for i in range(0,len(parts),3):
    section,key,value=(s.decode("utf-8","replace") for s in parts[i:i+3])
    result["sections"].setdefault(section,{})[key]=value
json.dump(result,sys.stdout,ensure_ascii=False,indent=2)
print()
'
}

main() {
  collect_system
  collect_platform
  collect_cpu
  collect_gpu
  collect_memory
  collect_storage
  collect_init
  collect_packages
  collect_network
  collect_power
  collect_extra
  collect_security
  if [[ "$OUTPUT" == json ]]; then render_json
  else render_text
  fi
}
main
