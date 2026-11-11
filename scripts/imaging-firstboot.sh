#!/bin/bash
# First boot after the Ubuntu image, while the imaging cable is still connected.
# 1. Files the installer's TPM disk-encryption recovery key with the imaging host,
#    which stores it and mails a NextPass link.
# 2. Posts the imaging report; the host writes it on the laptop's NextDesk ticket.
# Runs until both are sent, then never again.
set -u
HOST="${IMAGING_KIOSK:-http://192.168.26.106:8091}"
STATE=/var/lib/linux-encryption-setup
DONE="$STATE/report-sent"
install -d -m 700 "$STATE"
[ -f "$DONE" ] && exit 0

macs=$(for a in /sys/class/net/*/address; do
  n=$(basename "$(dirname "$a")"); [ "$n" = lo ] && continue
  tr 'A-F' 'a-f' < "$a"; done | grep -v '^00:00:00:00:00:00$' | sort -u)
dmi() { tr -d '\n' < "/sys/class/dmi/id/$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

problems=()
checks=()

# Recovery key for snapd's TPM full-disk encryption. The installer's key is never shown
# on a classic install, so make a new one through snapd's API and put it in the
# default-recovery keyslot (replace it, or add it if the installer made none).
# Each run makes a fresh key, so a failed filing is fixed by the next run.
FILED="$STATE/recovery-key-filed"
key=""
[ -f "$FILED" ] || key=$(python3 - <<'PY' 2>>/var/log/imaging-firstboot-recovery.log
import http.client, json, socket, sys, time

class Snapd(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect("/run/snapd.socket")

def call(method, path, body=None):
    c = Snapd("localhost", timeout=60)
    c.request(method, path, json.dumps(body) if body else None, {"Content-Type": "application/json"})
    r = json.loads(c.getresponse().read())
    return r.get("status-code"), r.get("result"), r.get("change")

code, res, _ = call("POST", "/v2/system-volumes", {"action": "generate-recovery-key"})
if code != 200:
    sys.exit(f"generate-recovery-key: {code} {res}")
for body in ({"action": "replace-recovery-key", "key-id": res["key-id"]},
             {"action": "add-recovery-key", "key-id": res["key-id"], "keyslots": [{"name": "default-recovery"}]},
             {"action": "add-recovery-key", "key-id": res["key-id"],
              "keyslots": [{"container-role": "system-data", "name": "default-recovery"}]}):
    code, err, change = call("POST", "/v2/system-volumes", body)
    print(body["action"], code, err, file=sys.stderr)
    if code != 202:
        continue
    for _ in range(120):
        _, chg, _ = call("GET", f"/v2/changes/{change}")
        if chg.get("ready"):
            break
        time.sleep(1)
    print("change", chg.get("status"), chg.get("err"), file=sys.stderr)
    if chg.get("status") == "Done":
        print(res["recovery-key"])
        sys.exit(0)
sys.exit("no recovery keyslot could be set")
PY
)
escrowed=no
[ -f "$FILED" ] && escrowed=yes
if [ "$escrowed" = yes ]; then
  :
elif [ -z "$key" ]; then
  problems+=("The disk recovery key could not be set (see /var/log/imaging-firstboot-recovery.log). Make one with snap-tpmctl or Security Center before handing the laptop out.")
else
  for mac in $macs; do
    body=$(python3 -c 'import json,sys; print(json.dumps({"mac": sys.argv[1], "passphrase": sys.argv[2], "serial": sys.argv[3]}))' "$mac" "$key" "$(dmi product_serial)")
    if curl -sf --max-time 20 -H 'Content-Type: application/json' -d "$body" "$HOST/api/recovery" | grep -q '"ok":true'; then
      escrowed=yes; touch "$FILED"; break
    fi
  done
  [ "$escrowed" = yes ] || problems+=("The disk recovery key was not filed with the imaging host. Record it before handing the laptop out.")
fi

root_src=$(findmnt -no SOURCE /)
if lsblk -s -no TYPE "$root_src" 2>/dev/null | grep -q crypt; then
  encryption="full disk, TPM unlock"
else
  encryption="NOT encrypted"
  problems+=("The disk is not encrypted. Re-image with Secure Boot on and the TPM enabled.")
fi
secure_boot=false
mokutil --sb-state 2>/dev/null | grep -qi enabled && secure_boot=true
[ "$secure_boot" = true ] || problems+=("Secure Boot is off.")
tpm=false; [ -e /dev/tpmrm0 ] && tpm=true
[ "$tpm" = true ] || problems+=("No TPM found.")
entra=false; snap list authd-msentraid >/dev/null 2>&1 && entra=true
[ "$entra" = true ] || problems+=("Entra sign-in (authd) is not installed. The employee cannot sign in with a work account.")
if lspci 2>/dev/null | grep -qi nvidia; then
  if lsmod | grep -q '^nvidia '; then checks+=("NVIDIA driver loaded.")
  else problems+=("NVIDIA GPU found but its driver is not loaded. Run: sudo ubuntu-drivers install"); fi
fi
nmcli -t -f NAME connection show 2>/dev/null | grep -qx "Nextlink_Corp" || problems+=("Office Wi-Fi (Nextlink_Corp) is not configured.")
# Agents, shown on the ticket like Windows. Services can still be starting on first boot.
atera=false; wazuh=false; unifi=false
for _ in $(seq 1 12); do
  systemctl is-active --quiet AteraAgent.service && atera=true
  systemctl is-active --quiet wazuh-agent.service && wazuh=true
  [ "$atera" = true ] && [ "$wazuh" = true ] && break
  sleep 5
done
dpkg-query -W -f='${Status}' unifi-endpoint 2>/dev/null | grep -q "install ok installed" && unifi=true
if [ "$atera" != true ]; then
  # Say why on the ticket: the service state and its last log lines.
  why=$( { systemctl is-enabled AteraAgent.service 2>&1; systemctl is-active AteraAgent.service 2>&1;
           journalctl -u AteraAgent.service -b -n 4 --no-pager -o cat 2>&1; } | tr '\n' ' ' | cut -c1-400)
  problems+=("Atera agent is not running: ${why}")
fi
[ "$wazuh" = true ] || problems+=("Wazuh agent is not running.")
[ "$unifi" = true ] || problems+=("UniFi Endpoint is not installed.")

PROBLEMS=$(IFS=$'\x1f'; printf '%s' "${problems[*]:-}")
CHECKS=$(IFS=$'\x1f'; printf '%s' "${checks[*]:-}")
report=$(STATE="$STATE" PROBLEMS="$PROBLEMS" CHECKS="$CHECKS" python3 - "$secure_boot" "$tpm" "$entra" "$encryption" "$macs" "$atera" "$wazuh" "$unifi" <<'PY'
import json, os, sys, pathlib, time
sb, tpm, entra, enc, macs, atera, wazuh, unifi = sys.argv[1:9]
def dmi(name):
    try: return pathlib.Path(f"/sys/class/dmi/id/{name}").read_text().strip()
    except OSError: return ""
apps = {}
try: apps = json.loads(pathlib.Path(os.environ["STATE"], "apps-result.json").read_text())
except (OSError, ValueError): pass
problems = [p for p in os.environ.get("PROBLEMS", "").split("\x1f") if p]
checks = [c for c in os.environ.get("CHECKS", "").split("\x1f") if c]
if not apps: problems.append("The app installer did not record a result.")
problems += [f"App failed to install: {a}" for a in apps.get("failed", [])]
print(json.dumps({
    "os": "ubuntu-26.04", "macs": macs.split(), "serial": dmi("product_serial"),
    "manufacturer": dmi("sys_vendor"), "model": dmi("product_version") if dmi("sys_vendor") == "LENOVO" else dmi("product_name"),
    "hostname": os.uname().nodename, "entra_joined": entra == "true", "secure_boot": sb == "true",
    "tpm_ready": tpm == "true", "encryption": enc, "apps_ok": apps.get("ok", []), "apps_failed": apps.get("failed", []),
    "agents": {"atera": atera == "true", "wazuh": wazuh == "true", "unifi": unifi == "true"},
    "problems": problems, "checks": checks, "finished": time.strftime("%Y-%m-%d %H:%M"),
}))
PY
)
printf '%s\n' "$report" > "$STATE/imaging-report.json"
# Installer logs next to the report on the imaging host (storage and encryption decisions live there).
serial=$(tr -d '\n' < /sys/class/dmi/id/product_serial 2>/dev/null | sed 's/[^A-Za-z0-9_-]//g')
python3 - "$HOST" "$serial" <<'PY' || logger -t imaging-firstboot "installer logs not sent"
import shutil, sys, urllib.request as u
host, serial = sys.argv[1], sys.argv[2] or "unknown"
shutil.make_archive("/tmp/nl-installer-logs", "zip", "/var/log", "installer")
data = open("/tmp/nl-installer-logs.zip", "rb").read()
u.urlopen(u.Request(f"{host}/api/logs?serial={serial}", data=data, headers={"Content-Type": "application/zip"}), timeout=60).read()
PY
if curl -sf --max-time 30 -H 'Content-Type: application/json' -d "$report" "$HOST/api/report" >/dev/null; then
  date -Is > "$DONE"
  logger -t imaging-firstboot "report sent; recovery key escrowed=$escrowed"
else
  logger -t imaging-firstboot "report not sent; will retry next boot"
  exit 1
fi
