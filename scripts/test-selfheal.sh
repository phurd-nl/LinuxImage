#!/bin/bash
# test-selfheal.sh — validate the self-heal credential-capture path WITHOUT waiting
# for a real PCR drift. It proves, end to end:
#   (a) GDM/sudo route authentication through common-auth (where the hook is wired),
#   (b) pam_exec 'expose_authtok' really delivers the password on STDIN,
#   (c) the captured bytes (no trailing newline) match a LUKS keyslot — i.e. your
#       LOGIN PASSWORD == keyslot 0, which is what self-heal needs to luksAddKey.
#
# SAFETY: does NOT touch /etc/luks-keyfile.jwe, does NOT reseal, does NOT add or
# remove any LUKS keyslot. It installs a TEMPORARY capture-only auth hook, you
# authenticate ONCE, then 'check' validates the capture and removes everything
# (hook, PAM line, and the shredded password).
#
#   sudo bash test-selfheal.sh arm     # wire a temporary capture hook
#   sudo -k ; sudo -v                  # ONE auth (same common-auth path as GDM)
#   sudo bash test-selfheal.sh check   # validate + clean up
#
# (For a true GDM test instead of 'sudo -v', log OUT and back in between arm/check.)
set -euo pipefail

source "$(dirname "$0")/config.sh"
TESTHOOK=/usr/local/sbin/home-crypt-stash-TEST
CAP=/dev/shm/.hc-selfheal-test
PAMA=/etc/pam.d/common-auth
say(){ echo "[$(date +%T)] $*"; }
[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bash $0 {arm|check}"; exit 1; }

case "${1:-}" in
arm)
  # Capture-only test hook. The capture line is byte-identical to the real
  # home-crypt-stash, minus the drift gate (so it always captures for the test).
  cat > "$TESTHOOK" <<EOF
#!/bin/bash
tok=\$(cat)
[ -n "\$tok" ] || exit 0
( umask 077; printf '%s' "\$tok" > "$CAP" )
exit 0
EOF
  chmod 700 "$TESTHOOK"; chown root:root "$TESTHOOK"
  rm -f "$CAP"
  grep -qF "$TESTHOOK" "$PAMA" || \
    echo "auth optional pam_exec.so expose_authtok quiet $TESTHOOK" >> "$PAMA"
  say "ARMED — temporary capture hook wired into $PAMA."
  say "Now perform ONE authentication:"
  say "    sudo -k ; sudo -v        # fastest; same common-auth path GDM uses"
  say "    …or log OUT and back in via GDM for the literal GDM test."
  say "Then run:  sudo bash $0 check"
  ;;
check)
  ok=1
  if [ -s "$CAP" ]; then
    say "PASS (a): password delivered on STDIN and captured ($(stat -c%s "$CAP") bytes)."
  else
    say "FAIL (a): no capture — expose_authtok/stdin did not deliver, or no auth happened."
    say "          Did you run 'sudo -k ; sudo -v' (or re-login) after 'arm'?"
    ok=0
  fi
  if [ -s "$CAP" ]; then
    if cryptsetup open --test-passphrase --key-file "$CAP" "$LUKS_DEV" 2>/dev/null; then
      say "PASS (b): captured password matches a LUKS keyslot — self-heal WILL work."
    else
      ok=0
      say "FAIL (b): captured password does NOT open the volume."
      say "          => login password != keyslot 0 (password-sync never synced it)."
      say "          Self-heal would fall back to manual: sudo clevis-reheal"
      say "          To make keyslot 0 track your login password, set it now:"
      say "            sudo cryptsetup luksChangeKey $LUKS_DEV --key-slot 0"
      say "            (authorise with your recovery phrase; enter login pw as the new one)"
    fi
  fi
  # ---- always disarm + shred, even on failure ----
  shred -u "$CAP" 2>/dev/null || rm -f "$CAP"
  sed -i "\#$TESTHOOK#d" "$PAMA"
  rm -f "$TESTHOOK"
  say "Cleaned up: temp hook + PAM line removed, captured password shredded."
  if [ "$ok" = 1 ]; then
    say "RESULT: ✅ self-heal capture path verified end-to-end."
  else
    say "RESULT: ❌ see FAIL lines above."
    exit 1
  fi
  ;;
*)
  echo "usage: sudo bash $0 {arm|check}"; exit 1;;
esac
