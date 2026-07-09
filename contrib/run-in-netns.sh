#!/bin/bash
# run-in-netns.sh — Run Radmin VPN inside an isolated network namespace.
#
# Workaround for hosts where Radmin hangs on "waiting for adapter" / never reaches
# ready, caused by a conflict with the host's network stack (multiple VPNs / bridges /
# sysctls / netfilter). In a clean network namespace Radmin connects and works
# normally, same kernel and bundled Wine.
#
# Usage:   sudo bash run-in-netns.sh [/path/to/RadminVPN-Linux-*.AppImage]
# Close the Radmin window to exit; the namespace + NAT rules are torn down automatically.
set -u

NS=radminvpn
VETH_H=rvpn-h ; VETH_N=rvpn-n
SUBNET=10.201.0 ; HOST_IP=$SUBNET.1 ; NS_IP=$SUBNET.2
USER_NAME="${SUDO_USER:-$(id -un)}"
UID_N="$(id -u "$USER_NAME")"
APP="${1:-/home/$USER_NAME/Descargas/RadminVPN-Linux-v0.3.4.AppImage}"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -f "$APP" ] || { echo "AppImage not found: $APP"; exit 1; }

cleanup() {
    echo; echo "[*] tearing down netns..."
    ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null
    ip netns del "$NS" 2>/dev/null
    ip link del "$VETH_H" 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$SUBNET.0/24" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -s "$SUBNET.0/24" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d "$SUBNET.0/24" -j ACCEPT 2>/dev/null
    rm -rf "/etc/netns/$NS"
    echo "[+] done."
}
trap cleanup EXIT INT TERM

echo "[*] setting up isolated netns '$NS'..."
ip netns del "$NS" 2>/dev/null ; ip link del "$VETH_H" 2>/dev/null ; sleep 0.3
ip netns add "$NS"
ip link add "$VETH_H" type veth peer name "$VETH_N"
ip link set "$VETH_N" netns "$NS"
ip addr add "$HOST_IP/24" dev "$VETH_H" ; ip link set "$VETH_H" up
ip netns exec "$NS" ip addr add "$NS_IP/24" dev "$VETH_N"
ip netns exec "$NS" ip link set "$VETH_N" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip route add default via "$HOST_IP"
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s "$SUBNET.0/24" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$SUBNET.0/24" -j MASQUERADE
iptables -I FORWARD 1 -s "$SUBNET.0/24" -j ACCEPT   # win over ufw's default-deny FORWARD
iptables -I FORWARD 1 -d "$SUBNET.0/24" -j ACCEPT
mkdir -p "/etc/netns/$NS" ; echo "nameserver 1.1.1.1" > "/etc/netns/$NS/resolv.conf"

ip netns exec "$NS" ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 \
  && echo "[+] netns has internet" || echo "[!] warning: no internet inside netns"

echo "[*] launching Radmin VPN (close its window to exit)..."
ip netns exec "$NS" runuser -u "$USER_NAME" -- \
  env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
      XDG_RUNTIME_DIR="/run/user/$UID_N" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
  "$APP"
# on exit, the EXIT trap cleans up
