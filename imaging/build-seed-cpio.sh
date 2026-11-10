#!/bin/bash
# Rebuild the Ubuntu autoinstall seed on the opsi host from this repo. Run as root.
# Keeps the install password hash already in /opt/linuximage/nocloud/user-data.
# initrd.auto is rebuilt as initrd.auto.base (the first initrd.auto) plus this seed.cpio.
# The kernel unpacks them in order, so this seed replaces the one baked into the base.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
nc=/opt/linuximage/nocloud
hash=$(grep -oP '^\s*password:\s*"\K\$6\$[^"]+' "$nc/user-data" | head -1)
[ -n "$hash" ] || { echo "no password hash in $nc/user-data"; exit 1; }
work=$(mktemp -d)
mkdir -p "$work/seed" "$work/scripts/casper-bottom"
python3 - "$repo/imaging/ubuntu-26.04-desktop-autoinstall.yaml" "$work/seed/user-data" "$hash" <<'PY'
import pathlib, sys
src, dest, hashed = sys.argv[1:]
text = pathlib.Path(src).read_text()
if "__TEMP_PASSWORD__" not in text:
    raise SystemExit("yaml lost its __TEMP_PASSWORD__ placeholder")
out = text.replace("__TEMP_PASSWORD__", hashed)
if not out.startswith("#cloud-config"):
    out = "#cloud-config\n" + out
pathlib.Path(dest).write_text(out)
PY
cp "$nc/meta-data" "$work/seed/meta-data"
cp "$work/seed/user-data" "$work/seed/autoinstall.yaml"
install -m 755 "$repo/imaging/seed-hook/99nextlinkseed" "$work/scripts/casper-bottom/99nextlinkseed"
# casper's run order, taken from the current seed so it matches the ISO's initrd.
(cd "$work" && cpio -i --quiet scripts/casper-bottom/ORDER < "$nc/seed.cpio")
grep -q 99nextlinkseed "$work/scripts/casper-bottom/ORDER"
cp -a "$nc/seed.cpio" "$nc/seed.cpio.bak-$(date +%Y%m%d%H%M)"
cp -a "$nc/user-data" "$nc/user-data.bak-$(date +%Y%m%d%H%M)"
(cd "$work" && find . -mindepth 1 -printf '%P\n' | sort | cpio -o -H newc --quiet) > "$nc/seed.cpio"
install -m 644 "$work/seed/user-data" "$nc/user-data"
casper=/opt/linuximage/casper
[ -f "$casper/initrd.auto.base" ] || cp -a "$casper/initrd.auto" "$casper/initrd.auto.base"
cp -a "$casper/initrd.auto" "$casper/initrd.auto.bak-$(date +%Y%m%d%H%M)"
# The kernel only reads an archive appended after a compressed one if it starts on a
# 4-byte boundary (init/initramfs.c); otherwise it stops with "invalid magic" and the
# old seed inside the base wins. Zero padding in between is skipped.
base_size=$(stat -c %s "$casper/initrd.auto.base")
pad=$(( (4 - base_size % 4) % 4 ))
{ cat "$casper/initrd.auto.base"; head -c "$pad" /dev/zero; cat "$nc/seed.cpio"; } > "$casper/initrd.auto.new"
mv "$casper/initrd.auto.new" "$casper/initrd.auto"
for f in imaging/late-install-linux-encryption.sh imaging/check-tpm-encryption.py scripts/imaging-firstboot.sh scripts/ubuntu_apps.py; do
    install -m 755 "$repo/$f" "$nc/extras/$(basename "$f")"
done
rm -rf "$work"
echo "seed rebuilt: $nc/seed.cpio"
