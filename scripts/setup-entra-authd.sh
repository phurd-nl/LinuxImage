#!/bin/bash
# setup-entra-authd.sh — Microsoft Entra ID login for the Ubuntu 26.04 image.
#
# Ubuntu 26.04 ships authd in the archive. The Entra broker is the
# authd-msentraid snap. The login screen starts at the username field, not
# the local account list. The person types user@domain and signs in with
# their Entra password plus MFA (entra_auth). The device-code QR flow stays
# available. This is not silent single sign-on, and it does not replace the
# wizard password that opens the LUKS volume.
#
# allowed_users is ALL and owner is empty: any account the Entra app accepts can sign in,
# like Windows. Restrict who that is with "Assignment required" on the Entra app.
# Sudo is the Entra group linux-sudo (sudoers drop-in), not this setting. Offline
# login uses the local password authd asks for when the person did not
# type the Entra password.
#
# Before this can succeed, register an Entra app (Ubuntu's authd guide):
#   delegated Microsoft Graph permissions, including GroupMember.Read.All
#   with admin consent, and public client flows enabled.
# Pass the tenant id and the application (client) id. No client secret.
# Broker 0.5.4 refuses entra_auth unless the device is registered or a
# client secret is set. This script enables register_device. The Entra app
# also needs the mobile/desktop redirect URI
# https://login.microsoftonline.com/common/oauth2/nativeclient.
#
# This script does not register the device. register_device runs inside a
# successful broker login. The person must be in the new-hire security
# group at that moment. Entra device settings allow only that group to
# join a device. Imaging adds them when the laptop is assigned. The
# membership ends 24 hours later, which stops another join and does not
# unjoin the device or sign them out. Do not name that group linux-*,
# or authd will map it onto a local group.
#
#   ENTRA_TENANT_ID=... ENTRA_CLIENT_ID=... bash scripts/setup-entra-authd.sh --dry-run
#   sudo IMAGE_HARDEN_CONFIRM=1 ENTRA_TENANT_ID=... ENTRA_CLIENT_ID=... \
#     bash scripts/setup-entra-authd.sh --apply
#
# Do not run --apply on the dev machine.
set -euo pipefail

mode=""
case "${1:-}" in
  --dry-run) mode=dry-run ;;
  --apply) mode=apply ;;
  *)
    echo "Use: $0 --dry-run | --apply" >&2
    exit 2
    ;;
esac

uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
tenant="${ENTRA_TENANT_ID:-}"
client="${ENTRA_CLIENT_ID:-}"
if [ -z "$tenant" ] || [ -z "$client" ]; then
  echo "ENTRA_TENANT_ID and ENTRA_CLIENT_ID are required." >&2
  exit 2
fi
if ! [[ "$tenant" =~ $uuid_re && "$client" =~ $uuid_re ]]; then
  echo "ENTRA_TENANT_ID and ENTRA_CLIENT_ID must be UUIDs." >&2
  exit 2
fi

if [ "$mode" = dry-run ]; then
  echo "would: authd package"
  echo "would: authd-msentraid snap"
  echo "would: entra password login"
  echo "would: allow every Entra user"
  echo "would: do not lock the first login as owner"
  echo "would: device registers on the imaging login"
  echo "would: offline local password"
  echo "would: disk unlock stays the wizard password"
  echo "would: login screen asks for the Entra name"
  echo "would: hide the imaging account"
  exit 0
fi

if [ "${IMAGE_HARDEN_CONFIRM:-}" != 1 ] && [ "${WIZARD_AUTO:-}" != 1 ]; then
  echo "Refusing to change this machine. Re-run with IMAGE_HARDEN_CONFIRM=1 on the template or target only." >&2
  exit 1
fi
if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo IMAGE_HARDEN_CONFIRM=1 bash $0 --apply" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y authd
# Right after the first boot snapd is still initializing the device and cannot reach the
# store ("unable to contact snap store", D3SFJR3 11 Nov). Wait for the seed, then retry.
snap wait system seed.loaded 2>/dev/null || true
# The imaging host keeps a copy (base snap + broker, each with its .assert) for when the store
# cannot be reached from the office network (11 Nov). snap ack checks Canonical's signatures,
# so the offline install is verified the same way as one from the store.
install_from_imaging_host() {
  local host="${IMAGING_FILES:-http://192.168.26.106:8090}/snaps" dir name
  dir=$(mktemp -d)
  curl -fsS --max-time 20 -o "$dir/files.txt" "$host/files.txt" || { rm -rf "$dir"; return 1; }
  while read -r name; do
    [ -n "$name" ] || continue
    curl -fsS --max-time 300 -o "$dir/$name.assert" "$host/$name.assert" &&
      curl -fsS --max-time 300 -o "$dir/$name.snap" "$host/$name.snap" &&
      snap ack "$dir/$name.assert" &&
      { snap list "${name%_*}" >/dev/null 2>&1 || snap install "$dir/$name.snap"; } || { rm -rf "$dir"; return 1; }
  done < "$dir/files.txt"
  rm -rf "$dir"
  snap list authd-msentraid >/dev/null 2>&1
}
for try in $(seq 1 20); do
  snap list authd-msentraid >/dev/null 2>&1 && break
  snap install authd-msentraid && break
  if [ "$try" -ge 3 ] && install_from_imaging_host; then
    echo "authd-msentraid installed from the imaging host's copy (the store was not reachable)"
    break
  fi
  echo "authd-msentraid not installed yet (try $try of 20); retrying in 30 seconds"
  sleep 30
