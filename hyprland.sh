#!/usr/bin/env bash
# hyprland.sh: one-shot Hyprland desktop setup for Ubuntu 26.04 (+ NVIDIA)
#
# Installs Hyprland, the NVIDIA driver if missing, and the desktop tools, then
# clones the config repos from GitHub into ~/.config/<repo>:
#   hypr waybar fuzzel mako kitty   (github.com/$GITHUB_USER/<repo>)
# Log in by picking "Hyprland" on the GDM login screen (gear icon).
#
# Usage:  bash hyprland.sh [options]
#   or:   wget -qO- https://raw.githubusercontent.com/tuncozanaydin/hypr/HEAD/hyprland.sh | bash -s -- [options]
#
#   --scale N           Monitor scale for this machine (repo default: 1.25)
#   --default-session   Make Hyprland the default login session for this user
#   --ssh               Clone over SSH (git@github.com:...) so you can push changes
#   --user NAME         GitHub user owning the repos (default: tuncozanaydin)
#   --skip-packages     Only fetch configs (no apt / driver / sudo)
#   -h, --help          Show this help
#
# Safe to re-run: config repos already in place are updated with `git pull`;
# any other existing config folders are backed up first.
# Requires passwordless sudo (unless --skip-packages). Run as your normal user.

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-tuncozanaydin}"
REPOS=(hypr waybar fuzzel mako kitty)
SCALE=""
USE_SSH=0
SKIP_PACKAGES=0
DEFAULT_SESSION=0
REBOOT_NEEDED=0
MIN_NVIDIA_VERSION=560   # explicit sync; anything older is rough on Wayland

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    local self="${BASH_SOURCE[0]:-}"
    if [[ -f $self ]]; then
        sed -n '2,/^$/p' "$self" | sed 's/^# \{0,1\}//'
    else
        echo "Usage: bash hyprland.sh [--scale N] [--default-session] [--ssh] [--user NAME] [--skip-packages]"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scale)           SCALE="${2:?--scale needs a value}"; shift 2 ;;
        --default-session) DEFAULT_SESSION=1; shift ;;
        --ssh)             USE_SSH=1; shift ;;
        --user)            GITHUB_USER="${2:?--user needs a value}"; shift 2 ;;
        --skip-packages)   SKIP_PACKAGES=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "Unknown option: $1 (see --help)" ;;
    esac
done

