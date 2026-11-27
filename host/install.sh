#!/usr/bin/env bash
# Install fukurou's host-level network setup on the Pi:
#   - nftables rules that keep the camera off the internet (it uses this Pi as
#     its gateway) while answering its connectivity-check pings
#   - no ICMP redirects (so the camera is never told to bypass the Pi)
#   - chrony serving time to the camera only
#
# Usage (on the Pi, from the repo checkout):  sudo host/install.sh
# Values come from the repo's .env:
#   FRIGATE_OWL_BOX_HOST   camera IP
#   FUKUROU_PI_IP          this Pi's LAN IP (the camera's gateway)
#   FUKUROU_PI_IFACE       this Pi's LAN interface (default eth0)
#   FUKUROU_LAN_CIDR       the LAN subnet, e.g. 192.0.2.0/24
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
env_file="$here/../.env"
[ -r "$env_file" ] || { echo "missing $env_file" >&2; exit 1; }

get() { grep -E "^$1=" "$env_file" | tail -1 | cut -d= -f2-; }
CAMERA_IP="$(get FRIGATE_OWL_BOX_HOST)"
PI_IP="$(get FUKUROU_PI_IP)"
PI_IFACE="$(get FUKUROU_PI_IFACE)"; PI_IFACE="${PI_IFACE:-eth0}"
LAN_CIDR="$(get FUKUROU_LAN_CIDR)"
for v in CAMERA_IP PI_IP LAN_CIDR; do
  [ -n "${!v}" ] || { echo "$v is not set (see .env.example)" >&2; exit 1; }
done

render() {
  sed -e "s|@CAMERA_IP@|$CAMERA_IP|g" -e "s|@PI_IP@|$PI_IP|g" \
      -e "s|@PI_IFACE@|$PI_IFACE|g" -e "s|@LAN_CIDR@|$LAN_CIDR|g" "$1"
}

apt_install() {
  dpkg -s "$@" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}
apt_install nftables chrony

install -d /etc/fukurou
render "$here/camera-egress.nft.in" > /etc/fukurou/camera-egress.nft
nft -c -f /etc/fukurou/camera-egress.nft   # syntax check before loading
install -m 644 "$here/fukurou-camera-firewall.service" /etc/systemd/system/
render "$here/90-fukurou.conf.in" > /etc/sysctl.d/90-fukurou.conf
render "$here/chrony-fukurou.conf.in" > /etc/chrony/conf.d/fukurou.conf

sysctl -q -p /etc/sysctl.d/90-fukurou.conf
systemctl daemon-reload
systemctl enable fukurou-camera-firewall.service
systemctl restart fukurou-camera-firewall.service chrony
# Forget any camera flows tracked before the rules were (re)loaded, so they
# get the new treatment immediately.
command -v conntrack >/dev/null && conntrack -D -s "$CAMERA_IP" >/dev/null 2>&1 || true

echo "fukurou host setup installed: camera $CAMERA_IP -> gateway $PI_IP ($PI_IFACE), LAN $LAN_CIDR"
