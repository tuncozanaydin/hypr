#!/usr/bin/env python3
"""Waybar custom/layout feed: print the current workspace's layout (as JSON
from `layout.sh status`) whenever it changes.

Listens to Hyprland's event socket for workspace switches and config reloads
(layout.sh reloads after every change), and re-checks every 2 s as a fallback.
"""
import os
import select
import socket
import subprocess
import sys

STATUS = [os.path.expanduser("~/.config/hypr/scripts/layout.sh"), "status"]
EVENTS = (b"workspace", b"focusedmon", b"configreloaded", b"activespecial")


def status():
    return subprocess.run(STATUS, capture_output=True, text=True).stdout.strip()


def main():
    sock_path = os.path.join(os.environ["XDG_RUNTIME_DIR"], "hypr",
                             os.environ["HYPRLAND_INSTANCE_SIGNATURE"], ".socket2.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(sock_path)

    last = None
    buf = b""
    check = True
    while True:
        if check:
            line = status()
            if line and line != last:
                print(line, flush=True)
                last = line
        ready, _, _ = select.select([sock], [], [], 2.0)
        if not ready:          # quiet for 2 s: re-check as a fallback
            check = True
            continue
        data = sock.recv(4096)
        if not data:           # Hyprland went away
            sys.exit(0)
        buf += data
        *events, buf = buf.split(b"\n")
        # only workspace switches / reloads can change the shown layout
        check = any(e.startswith(EVENTS) for e in events)


if __name__ == "__main__":
    main()
