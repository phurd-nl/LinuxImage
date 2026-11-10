#!/bin/bash
# test-seed-password.sh — the built seed has a passwd hash, not the plaintext.
# Does not boot a laptop and does not build the tarball.
#
# Run: bash imaging/test-seed-password.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
yaml="$here/ubuntu-26.04-desktop-autoinstall.yaml"
fail=0
ok() { printf '  OK   %s\n' "$*"; }
no() { printf '  FAIL %s\n' "$*"; fail=1; }

if grep -q 'update: false' "$yaml" && ! grep -q '^  channel:' "$yaml"; then
  ok "installer snap refresh is off"
else
  no "installer snap refresh is off"
fi

if grep -q 'http://192.168.26.106:8090/nocloud/extras' "$yaml" && grep -q '/cdrom/nocloud/extras' "$yaml"; then
  ok "late-commands use the host and fall back to USB"
else
  no "late-commands use the host and fall back to USB"
fi

# The installer root is the NFS share. A network: section makes Subiquity
# run netplan apply, which stops NetworkManager and deadlocks that root
# at Drivers/_list_drivers/wait_apt. Ethernet DHCP is written to the
# installed system by a late-command instead.
if python3 - "$yaml" <<'PY'
import pathlib, re, subprocess, sys, tempfile
raw = pathlib.Path(sys.argv[1]).read_text()
body = [ln for ln in raw.splitlines() if not ln.lstrip().startswith("#")]
if any(re.match(r"  network:\s*$", ln) for ln in body):
    sys.exit("autoinstall network section would stop NetworkManager on the NFS root")
line = next((ln for ln in raw.splitlines() if "90-nextlink-ethernet.yaml" in ln), "")
match = re.search(r'\["bash", "-c", "(.*)"\]\s*$', line)
if match is None:
    sys.exit("missing netplan late-command")
cmd = match.group(1).encode("utf-8").decode("unicode_escape")
with tempfile.TemporaryDirectory() as tmp:
    target = pathlib.Path(tmp) / "target"
    (target / "etc" / "netplan").mkdir(parents=True)
    (target / "etc" / "netplan" / "00-installer-config.yaml").write_text("old\n")
    subprocess.run(["bash", "-c", cmd.replace("/target", str(target))], check=True)
    written = (target / "etc" / "netplan" / "90-nextlink-ethernet.yaml").read_text()
    if (target / "etc" / "netplan" / "00-installer-config.yaml").exists():
        sys.exit("installer netplan was left in place")
need = [
    "renderer: NetworkManager",
    'name: "en*"',
    'name: "eth*"',
    "dhcp4: true",
    "optional: true",
]
missing = [item for item in need if item not in written]
if missing:
    sys.exit("netplan missing " + ", ".join(missing))
PY
then
  ok "live install does not apply netplan; target ethernet stays on DHCP"
else
  no "live install does not apply netplan; target ethernet stays on DHCP"
fi

plain="known-plain-test-value"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
if SEED_OUT="$out" TEMP_PASSWORD="$plain" bash "$here/build-imaging-seed.sh" --user-data-only >/dev/null; then
  ok "user-data-only build"
else
  no "user-data-only build"
  exit 1
fi

data="$(cat "$out/user-data")"
pwfile="$out/TECH-PASSWORD.txt"
mode="$(stat -c %a "$pwfile" 2>/dev/null || echo missing)"

printf '%s\n' "$data" | grep -q '\$6\$' && ok "password field is a sha512-crypt hash" || no "password field is a sha512-crypt hash"
printf '%s\n' "$data" | grep -q "$plain" && no "plaintext stayed out of user-data" || ok "plaintext stayed out of user-data"
[ "$(cat "$pwfile")" = "$plain" ] && ok "plaintext is only in TECH-PASSWORD.txt" || no "plaintext is only in TECH-PASSWORD.txt"
[ "$mode" = "600" ] && ok "TECH-PASSWORD.txt is mode 600" || no "TECH-PASSWORD.txt is mode 600 (got $mode)"

exit "$fail"