[[ $EUID -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
[[ -z $SCALE || $SCALE =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--scale must be a number, e.g. 1.25"

# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || warn "This script targets Ubuntu; detected ${PRETTY_NAME:-unknown}."
[[ ${VERSION_ID:-} == 26.04 ]] || warn "Tested on Ubuntu 26.04; detected ${VERSION_ID:-unknown}."

###########################################################################
# 1. Packages and NVIDIA driver
###########################################################################

PACKAGES=(
    # Compositor + portals
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
    # Desktop components
    kitty waybar fuzzel mako-notifier hyprpaper hyprlock hypridle hyprpolkitagent
    network-manager-gnome pavucontrol nautilus
    # Hyprland's runtime dialogs (hyprland-dialog etc.); Ubuntu ships these as
    # hyprland-qtutils. Without it Hyprland warns "hyprland-guiutils missing".
    hyprland-qtutils
    # Bluetooth (tray applet + manager; audio via PipeWire's bluez plugin)
    bluez blueman libspa-0.2-bluetooth
    # Screenshots, clipboard, media/brightness keys
    wl-clipboard grim slurp brightnessctl playerctl
    # Audio, X11 apps, Qt Wayland, keyring
    pipewire pipewire-pulse wireplumber xwayland qt6-wayland
    gnome-keyring libpam-gnome-keyring
    # Fonts
    fonts-font-awesome fonts-jetbrains-mono
    # Used by this script / keybind viewer
    git python3 pciutils
)

has_nvidia_gpu() {
    # PCI vendor 10de = NVIDIA; class 0300 = VGA, 0302 = 3D controller
    lspci -d 10de::0300 2>/dev/null | grep -q . || lspci -d 10de::0302 2>/dev/null | grep -q .
}

installed_nvidia_driver() {
    dpkg-query -W -f='${Status} ${Package}\n' 'nvidia-driver-*' 2>/dev/null \
        | awk '/install ok installed/ {print $NF}' | sort -V | tail -1
}

setup_nvidia() {
    log "NVIDIA GPU detected: $(lspci -d 10de: | grep -Ei 'vga|3d' | head -1 | sed 's/.*: //')"

    local drv
    drv=$(installed_nvidia_driver)
    if [[ -z $drv ]]; then
        log "No NVIDIA driver installed; installing Ubuntu's recommended driver"
        sudo apt-get install -y ubuntu-drivers-common
        ubuntu-drivers devices 2>/dev/null | grep -E 'recommended' || true
        sudo ubuntu-drivers install
        REBOOT_NEEDED=1
        drv=$(installed_nvidia_driver)
    fi
    [[ -n $drv ]] || die "NVIDIA driver installation failed."
    log "NVIDIA driver package: $drv"

    local ver
    ver=$(grep -oE '[0-9]+' <<<"$drv" | head -1)
    if (( ver < MIN_NVIDIA_VERSION )); then
        warn "Driver $ver is older than $MIN_NVIDIA_VERSION; Hyprland may flicker or glitch."
        warn "Upgrade with: sudo ubuntu-drivers install"
    fi

    # Hyprland needs kernel modesetting (Ubuntu's driver packages normally set it)
    if ! grep -rqsE '^\s*options\s+nvidia[-_]drm\s+.*modeset=1' /etc/modprobe.d /usr/lib/modprobe.d; then
        log "Enabling nvidia_drm modeset=1"
        echo 'options nvidia_drm modeset=1' | sudo tee /etc/modprobe.d/nvidia-drm-modeset.conf >/dev/null
        sudo update-initramfs -u
        REBOOT_NEEDED=1
    fi
}

install_packages() {
    sudo -n true 2>/dev/null || die "Passwordless sudo is required (or use --skip-packages)."
    export DEBIAN_FRONTEND=noninteractive

    log "Updating package lists"
    sudo apt-get update

    if has_nvidia_gpu; then
        setup_nvidia
    else
        log "No NVIDIA GPU found; skipping driver setup"
    fi

    log "Installing Hyprland and desktop components"
    sudo apt-get install -y "${PACKAGES[@]}"
    sudo systemctl enable --now bluetooth

    if [[ ! -e /etc/X11/default-display-manager ]]; then
        log "No display manager found; installing GDM"
        sudo apt-get install -y gdm3
        sudo systemctl enable gdm3
    fi
}

###########################################################################
# 2. Config repos -> ~/.config/<repo>
###########################################################################

BACKUP_DIR="$HOME/.config/hyprland-setup-backup-$(date +%Y%m%d-%H%M%S)"

repo_url() {
    if [[ $USE_SSH -eq 1 ]]; then
        echo "git@github.com:$GITHUB_USER/$1.git"
    else
        echo "https://github.com/$GITHUB_USER/$1.git"
    fi
}

# Prints the owner/name part of a GitHub URL, so https and ssh remotes compare equal
repo_slug() {
    sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$1"
}

fetch_repo() {
    local name="$1" dest="$HOME/.config/$1" url tmp
    url=$(repo_url "$name")

    if [[ -d $dest/.git ]] &&
        [[ $(repo_slug "$(git -C "$dest" config --get remote.origin.url 2>/dev/null)") == "$(repo_slug "$url")" ]]; then
        log "Updating $name"
        if ! git -C "$dest" pull --ff-only --quiet; then
            warn "$name: git pull failed (local changes?); left as is"
        fi
        return 0
    fi

    log "Cloning $url"
    tmp=$(mktemp -d)
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$tmp/$name"; then
        rm -rf "$tmp"
        warn "$name: could not clone $url (repo missing or private?)"
        return 1
    fi
    if [[ -e $dest ]]; then
        mkdir -p "$BACKUP_DIR"
        mv "$dest" "$BACKUP_DIR/$name"
    fi
    mkdir -p "$HOME/.config"
    mv "$tmp/$name" "$dest"
    rm -rf "$tmp"
}

fetch_configs() {
    command -v git >/dev/null || die "git is not installed (drop --skip-packages or: sudo apt install git)"
    local failed=()
    for r in "${REPOS[@]}"; do
        fetch_repo "$r" || failed+=("$r")
    done
    [[ -d $BACKUP_DIR ]] && log "Previous configs backed up to $BACKUP_DIR"
    [[ ${#failed[@]} -eq 0 ]] || die "Failed to fetch: ${failed[*]}"

    if [[ -n $SCALE ]]; then
        mkdir -p "$HOME/.config/hypr/local.d"
        printf '# Written by hyprland.sh --scale\nmonitor = , preferred, auto, %s\n' "$SCALE" \
            >"$HOME/.config/hypr/local.d/monitor.conf"
        log "Monitor scale for this machine: $SCALE (~/.config/hypr/local.d/monitor.conf)"
    fi
}

###########################################################################
# 3. Keep Hyprland's user services out of GNOME
###########################################################################
# The Ubuntu packages enable these for every graphical session (GNOME too).
# Restrict them to Hyprland; inside Hyprland they start via exec-once.

restrict_services() {
    log "Restricting Hyprland user services to Hyprland sessions"
    local u d
    for u in waybar mako hypridle hyprpaper hyprpolkitagent; do
        d="$HOME/.config/systemd/user/$u.service.d"
        mkdir -p "$d"
        printf '[Unit]\n# Only run inside Hyprland, not GNOME\nConditionEnvironment=XDG_CURRENT_DESKTOP=Hyprland\n' \
            >"$d/only-hyprland.conf"
    done
    systemctl --user daemon-reload 2>/dev/null || true
}

set_default_session() {
    local f="/var/lib/AccountsService/users/$USER"
    log "Making Hyprland the default login session for $USER"
    sudo mkdir -p "$(dirname "$f")"
    if sudo test -f "$f" && sudo grep -q '^\[User\]' "$f"; then
        sudo sed -i -e '/^Session=/d' -e '/^XSession=/d' -e 's/^\[User\]$/[User]\nSession=hyprland/' "$f"
    else
        printf '[User]\nSession=hyprland\n' | sudo tee "$f" >/dev/null
    fi
}

###########################################################################
# 4. Verify
###########################################################################

verify() {
    log "Verifying"
    local ok=1

    if command -v Hyprland >/dev/null; then
        if Hyprland --verify-config 2>&1 | grep -q 'config ok'; then
            log "Hyprland config: ok"
        else
            warn "Hyprland config has errors:"; Hyprland --verify-config 2>&1 | tail -20 >&2; ok=0
        fi
    else
        warn "Hyprland not installed (expected with --skip-packages)"
    fi

    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HOME/.config/waybar/config.jsonc"; then
        log "Waybar config: ok"
    else
        warn "Waybar config is not valid JSON"; ok=0
    fi

    [[ -e /usr/share/wayland-sessions/hyprland.desktop ]] \
        || { [[ $SKIP_PACKAGES -eq 1 ]] || { warn "Hyprland login session entry missing"; ok=0; }; }

    return $(( ok ? 0 : 1 ))
}

###########################################################################

main() {
    [[ $SKIP_PACKAGES -eq 1 ]] || install_packages
    fetch_configs
    restrict_services
    [[ $DEFAULT_SESSION -eq 0 ]] || set_default_session
    verify || die "Verification failed; see warnings above."

    echo
    log "Done."
    if [[ $REBOOT_NEEDED -eq 1 ]]; then
        printf '\n\033[1;33m>>> Reboot required (NVIDIA driver/modesetting changed): sudo reboot\033[0m\n'
    fi
    cat <<'EOF'

Next steps:
  1. Log out (or reboot if asked above).
  2. On the login screen, click the gear icon and choose "Hyprland"
     (not "Hyprland (uwsm-managed)").
  3. Press Super + F1 (or click ? in the bar) for all key bindings.
EOF
}

main
