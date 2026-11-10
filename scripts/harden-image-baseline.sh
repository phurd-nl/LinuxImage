#!/bin/bash
# harden-image-baseline.sh — OS lockdown for the Ubuntu 26.04 laptop image.
#
# Does not partition, format, or touch LUKS/TPM. Encryption stays in the
# first-boot wizard (01 → 02 → reboot → 08 → 04).
#
# Apply only on a template VM or inside the installed target:
#   sudo IMAGE_HARDEN_CONFIRM=1 bash scripts/harden-image-baseline.sh --apply
# Preview (safe on a dev machine):
#   bash scripts/harden-image-baseline.sh --dry-run
#
# Idempotent. Re-running rewrites the same drop-in files.
# Reversible: delete the linux-image drop-ins listed below, unmask ssh,
# avahi, and rpcbind, and remove the wsdd divert. UFW rules added here are
# the default policy only. Timeshift config is removed with
# /etc/timeshift/timeshift.json and linux-image-timeshift.timer.
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

if [ "$mode" = apply ]; then
  if [ "${IMAGE_HARDEN_CONFIRM:-}" != 1 ]; then
    echo "Refusing to change this machine. Re-run with IMAGE_HARDEN_CONFIRM=1 on the template or target only." >&2
    exit 1
  fi
  if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo IMAGE_HARDEN_CONFIRM=1 bash $0 --apply" >&2
    exit 1
  fi
fi

here="$(cd "$(dirname "$0")" && pwd)"

say() { echo "would: $*"; }

write_file() {
  local desc="$1" path="$2"
  if [ "$mode" = dry-run ]; then
    say "$desc"
    return 0
  fi
  echo "apply: $desc"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

run_cmd() {
  local desc="$1"
  shift
  if [ "$mode" = dry-run ]; then
    say "$desc"
    return 0
  fi
  echo "apply: $desc"
  "$@"
}

# --- firewall: deny unsolicited inbound, allow outbound -------------------
run_cmd "ufw default deny incoming" true
if [ "$mode" = apply ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y ufw unattended-upgrades libpam-pwquality apparmor
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable || true
fi

# --- listeners that are not needed on a laptop image ----------------------
# Kept, because they are localhost-only or required: systemd-resolved :53,
# chrony :323, cupsd :631. SSH is masked. Avahi (:5353) advertises the
# hostname. rpcbind (:111) is for NFS. wsdd (:3702) is Windows discovery.
mask_listeners() {
  local desc="$1"
  shift
  run_cmd "$desc" true
  if [ "$mode" != apply ]; then
    return 0
  fi
  local unit
  for unit in "$@"; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^${unit}"; then
      systemctl disable --now "$unit" || true
      systemctl mask "$unit" || true
    fi
  done
}

mask_listeners "disable ssh" ssh.service ssh.socket
mask_listeners "disable avahi" avahi-daemon.service avahi-daemon.socket
mask_listeners "disable rpcbind" rpcbind.service rpcbind.socket

run_cmd "disable wsdd" true
if [ "$mode" = apply ]; then
  wsdd_mount=/usr/share/gvfs/mounts/wsdd.mount
  if [ -f "$wsdd_mount" ] || [ -f "${wsdd_mount}.distrib" ]; then
    if [ ! -f "${wsdd_mount}.distrib" ]; then
      dpkg-divert --local --rename --divert "${wsdd_mount}.distrib" --add "$wsdd_mount"
    fi
    cat > "$wsdd_mount" <<'EOF'
[Mount]
Type=wsdd
Exec=/usr/libexec/gvfsd-wsdd
AutoMount=false
EOF
  fi
  if dpkg -s wsdd >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y wsdd
  fi
fi

# Package and timer only. The backup disk is the encrypted /home filesystem,
# which does not exist until the first-boot wizard finishes.
run_cmd "timeshift on encrypted home" true
if [ "$mode" = apply ]; then
  IMAGE_HARDEN_CONFIRM=1 bash "$here/setup-timeshift.sh" --install
fi

# --- security updates -------------------------------------------------------
run_cmd "unattended-upgrades" true
write_file "unattended-upgrades" /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
if [ "$mode" = apply ]; then
  systemctl enable --now unattended-upgrades.service || true
fi

# --- no autologin at the display manager ------------------------------------
run_cmd "gdm no autologin" true
if [ "$mode" = apply ]; then
  install -d /etc/gdm3
  if [ ! -f /etc/gdm3/custom.conf ]; then
    printf '[daemon]\n' > /etc/gdm3/custom.conf
  fi
  if ! grep -q '^\[daemon\]' /etc/gdm3/custom.conf; then
    printf '\n[daemon]\n' >> /etc/gdm3/custom.conf
  fi
  for key in AutomaticLoginEnable TimedLoginEnable WaylandEnable; do
    if grep -q "^${key}=" /etc/gdm3/custom.conf; then
      sed -i "s/^${key}=.*/${key}=false/" /etc/gdm3/custom.conf
    else
      sed -i "/^\[daemon\]/a ${key}=false" /etc/gdm3/custom.conf
    fi
  done
fi

# --- scratch dirs are not persistent disks ----------------------------------
run_cmd "tmpfs /tmp" true
if [ "$mode" = apply ]; then
  add_tmpfs() {
    local path="$1" size="$2" line
    line="tmpfs ${path} tmpfs defaults,nosuid,nodev,mode=1777,size=${size} 0 0"
    if grep -qE "^[^#]*[[:space:]]${path}[[:space:]]" /etc/fstab; then
      return 0
    fi
    echo "$line" >> /etc/fstab
  }
  add_tmpfs /tmp 2G
  add_tmpfs /var/tmp 1G
fi

# --- kernel exposure knobs. squashfs stays (snaps need it). ----------------
write_file "sysctl lockdown" /etc/sysctl.d/99-linux-image.conf <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.kexec_load_disabled = 1
fs.suid_dumpable = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF
if [ "$mode" = apply ]; then
  sysctl --system >/dev/null
fi

write_file "sysctl lockdown" /etc/modprobe.d/linux-image-fs.conf <<'EOF'
# Rare filesystems. Do not blacklist squashfs (snaps) or usb-storage (docks).
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install udf /bin/true
EOF

# --- crash reports stay on the machine --------------------------------------
run_cmd "disable apport" true
if [ "$mode" = apply ]; then
  if [ -f /etc/default/apport ]; then
    sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
  fi
  systemctl disable --now apport.service 2>/dev/null || true
fi

# --- later password changes. The first-boot wizard still accepts 8 via chpasswd.
write_file "pwquality" /etc/security/pwquality.conf.d/linux-image.conf <<'EOF'
minlen = 12
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
EOF

write_file "no core dumps" /etc/security/limits.d/99-linux-image.conf <<'EOF'
* hard core 0
EOF
write_file "no core dumps" /etc/systemd/coredump.conf.d/linux-image.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

write_file "journald cap" /etc/systemd/journald.conf.d/linux-image.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF

if [ "$mode" = apply ]; then
  systemctl enable apparmor.service || true
  install -d -m 700 /var/lib/linux-encryption-setup
  date -Is > /var/lib/linux-encryption-setup/baseline-hardened
  echo "Baseline lockdown applied. Encryption still runs from the first-boot wizard."
fi
