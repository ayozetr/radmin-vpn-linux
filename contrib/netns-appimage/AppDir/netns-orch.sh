#!/bin/bash
# netns-orch.sh — runs as ROOT (via pkexec/sudo from AppRun).
# Sets up an isolated network namespace with NAT'd internet, launches the ORIGINAL
# Radmin VPN AppImage (as the invoking user) inside it, and tears everything down on exit.
set -u

RUSER="${RUSER:-${SUDO_USER:-}}"
[ -n "$RUSER" ] || { echo "netns-orch: no target user"; exit 1; }
RUID="$(id -u "$RUSER")"
RHOME="$(getent passwd "$RUSER" | cut -d: -f6)"
CACHE="${CACHE:-$RHOME/.cache/radmin-vpn-netns}"

NS=radminvpn ; VH=rvpn-h ; VN=rvpn-n
SUB=10.201.0 ; HIP=$SUB.1 ; NIP=$SUB.2

# Where the caching askpass stores the sudo credential for this session (tmpfs, 0600).
PWFILE="/run/user/$RUID/.radmin-sudo"
# Flag file that keeps the "preparing" progress dialog alive; removing it closes it.
PROGFLAG="/run/user/$RUID/.radmin-preparing"

cleanup() {
    rm -f "$PROGFLAG" 2>/dev/null
    pkill -u "$RUSER" -f "zenity --progress" 2>/dev/null
    echo; echo "[*] tearing down netns…"
    ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null
    ip netns del "$NS" 2>/dev/null
    ip link del "$VH" 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$SUB.0/24" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -s "$SUB.0/24" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d "$SUB.0/24" -j ACCEPT 2>/dev/null
    rm -f "$PWFILE"                 # drop the cached sudo password
    rm -rf "/etc/netns/$NS"
    echo "[+] done."
}
trap cleanup EXIT INT TERM

# Kill any leftover launcher instance FIRST. Two orchestrators sharing one netns would
# race — the newcomer's startup kill tears down the old one's Radmin, and the old one's
# EXIT-trap then tears down the newcomer's namespace → Radmin starts but instantly
# vanishes. This happens if a previous session wasn't closed, or on a double double-click.
for p in $(pgrep -f "netns-orch.sh" 2>/dev/null); do
    [ "$p" = "$$" ] || kill -TERM "$p" 2>/dev/null   # let its cleanup() run
done
sleep 2

rm -f "$PWFILE"                     # start clean (no stale credential)

# Radmin is single-instance (shared /tmp FIFOs). Clear any stray/leftover instance —
# an orphaned run.sh from a crashed session keeps a sudo-askpass shim that can pop extra
# password dialogs, so kill the whole family, not just the service.
pkill -9 -f "RvControlSvc|RvRvpnGui|rvpn_launcher|tap_bridge" 2>/dev/null
ip netns pids "$NS" 2>/dev/null | xargs -r kill -9 2>/dev/null   # anything left in an old netns
sleep 1

echo "[*] setting up isolated netns '$NS'…"
ip netns del "$NS" 2>/dev/null ; ip link del "$VH" 2>/dev/null ; sleep 0.3
ip netns add "$NS"
ip link add "$VH" type veth peer name "$VN"
ip link set "$VN" netns "$NS"
ip addr add "$HIP/24" dev "$VH" ; ip link set "$VH" up
ip netns exec "$NS" ip addr add "$NIP/24" dev "$VN"
ip netns exec "$NS" ip link set "$VN" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip route add default via "$HIP"
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s "$SUB.0/24" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$SUB.0/24" -j MASQUERADE
iptables -I FORWARD 1 -s "$SUB.0/24" -j ACCEPT   # beat ufw's default-deny FORWARD
iptables -I FORWARD 1 -d "$SUB.0/24" -j ACCEPT
mkdir -p "/etc/netns/$NS" ; echo "nameserver 1.1.1.1" > "/etc/netns/$NS/resolv.conf"

ip netns exec "$NS" ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 \
  && echo "[+] netns has internet" || echo "[!] warning: no internet inside netns"

# Radmin remembers "IsHidden=true" when it was last closed to the tray, and then starts
# minimized (window unpainted → looks black if force-shown). Reset it to false before
# launch so it opens visible on its own. Safe here: we just killed every wineserver, so
# nothing will overwrite user.reg before the app's own wineserver reads it.
REG="$RHOME/.local/share/radmin-vpn-linux/wineprefix/user.reg"
[ -f "$REG" ] && runuser -u "$RUSER" -- sed -i 's/"IsHidden"="true"/"IsHidden"="false"/' "$REG" 2>/dev/null

