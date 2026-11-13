#!/bin/bash
# diag-entra.sh: why the sign-in screen has no Microsoft Entra ID choice.
# Run on the laptop as nextadmin:
#   curl -sk https://192.168.26.106:8092/files/diag-entra.sh | sudo bash   (or the :8090 extras URL)
# Sends a zip to the imaging host (pinned HTTPS). Tenant/client ids and secrets are masked.
set -u
HOST="https://192.168.26.106:8092"
PIN="sha256//2jFl+1+PP0iTZrp+8/ltxQhVt2Ed+9m9cyuQUGhi5IM="
d=$(mktemp -d)
mask() { sed -E 's/^([[:space:]]*(issuer|client_id|client_secret|tenant[a-z_]*)[[:space:]]*=).*/\1 <masked>/I'; }
{
  echo "== snaps"; snap list authd-msentraid core24 2>&1
  echo "== snap services"; snap services authd-msentraid 2>&1
  echo "== authd"; systemctl status authd.service authd.socket --no-pager 2>&1 | head -30
  echo "== nextlink-entra-authd"; systemctl status nextlink-entra-authd --no-pager 2>&1 | head -20
  echo "== brokers dir"; ls -la /etc/authd/brokers.d/ 2>&1; for f in /etc/authd/brokers.d/*; do echo "-- $f"; mask < "$f"; done
  echo "== broker.conf"; mask < /var/snap/authd-msentraid/current/broker.conf 2>&1
  echo "== broker.conf.d"; for f in /var/snap/authd-msentraid/current/broker.conf.d/*; do echo "-- $f"; mask < "$f"; done
  echo "== common-auth"; cat /etc/pam.d/common-auth
  echo "== gdm-password"; cat /etc/pam.d/gdm-password 2>&1
  echo "== pam-configs"; ls /usr/share/pam-configs/
  echo "== gdm"; dpkg -l gdm3 authd 2>&1 | tail -2; cat /etc/gdm3/custom.conf
  echo "== faillock nextadmin"; faillock --user nextadmin 2>&1
} > "$d/state.txt" 2>&1
journalctl -b --no-pager -u authd -u snap.authd-msentraid.authd-msentraid -u nextlink-entra-authd -u gdm 2>&1 | mask | tail -400 > "$d/journal.txt"
cp /var/lib/linux-encryption-setup/*.log "$d/" 2>/dev/null
(cd "$d" && python3 -c 'import zipfile,os,sys; z=zipfile.ZipFile("diag.zip","w"); [z.write(f) for f in os.listdir(".") if f!="diag.zip"]')
serial=$(cat /sys/class/dmi/id/product_serial)
curl -sf --pinnedpubkey "$PIN" -k --max-time 60 -H 'Content-Type: application/zip' --data-binary @"$d/diag.zip" "$HOST/api/logs?serial=$serial" && echo " sent" || echo "upload failed; the file is $d/diag.zip"
