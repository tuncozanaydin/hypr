#!/usr/bin/env bash
# Switch between three window layouts:
#   center   master layout, main window in the middle (the default, see hyprland.conf)
#   left     master layout, main window on the left, others stacked on the right
#   dwindle  Hyprland's default: each new window splits the focused one
#
#   layout.sh next | prev   cycle (Super+Tab / Super+Shift+Tab, bar icon clicks)
#   layout.sh set NAME      switch to center|left|dwindle
#   layout.sh swap          Super+J: swap with the main window, or toggle the
#                           split direction in dwindle
#   layout.sh status        JSON for the waybar custom/layout module
#
# The choice is saved in local.d/layout.conf (untracked, per machine), so it
# survives config reloads and new logins.
set -euo pipefail

LAYOUTS=(center left dwindle)
STATE="$HOME/.config/hypr/local.d/layout.conf"
WAYBAR_SIGNAL=9   # matches "signal" of custom/layout in ~/.config/waybar/config.jsonc

current() {
    local layout orientation
    layout=$(hyprctl getoption general:layout -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["str"])')
    if [[ $layout == dwindle ]]; then echo dwindle; return; fi
    orientation=$(hyprctl getoption master:orientation -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["str"])')
    if [[ $orientation == center ]]; then echo center; else echo left; fi
}

apply() {
    local name=$1 layout orientation keep
    # keep = master:always_keep_position: a lone window stays in its slot. Wanted
    # for center (stays in the middle), not for left (should fill the screen).
    case $name in
        center)  layout=master  orientation=center keep=1 ;;
        left)    layout=master  orientation=left   keep=0 ;;
        dwindle) layout=dwindle orientation=center keep=1 ;;   # master options unused by dwindle
        *) echo "unknown layout: $name (center|left|dwindle)" >&2; exit 2 ;;
    esac

    hyprctl --batch "keyword general:layout $layout ; keyword master:orientation $orientation ; keyword master:always_keep_position $keep" >/dev/null

    # master:orientation only affects workspaces created from now on; ones that
    # already have windows keep their own orientation. Visit each of them (in
    # one batch, animations off) to apply it, then return to where we were.
    if [[ $layout == master ]]; then
        local here focus anim cmds="" ws
        here=$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
        focus=$(hyprctl activewindow -j | python3 -c 'import json,sys; print(json.load(sys.stdin).get("address", ""))' 2>/dev/null || true)
        anim=$(hyprctl getoption animations:enabled -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["int"])')
        for ws in $(hyprctl workspaces -j | python3 -c 'import json,sys; print(" ".join(str(w["id"]) for w in json.load(sys.stdin) if w["id"] > 0 and w["windows"] > 0))'); do
            cmds+="dispatch workspace $ws ; dispatch layoutmsg orientation$orientation ; "
        done
        cmds+="dispatch workspace $here ; "
        [[ -z $focus ]] || cmds+="dispatch focuswindow address:$focus ; "
        hyprctl --batch "keyword animations:enabled 0 ; ${cmds}keyword animations:enabled $anim" >/dev/null
    fi

    mkdir -p "$(dirname "$STATE")"
    if [[ $name == center ]]; then
        rm -f "$STATE"   # center is the hyprland.conf default
    else
        printf '# Written by scripts/layout.sh (Super+Tab); delete to go back to center.\ngeneral {\n    layout = %s\n}\nmaster {\n    orientation = %s\n    always_keep_position = %s\n}\n' \
            "$layout" "$orientation" "$keep" >"$STATE"
    fi

    pkill -RTMIN+"$WAYBAR_SIGNAL" -x waybar 2>/dev/null || true
}

step() {
    local cur i n=${#LAYOUTS[@]}
    cur=$(current)
    for (( i = 0; i < n; i++ )); do [[ ${LAYOUTS[i]} == "$cur" ]] && break; done
    apply "${LAYOUTS[(i + $1 + n) % n]}"
}

case "${1:-status}" in
    next) step 1 ;;
    prev) step -1 ;;
    set)  apply "${2:?usage: layout.sh set center|left|dwindle}" ;;
    swap)
        if [[ $(current) == dwindle ]]; then
            hyprctl dispatch togglesplit >/dev/null
        else
            hyprctl dispatch layoutmsg swapwithmaster master >/dev/null
        fi ;;
    status)
        case $(current) in
            center)  text=' center'  tip='Centered master: main window in the middle' ;;
            left)    text=' left'    tip='Master left: main window left, others stacked right' ;;
            dwindle) text=' dwindle' tip='Dwindle: each new window splits the focused one' ;;
        esac
        printf '{"text":"%s","tooltip":"%s\\nClick: next layout (Super+Tab)\\nRight-click: previous"}\n' "$text" "$tip" ;;
    *) echo "usage: layout.sh next|prev|set NAME|swap|status" >&2; exit 2 ;;
esac
