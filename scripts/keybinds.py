#!/usr/bin/env python3
"""Show all current Hyprland key bindings in a searchable fuzzel list.

Reads live bindings from `hyprctl binds -j`, so the list always matches the
loaded config. Binds defined with `bindd` show their description instead of
the raw command.
"""
import json
import subprocess

MODS = [(64, "SUPER"), (4, "CTRL"), (8, "ALT"), (1, "SHIFT")]

KEY_NAMES = {
    "Return": "Enter",
    "mouse:272": "Left drag",
    "mouse:273": "Right drag",
    "mouse_down": "Scroll down",
    "mouse_up": "Scroll up",
    "left": "Left",
    "right": "Right",
    "up": "Up",
    "down": "Down",
    "XF86AudioRaiseVolume": "Volume up",
    "XF86AudioLowerVolume": "Volume down",
    "XF86AudioMute": "Mute",
    "XF86AudioMicMute": "Mic mute",
    "XF86AudioNext": "Media next",
    "XF86AudioPrev": "Media previous",
    "XF86AudioPlay": "Media play",
    "XF86AudioPause": "Media pause",
}

DIRS = {"l": "left", "r": "right", "u": "up", "d": "down"}


def keys(b):
    mods = [name for bit, name in MODS if b["modmask"] & bit]
    return " + ".join(mods + [KEY_NAMES.get(b["key"], b["key"])])


def action(b):
    if b.get("has_description") and b["description"]:
        return b["description"]
    d, a = b["dispatcher"], b["arg"].strip()
    if d == "exec":
        if "keybinds.py" in a:
            return "Show key bindings (this list)"
        if "grim" in a:
            return "Screenshot (area)" if "slurp" in a else "Screenshot (full screen)"
        if "wpctl" in a or "playerctl" in a:
            return {"5%+": "Volume up", "5%-": "Volume down"}.get(a.split()[-1], a)
        return f"Run {a}" if len(a) <= 45 else f"Run {a[:42]}..."
    simple = {
        "killactive": "Close window",
        "fullscreen": "Fullscreen",
        "togglefloating": "Toggle floating",
        "pseudo": "Pseudo-tile",
        "togglesplit": "Toggle split direction",
        "exit": "Log out of Hyprland",
    }
    if d in simple:
        return simple[d]
    if d == "movefocus":
        return f"Focus {DIRS.get(a, a)}"
    if d == "movewindow":
        return f"Move window {DIRS.get(a, a)}"
    if d == "resizeactive":
        return f"Resize window ({a})"
    if d == "workspace":
        return {"e+1": "Next workspace", "e-1": "Previous workspace"}.get(a, f"Go to workspace {a}")
    if d == "movetoworkspace":
        return "Send window to scratchpad" if a.startswith("special") else f"Send window to workspace {a}"
    if d == "togglespecialworkspace":
        return "Show/hide scratchpad"
    if d == "mouse":
        return {"movewindow": "Move window", "resizewindow": "Resize window"}.get(a, a)
    return f"{d} {a}".strip()


def main():
    binds = json.loads(subprocess.run(["hyprctl", "binds", "-j"], capture_output=True, text=True).stdout)
    rows = [(keys(b), action(b)) for b in binds]
    width = max(len(k) for k, _ in rows) + 3
    text = "\n".join(f"{k:<{width}}{a}" for k, a in rows)
    subprocess.run(
        ["fuzzel", "--dmenu", "--prompt", "Keybinds: ", "--width", "70", "--lines", "25"],
        input=text, text=True,
    )


if __name__ == "__main__":
    main()
