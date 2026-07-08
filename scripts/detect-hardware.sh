#!/bin/bash
# detect-hardware.sh — auto-detect the encryption target on THIS Ubuntu machine.
# Read-only. Emits JSON on stdout for the first-boot wizard.
# Run: bash scripts/detect-hardware.sh
set -euo pipefail

# Runs as root in production (wizard systemd service). Works unprivileged for
# read-only fields; free-space and blockers need root for accuracy.
exec python3 <<'PY'
import json, os, re, subprocess

root = os.geteuid() == 0

def run(*args):
    return subprocess.run(args, capture_output=True, text=True)

def sh(cmd):
    return run("bash", "-c", cmd)

blockers = []

# Boot disk from /
r = run("findmnt", "-no", "SOURCE", "/")
if r.returncode != 0 or not r.stdout.strip():
    print(json.dumps({"error": "Cannot find mount source for /"}))
    raise SystemExit(1)
root_src = r.stdout.strip()
r = run("lsblk", "-no", "PATH", root_src)
root_part = r.stdout.strip().splitlines()[0]
r = run("lsblk", "-no", "PKNAME", root_part)
if r.returncode != 0 or not r.stdout.strip():
    print(json.dumps({"error": "Cannot resolve parent disk for /"}))
    raise SystemExit(1)
disk = "/dev/" + r.stdout.strip()

# Login user (uid 1000 = standard Ubuntu OEM/first user)
username = ""
r = run("id", "-un", "1000")
if r.returncode == 0:
    username = r.stdout.strip()
else:
    print(json.dumps({"error": "No uid-1000 login user — create the user before running setup"}))
    raise SystemExit(1)

# Partitions on boot disk only
r = run("lsblk", "-J", "-o", "NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT,PKNAME", disk)
lsblk = json.loads(r.stdout)
children = lsblk["blockdevices"][0].get("children", [])
max_part = 0
luks_dev = ""
home_encrypted = False
mapper = "home_crypt"

for ch in children:
    name = ch["name"]
    m = re.search(r"(\d+)$", name)
    if m:
        max_part = max(max_part, int(m.group(1)))
    dev = f"/dev/{name}"
    if ch.get("fstype") == "crypto_LUKS":
        luks_dev = dev
        for sub in ch.get("children") or []:
            if sub.get("type") == "crypt" and sub.get("mountpoint") == "/home":
                home_encrypted = True

next_part = max_part + 1
if re.search(r"\d$", disk):
    proposed_luks = f"{disk}p{next_part}"
else:
    proposed_luks = f"{disk}{next_part}"
if luks_dev:
    proposed_luks = luks_dev
    m = re.search(r"(\d+)$", luks_dev)
    if m:
        next_part = int(m.group(1))

# Free space (sgdisk — requires root)
free_mb = 0
if root and run("command", "-v", "sgdisk").returncode == 0:
    r = sh(f"sgdisk -p {disk} 2>/dev/null | grep -i 'free space' | tail -1")
    if r.stdout.strip():
        nums = re.findall(r"[\d.]+", r.stdout)
        if nums:
            free_mb = int(float(nums[0]) * 1024)

# Safety: one internal non-removable disk >= 20G
r = run("lsblk", "-dn", "-o", "NAME,TYPE,RM,SIZE")
internal = 0
for line in r.stdout.splitlines():
    name, typ, rm, size = line.split(None, 3)
    if typ != "disk" or rm != "0":
        continue
    g = re.match(r"([\d.]+)G", size)
    if g and float(g.group(1)) >= 20:
        internal += 1

# TPM + Secure Boot
sb = run("mokutil", "--sb-state")
secure_boot = sb.returncode == 0 and "enabled" in (sb.stdout + sb.stderr).lower()
tpm = os.path.exists("/dev/tpmrm0") or os.path.exists("/dev/tpm0")

# Phase detection (resume-aware)
state_dir = "/var/lib/linux-encryption-setup"
completed_marker = os.path.join(state_dir, "completed_at")
purge_marker = os.path.join(state_dir, "purge_done")
jwe = "/etc/luks-keyfile.jwe"
pcr7 = False
jwe_present = os.path.isfile(jwe)
if jwe_present and os.access(jwe, os.R_OK):
    raw = open(jwe, "rb").read()
    pcr7 = b'"pcr_ids":"7"' in raw or b'"pcr_ids": "7"' in raw
elif jwe_present:
    pcr7 = None  # unknown without root

if os.path.isfile(completed_marker) or os.path.isfile(purge_marker):
    phase = "complete"
elif home_encrypted and pcr7:
    phase = "needs_purge"
elif home_encrypted and jwe_present:
    phase = "needs_harden"  # pcr7 False or unknown (non-root)
elif jwe_present:
    phase = "needs_reboot"
elif luks_dev and run("cryptsetup", "isLuks", luks_dev).returncode == 0:
    phase = "needs_encrypt_hooks"
elif os.path.exists(proposed_luks):
    sig = run("blkid", "-o", "value", "-s", "TYPE", proposed_luks).stdout.strip()
    phase = "needs_encrypt" if not sig else "needs_encrypt_hooks"
else:
    phase = "needs_partition"

# ready = safe to run the NEXT automated step
ready = True
fresh_phases = ("needs_partition", "needs_encrypt", "needs_encrypt_hooks")
if not tpm:
    blockers.append("No TPM 2.0 detected on this machine")
    ready = False
if not root and phase != "complete":
    blockers.append("Wizard service must run as root (sudo bash scripts/install-setup-wizard.sh)")
    ready = False
elif phase in fresh_phases:
    if not secure_boot:
        blockers.append("Enable Secure Boot in UEFI firmware, then return here")
        ready = False
    if phase == "needs_partition" and free_mb < 51200:
        blockers.append(f"Need ~50 GB unallocated free space at end of {disk} (found ~{free_mb} MB)")
        ready = False
warnings = []
if internal > 1:
    warnings.append(f"Multiple internal disks — only {disk} (boot disk) will be modified")
# Post-encrypt phases ignore Secure Boot / free-space blockers for resume
if phase not in fresh_phases and root:
    blockers = [b for b in blockers if "Secure Boot" not in b and "free space" not in b and "run as root" not in b]
    ready = tpm

lsblk_txt = run("lsblk", "-o", "NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT", disk).stdout

print(json.dumps({
    "hostname": run("hostname").stdout.strip(),
    "disk": disk,
    "partnum": next_part,
    "luks_dev": proposed_luks,
    "username": username,
    "mapper": mapper,
    "free_mb": free_mb,
    "secure_boot": secure_boot,
    "tpm": tpm,
    "home_encrypted": home_encrypted,
    "pcr7": pcr7,
    "phase": phase,
    "ready": ready,
    "blockers": blockers,
    "warnings": warnings,
    "lsblk": lsblk_txt,
}, indent=2))
PY