done
snap list authd-msentraid >/dev/null 2>&1 || { echo "ABORT: authd-msentraid could not be installed" >&2; exit 1; }

conf=/var/snap/authd-msentraid/current/broker.conf
if [ ! -f "$conf" ]; then
  echo "ABORT: $conf missing after installing authd-msentraid." >&2
  exit 1
fi
sed -i \
  -e "s|<CLIENT_ID>|${client}|g" \
  -e "s|<ISSUER_ID>|${tenant}|g" \
  "$conf"
if grep -q '^entra_auth[[:space:]]*=' "$conf"; then
  sed -i 's/^entra_auth[[:space:]]*=.*/entra_auth = true/' "$conf"
else
  printf '\n[flows]\nentra_auth = true\n' >> "$conf"
fi
# Password login reads group membership through the registered device.
# A client secret is the other option; this image does not use one.
if grep -q '^register_device[[:space:]]*=' "$conf"; then
  sed -i 's/^register_device[[:space:]]*=.*/register_device = true/' "$conf"
else
  printf '\n[msentraid]\nregister_device = true\n' >> "$conf"
fi

# Who may sign in: any account the Entra app accepts, like Windows (decision 12 Nov 2026,
# after security review H1). Limit who that is with "Assignment required" on the Entra app.
# Home folders are private to each person; admin is only linux-sudo and NextAdmin.
NL_ALLOWED="ALL"
NL_OWNER='""'
export NL_ALLOWED NL_OWNER
python3 - "$conf" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()

def set_key(lines, section, key, value):
    header = f"[{section}]"
    out = []
    in_section = False
    found = False
    seen = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_section and not found:
                out.append(f"{key} = {value}")
                found = True
            in_section = stripped == header
            seen = seen or in_section
        elif in_section and stripped.split("=", 1)[0].strip() == key:
            out.append(f"{key} = {value}")
            found = True
            continue
        out.append(line)
    if in_section and not found:
        out.append(f"{key} = {value}")
    elif not seen:
        if out and out[-1] != "":
            out.append("")
        out.append(header)
        out.append(f"{key} = {value}")
    return out

import os
lines = set_key(lines, "users", "allowed_users", os.environ["NL_ALLOWED"])
lines = set_key(lines, "users", "owner", os.environ["NL_OWNER"])
path.write_text("\n".join(lines) + "\n")
PY

dropin="$(dirname "$conf")/broker.conf.d"
install -d "$dropin"
rm -f "$dropin/20-owner-autoregistration.conf"
cat > "$dropin/99-fleet-access.conf" <<EOF
[users]
allowed_users = $NL_ALLOWED
owner = $NL_OWNER
EOF
# The broker refuses to start if a drop-in is readable by anyone else.
chmod 600 "$dropin/99-fleet-access.conf"

# IT admin on any laptop: members of the Entra group linux-sudo (review C1). authd also maps
# linux-* Entra groups onto local groups; this drop-in covers the group by its own name.
printf '%%linux-sudo ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/linux-sudo
chmod 440 /etc/sudoers.d/linux-sudo
visudo -cf /etc/sudoers.d/linux-sudo >/dev/null || rm -f /etc/sudoers.d/linux-sudo

install -d /etc/authd/brokers.d
cp /snap/authd-msentraid/current/conf/authd/msentraid.conf /etc/authd/brokers.d/msentraid.conf
systemctl restart authd || true
if systemctl list-unit-files snap.authd-msentraid.authd-msentraid.service --no-legend 2>/dev/null | grep -q .; then
  systemctl restart snap.authd-msentraid.authd-msentraid.service
else
  snap restart authd-msentraid
fi

install -d /etc/dconf/profile /etc/dconf/db/gdm.d
if [ ! -f /etc/dconf/profile/gdm ]; then
  printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' > /etc/dconf/profile/gdm
fi
python3 - << 'PY'
from pathlib import Path
path = Path("/etc/dconf/db/gdm.d/01-entra-login")
existing = path.read_text().splitlines() if path.is_file() else []
kept = [line for line in existing if line.startswith("banner-message-")]
lines = ["[org/gnome/login-screen]", "disable-user-list=true", *kept]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(lines) + "\n")
PY
dconf update || true

imaging_user="${IMAGING_LOCAL_USER:-nextadmin}"
install -d "/var/lib/AccountsService/users"
cat > "/var/lib/AccountsService/users/${imaging_user}" <<EOF
[User]
SystemAccount=true
EOF

# The login screen may have come up before Entra was installed (the store retry can take
# minutes); it then offers only a local password and no welcome line. Restart it so it
# shows the Entra choice, but never under a person who is already signed in.
if [ -z "$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 !~ /^gdm/ {print}')" ]; then
  systemctl restart gdm || true
fi

echo "Entra login is configured. The login screen asks for user@domain."
echo "Any account the Entra app accepts can sign in (limit it with Assignment required in Entra)."
echo "The device registers when the imaging login succeeds, not in this script."
echo "The login screen is Entra. The first password sign-in replaces the install disk key."
