#!/bin/bash
# Create encrypted /home before the login screen. Nobody types a password.
# The first Entra sign-in replaces the install password. /home opens with the TPM.
set -u
STATE=/var/lib/linux-encryption-setup
ROOT=/opt/linux-encryption-setup
SCRIPTS=$ROOT/scripts
[ "$(id -u)" -eq 0 ] || exit 0
[ -f "$STATE/completed_at" ] && exit 0
[ -x "$SCRIPTS/orchestrate-firstboot.sh" ] || exit 0

logger -t unattended-encrypt "starting"
# PXE cannot turn Secure Boot on. Encrypt /home anyway and seal to this TPM.
install -d -m 700 "$STATE"
touch "$STATE/secureboot-override"
chmod 600 "$STATE/secureboot-override"
python3 "$SCRIPTS/pull-install-password.py" || true
if [ ! -s "$STATE/recovery-passphrase" ] && [ -f "$SCRIPTS/recovery_passphrase.py" ]; then
  python3 "$SCRIPTS/recovery_passphrase.py" --pull || true
fi

phase=$(bash "$SCRIPTS/detect-hardware.sh" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("phase",""))')
case "$phase" in
  complete|needs_reboot|needs_harden|needs_purge)
    logger -t unattended-encrypt "encryption already prepared ($phase)"
    exit 0
    ;;
esac

secret_line() {
  python3 - "$1" "$2" << 'PY'
import pathlib, sys
src, dest = sys.argv[1:]
line = ""
for item in pathlib.Path(src).read_text(errors="replace").splitlines():
    item = item.strip()
    if item and not item.startswith("#"):
        line = item
        break
if not line:
    raise SystemExit(1)
path = pathlib.Path(dest)
path.write_text(line + "\n")
path.chmod(0o600)
PY
}

if [ ! -s "$STATE/install-password" ] || [ ! -s "$STATE/recovery-passphrase" ]; then
  logger -t unattended-encrypt "missing install password or recovery phrase; login will not encrypt /home"
  exit 0
fi

work=$(mktemp -d /dev/shm/luks.XXXXXX)
chmod 700 "$work"
cleanup() {
  shred -u "$work/login" "$work/recovery" 2>/dev/null || rm -f "$work/login" "$work/recovery"
  rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT
secret_line "$STATE/install-password" "$work/login" || exit 0
secret_line "$STATE/recovery-passphrase" "$work/recovery" || exit 0

WIZARD_LOGIN_PW_FILE=$work/login WIZARD_RECOVERY_PW_FILE=$work/recovery \
  bash "$SCRIPTS/orchestrate-firstboot.sh" || { logger -t unattended-encrypt "orchestrator failed"; exit 1; }
if [ -f "$STATE/install.key" ]; then
  shred -u "$STATE/install-password" 2>/dev/null || rm -f "$STATE/install-password"
fi
if [ -f /etc/luks-keyfile.jwe ] && [ -x "$SCRIPTS/08-harden-tpm-pcr7-selfheal.sh" ]; then
  detect=$(bash "$SCRIPTS/detect-hardware.sh")
  DISK=$(printf '%s' "$detect" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("disk",""))')
  PARTNUM=$(printf '%s' "$detect" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("partnum",""))')
  USERNAME=$(printf '%s' "$detect" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("username",""))')
  MAPPER=$(printf '%s' "$detect" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mapper","home_crypt"))')
  export DISK PARTNUM USERNAME MAPPER
  WIZARD_AUTO=1 bash "$SCRIPTS/08-harden-tpm-pcr7-selfheal.sh" || logger -t unattended-encrypt "PCR 7 reseal failed"
fi

# After the employee signs in and /home is the encrypted volume, finish purge.
cat > /usr/local/sbin/home-crypt-finish << 'EOF'
#!/bin/bash
src=$(findmnt -n -o SOURCE --target /home 2>/dev/null || true)
[ "$src" = "/dev/mapper/home_crypt" ] || exit 0
[ -f /var/lib/linux-encryption-setup/completed_at ] && exit 0
systemd-run --unit=linux-encryption-finish --collect \
  /opt/linux-encryption-setup/scripts/finish-after-login.sh >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 /usr/local/sbin/home-crypt-finish
grep -q home-crypt-finish /etc/pam.d/common-session || \
  echo "session optional pam_exec.so quiet /usr/local/sbin/home-crypt-finish" >> /etc/pam.d/common-session
logger -t unattended-encrypt "encrypted home is ready for Entra sign-in"
exit 0
