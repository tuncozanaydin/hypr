#!/usr/bin/env bash
# Window layouts, per workspace:
#   center   master layout, main window in the middle (the default)
#   left     master layout, main window left, others stacked right
# plus a global switch:
#   dwindle  Hyprland's default layout, for all workspaces at once (Hyprland
#            has only one layout type at a time; master orientation is the
#            part that can differ per workspace)
#
#   layout.sh toggle    Super+Tab: current workspace center <-> left
#                       (turns dwindle off first if it is on)
#   layout.sh dwindle   Super+Shift+Tab: dwindle on/off for all workspaces
#   layout.sh sync      re-apply the saved state to all open workspaces
#   layout.sh swap      Super+J: swap with the main window (dwindle: toggle split)
#   layout.sh status    JSON for waybar (current workspace)
#
# State lives in local.d/layout.conf (untracked, per machine) as Hyprland
# config: workspace rules for "left" workspaces, plus the dwindle switch.
set -euo pipefail

STATE="$HOME/.config/hypr/local.d/layout.conf"

active_ws() { hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
dwindle_on() { [[ -f $STATE ]] && grep -q '^    layout = dwindle$' "$STATE"; }
left_workspaces() { [[ -f $STATE ]] && sed -n 's/^workspace = \([0-9-]*\), layoutopt:orientation:left$/\1/p' "$STATE" || true; }
is_left() { left_workspaces | grep -qx "$1"; }

# write_state DWINDLE(0|1) LEFT_WS...
write_state() {
    local dwindle=$1; shift
    mkdir -p "$(dirname "$STATE")"
    if [[ $dwindle == 0 && $# == 0 ]]; then rm -f "$STATE"; return; fi
    {
        echo "# Written by scripts/layout.sh (Super+Tab / Super+Shift+Tab). Delete to reset."
        if [[ $dwindle == 1 ]]; then printf 'general {\n    layout = dwindle\n}\n'; fi
        local ws
        for ws in "$@"; do echo "workspace = $ws, layoutopt:orientation:left"; done
    } >"$STATE"
}

# Make every workspace that has windows match the saved state. Workspace rules
# only reach workspaces without an orientation of their own, and Hyprland keeps
# a workspace's orientation once it has been set, so visit each one (animations
# off) and set it explicitly, then return to where we were.
# Switches are separate hyprctl calls: inside one --batch Hyprland still sees
# the old current workspace, and "switch to the current workspace" means "go to
# the previous one", which landed on the wrong workspace.
sync() {
    dwindle_on && return 0
    local here anim ws o
    here=$(active_ws)
    anim=$(hyprctl getoption animations:enabled -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["int"])')
    hyprctl keyword animations:enabled 0 >/dev/null
    for ws in $(hyprctl workspaces -j | python3 -c 'import json,sys; print(" ".join(str(w["id"]) for w in json.load(sys.stdin) if w["id"] > 0 and w["windows"] > 0))'); do
        if is_left "$ws"; then o=left; else o=center; fi
        [[ $ws == "$here" ]] || hyprctl dispatch workspace "$ws" >/dev/null
        hyprctl dispatch layoutmsg "orientation$o" >/dev/null
    done
    [[ $(active_ws) == "$here" ]] || hyprctl dispatch workspace "$here" >/dev/null
    hyprctl keyword animations:enabled "$anim" >/dev/null
}

toggle() {
    local ws others=() w
    ws=$(active_ws)
    mapfile -t lefts < <(left_workspaces)

    if dwindle_on; then
        write_state 0 "${lefts[@]}"          # back to per-workspace layouts
        hyprctl reload >/dev/null
        sync
        return
    fi

    if is_left "$ws"; then
        for w in "${lefts[@]}"; do [[ $w == "$ws" ]] || others+=("$w"); done
        write_state 0 "${others[@]}"
        hyprctl reload >/dev/null
        hyprctl dispatch layoutmsg orientationcenter >/dev/null
    else
        write_state 0 "${lefts[@]}" "$ws"
        hyprctl reload >/dev/null
        hyprctl dispatch layoutmsg orientationleft >/dev/null
    fi
}

toggle_dwindle() {
    mapfile -t lefts < <(left_workspaces)
    if dwindle_on; then write_state 0 "${lefts[@]}"; else write_state 1 "${lefts[@]}"; fi
    hyprctl reload >/dev/null
    sync
}

case "${1:-status}" in
    toggle)  toggle ;;
    sync)    sync ;;
    dwindle) toggle_dwindle ;;
    swap)
        if dwindle_on; then
            hyprctl dispatch togglesplit >/dev/null
        else
            hyprctl dispatch layoutmsg swapwithmaster master >/dev/null
        fi ;;
    status)
        if dwindle_on; then
            text=' dwindle' tip='Dwindle on all workspaces'
        elif is_left "$(active_ws)"; then
            text=' left' tip='This workspace: main window left, others stacked right'
        else
            text=' center' tip='This workspace: main window in the middle'
        fi
        printf '{"text":"%s","tooltip":"%s\\nClick: center/left for this workspace (Super+Tab)\\nRight-click: dwindle on/off (Super+Shift+Tab)"}\n' "$text" "$tip" ;;
    *) echo "usage: layout.sh toggle|dwindle|sync|swap|status" >&2; exit 2 ;;
esac
