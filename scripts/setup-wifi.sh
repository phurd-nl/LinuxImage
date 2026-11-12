#!/bin/bash
# Add the office Wi-Fi (Nextlink_Corp, WPA2-Personal) as a system-wide, auto-connecting
# NetworkManager connection. Runs in late-install while the imaging cable works.
# The key is read once per Start from the imaging host; it is never in git or the seed.
set -u
# HTTPS with the imaging host's public key pinned: secrets never go in clear (security review C2).
HOST="${IMAGING_KIOSK:-https://192.168.26.106:8092}"
PIN="sha256//2jFl+1+PP0iTZrp+8/ltxQhVt2Ed+9m9cyuQUGhi5IM="
SSID="${WIFI_SSID:-Nextlink_Corp}"
DEST="/etc/NetworkManager/system-connections/${SSID}.nmconnection"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

got=""
# The serial matters on Dells whose network boot used a passthrough MAC that Ubuntu never sees.
serial=$(tr -d '\n ' < /sys/class/dmi/id/product_serial 2>/dev/null)
for addr in /sys/class/net/*/address; do
  mac=$(tr 'A-F' 'a-f' < "$addr" | tr -d '\r\n')
  case "$mac" in ""|00:00:00:00:00:00) continue ;; esac
  if curl -fsS --pinnedpubkey "$PIN" -k --max-time 20 -o "$tmp" "${HOST}/api/imaging-file?mac=${mac}&serial=${serial}&name=wifi"; then got=1; break; fi
done
if [ -z "$got" ]; then
  echo "[wifi] key not available for this laptop; Wi-Fi left for the employee"
  exit 0
fi
psk=$(head -n 1 "$tmp" | tr -d '\r\n')
if [ "${#psk}" -lt 8 ]; then
  echo "[wifi] key looks wrong; not configured"
  exit 0
fi

install -d -m 755 /etc/NetworkManager/system-connections
umask 077
cat > "$DEST" <<EOF
[connection]
id=${SSID}
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
autoconnect=true
permissions=

[wifi]
mode=infrastructure
ssid=${SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${psk}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$DEST"
echo "[wifi] ${SSID} added for every user"
