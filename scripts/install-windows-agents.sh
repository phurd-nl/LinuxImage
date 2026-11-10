#!/bin/bash
# Linux counterparts of the agents every Windows image installs.
# Atera and UniFi Endpoint come from the imaging host. Wazuh installs only
# when the registration password was provided to this run. It is not stored here.
set -u
HOST="${IMAGING_KIOSK:-http://192.168.26.106:8091}"
MANAGER="${WAZUH_MANAGER:-132.147.132.130}"
export DEBIAN_FRONTEND=noninteractive

laptop_serial() {
  serial=""
  if [ -r /sys/class/dmi/id/product_serial ]; then
    serial="$(tr -d '\000\r\n' < /sys/class/dmi/id/product_serial)"
  fi
  case "$(printf '%s' "$serial" | tr '[:upper:]' '[:lower:]')" in
    ""|none|"default string"|"to be filled by o.e.m."|"system serial number"|"not specified"|0)
      serial=""
      ;;
  esac
  if [ -z "$serial" ] && [ -r /proc/cmdline ]; then
    for token in $(cat /proc/cmdline); do
      case "$token" in
        kiosk.serial=*) serial="${token#kiosk.serial=}" ;;
      esac
    done
  fi
  printf '%s' "$serial"
}

fetch_for_mac() {
  name="$1"
  dest="$2"
  for addr in /sys/class/net/*/address; do
    [ -f "$addr" ] || continue
    iface="$(basename "$(dirname "$addr")")"
    [ "$iface" = "lo" ] && continue
    mac="$(tr 'A-F' 'a-f' < "$addr" | tr -d '\r\n')"
    [ -n "$mac" ] || continue
    [ "$mac" = "00:00:00:00:00:00" ] && continue
    if curl -fsSL -o "$dest" "${HOST}/api/imaging-file?mac=${mac}&name=${name}"; then
      return 0
    fi
  done
  serial="$(laptop_serial)"
  if [ -n "$serial" ] && curl -fsSL -G -o "$dest" "${HOST}/api/imaging-file" \
      --data-urlencode "serial=${serial}" --data-urlencode "name=${name}"; then
    return 0
  fi
  return 1
}

if fetch_for_mac atera /tmp/atera-install.url; then
  ATERA_URL="$(head -n 1 /tmp/atera-install.url | tr -d '\r')"
  rm -f /tmp/atera-install.url
  if [ -n "$ATERA_URL" ]; then
    echo "[agents] installing Atera"
    # Atera's script ends with systemctl daemon-reload/enable/start, which fail in the
    # installer chroot (no running systemd). Its files and settings are in place by then,
    # so enable the unit with a plain symlink; it starts on the first real boot.
    curl -fsSL "$ATERA_URL" | bash || true
    unit=/etc/systemd/system/AteraAgent.service
    if [ -f /etc/atera-agent/.settings.json ] && [ -f "$unit" ]; then
      want=$(sed -n 's/^WantedBy=//p' "$unit" | head -n 1)
      want=${want:-multi-user.target}
      mkdir -p "/etc/systemd/system/${want}.wants"
      ln -sf ../AteraAgent.service "/etc/systemd/system/${want}.wants/AteraAgent.service"
      echo "[agents] Atera installed; it starts on first boot"
    else
      echo "[agents] WARN Atera install failed"
    fi
  fi
else
  echo "[agents] Atera installer not available for this laptop"
fi

if fetch_for_mac unifi /tmp/unifi-endpoint.deb; then
  echo "[agents] installing UniFi Endpoint"
  apt-get update -qq || true
  apt-get install -y /tmp/unifi-endpoint.deb || echo "[agents] WARN UniFi Endpoint install failed"
  rm -f /tmp/unifi-endpoint.deb
else
  echo "[agents] UniFi Endpoint package not available for this laptop"
fi
if [ -z "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
  if fetch_for_mac wazuh /tmp/wazuh-auth.pass; then
    WAZUH_REGISTRATION_PASSWORD="$(tr -d '\r\n' < /tmp/wazuh-auth.pass)"
    rm -f /tmp/wazuh-auth.pass
  fi
fi
if [ -z "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
  echo "[agents] Wazuh agent not installed. The registration password is not on the imaging host."
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update -qq
WAZUH_MANAGER="$MANAGER" WAZUH_REGISTRATION_PASSWORD="$WAZUH_REGISTRATION_PASSWORD" \
  apt-get install -y wazuh-agent
systemctl enable --now wazuh-agent || true
echo "[agents] Wazuh agent installed for $MANAGER"