# GUI/X environment reused for the progress dialog + window-raise (no netns needed for
# X clients — they reach the display over the filesystem X socket).
GUIENV="DISPLAY=${DISPLAY:-:0} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0} XAUTHORITY=${XAUTHORITY:-$RHOME/.Xauthority} XDG_RUNTIME_DIR=/run/user/$RUID DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$RUID/bus}"

echo "[*] launching Radmin VPN (close its window to exit)…"
# Run the ORIGINAL AppImage as-is (self-mounts as the user) so rendering matches a
# direct launch. RADMIN_IN_TERM=1 makes its AppRun run run.sh directly (no konsole
# re-exec), which keeps Radmin inside THIS netns. XAUTHORITY lets the askpass dialog
# reach X. SUDO_ASKPASS points at our caching askpass so run.sh's several `sudo …`
# calls only prompt ONCE. Backgrounded; the wait-loop below is the "still running" gate.
ip netns exec "$NS" runuser -u "$RUSER" -- \
  env HOME="$RHOME" DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
      XAUTHORITY="${XAUTHORITY:-$RHOME/.Xauthority}" \
      XDG_RUNTIME_DIR="/run/user/$RUID" \
      DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$RUID/bus}" \
      RADMIN_IN_TERM=1 \
      SUDO_ASKPASS="$CACHE/radmin-askpass.sh" RADMIN_PWFILE="$PWFILE" \
  "$CACHE/RadminVPN.AppImage" >/tmp/radmin-netns-run.log 2>&1 &

# Progress dialog: appears once the sudo password is in (so it doesn't clash with the
# password prompt) and pulses through the ~30s Wine boot so the user knows it's working.
# The feeder (`while [ -e PROGFLAG ]`) keeps zenity's stdin open so it keeps pulsing and
# shows NO button; removing PROGFLAG (or killing zenity) closes it automatically.
: > "$PROGFLAG"; chown "$RUSER":"$RUSER" "$PROGFLAG" 2>/dev/null
( for _ in $(seq 1 120); do [ -s "$PWFILE" ] && break; sleep 1; done
  [ -e "$PROGFLAG" ] || exit 0
  runuser -u "$RUSER" -- env $GUIENV sh -c '
    ( while [ -e "'"$PROGFLAG"'" ]; do sleep 0.4; done ) |
      zenity --progress --pulsate --no-cancel --auto-close --title="Radmin VPN" \
             --text="Starting Radmin VPN, please wait…  "
  ' >/dev/null 2>&1 ) &

# Wait for the service to come up…
echo "[*] waiting for Radmin to come up…"
for _ in $(seq 1 90); do
    pgrep -f "RvControlSvc.exe" >/dev/null 2>&1 && break
    sleep 2
done

if pgrep -f "RvControlSvc.exe" >/dev/null 2>&1; then
    # …then keep "preparing" up until the real GUI window is actually on screen
    # (Radmin/Wine can take a good while to render it). We look for a viewable
    # RvRvpnGui window taller than 300px = the main window, not the tiny helpers.
    for _ in $(seq 1 60); do
        runuser -u "$RUSER" -- env $GUIENV bash -c '
          for w in $(xdotool search --onlyvisible --class RvRvpnGui 2>/dev/null); do
            g=$(xdotool getwindowgeometry "$w" 2>/dev/null | grep -oE "[0-9]+x[0-9]+")
            [ "${g#*x}" -gt 300 ] 2>/dev/null && exit 0
          done
          exit 1' && break
        sleep 1
    done
    sleep 1
    rm -f "$PROGFLAG" 2>/dev/null
    pkill -u "$RUSER" -f "zenity --progress" 2>/dev/null   # close "preparing"
    # Gentle focus/raise (window is already painted by Radmin — no windowmap, which
    # would show an unpainted black frame). Best-effort on Wayland.
    runuser -u "$RUSER" -- env $GUIENV sh -c \
      'for i in 1 2 3 4; do xdotool search --onlyvisible --class "RvRvpnGui" windowactivate 2>/dev/null && exit 0; sleep 1; done' \
      >/dev/null 2>&1 &
    echo "[+] Radmin is up — close its window to exit and tear down the netns."
    while pgrep -f "RvControlSvc.exe" >/dev/null 2>&1; do sleep 3; done
else
    rm -f "$PROGFLAG" 2>/dev/null
    pkill -u "$RUSER" -f "zenity --progress" 2>/dev/null
    echo "[!] Radmin did not come up within the timeout."
fi
# EXIT trap tears the netns down
