#!/bin/bash
# harden-image-baseline.sh — OS lockdown for the Ubuntu 26.04 laptop image.
#
# Does not partition, format, or touch LUKS/TPM (the installer does TPM full-disk encryption).
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
    # Mask unconditionally: template instances such as
    # serial-getty@ttyS0 never show in the unit file list, and masking an absent unit is harmless.
    systemctl disable --now "$unit" 2>/dev/null || true
    systemctl mask "$unit" || true
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

# No Timeshift: its backup disk was the wizard's separate home volume, which the TPM full-disk
# image does not have, so the hourly timer only ever no-op'd (security review M6).
run_cmd "no timeshift timer" true
if [ "$mode" = apply ]; then
  systemctl disable --now linux-image-timeshift.timer 2>/dev/null || true
  rm -f /etc/systemd/system/linux-image-timeshift.timer /etc/systemd/system/linux-image-timeshift.service
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
  # Shared memory: no programs run from it (review L1). /tmp stays executable for installers.
  grep -qE '^[^#]*[[:space:]]/dev/shm[[:space:]]' /etc/fstab \
    || echo "tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0" >> /etc/fstab
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
# Security review L1: no SysRq keys, log spoofed packets, and no core file even if a process
# ignores the core limit.
kernel.sysrq = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.core_pattern = |/bin/false
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

# --- security review 12 Nov 2026 (M1, M2, M3, M5, H4, C1, L1) ------------------------------
# Failed local logins: lock for 15 minutes after 5 tries, and no empty passwords (M1).
write_file "faillock" /etc/security/faillock.conf <<'EOF'
deny = 5
unlock_time = 900
EOF
write_file "faillock" /usr/share/pam-configs/nextlink-faillock <<'EOF'
Name: Lock an account for 15 minutes after 5 failed logins (Nextlink image)
Default: yes
Priority: 0
Auth-Type: Primary
Auth:
	[default=die] pam_faillock.so authfail
	sufficient pam_faillock.so authsucc
EOF
write_file "faillock" /usr/share/pam-configs/nextlink-faillock-preauth <<'EOF'
Name: Check the failed login counter first (Nextlink image)
Default: yes
Priority: 1024
Auth-Type: Primary
Auth:
	requisite pam_faillock.so preauth
EOF
if [ "$mode" = apply ]; then
  pam-auth-update --enable nextlink-faillock nextlink-faillock-preauth --package || true
  sed -i 's/[[:space:]]nullok\b//' /etc/pam.d/common-auth
fi

# Lock screen and USB rules the person cannot switch off (M2). Drives still mount (docks).
write_file "locked desktop policy" /etc/dconf/db/local.d/00-nextlink-security <<'EOF'
[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0
ubuntu-lock-on-suspend=true

[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/privacy]
usb-protection=true
usb-protection-level='lockscreen'

[org/gnome/desktop/media-handling]
automount-open=false
EOF
write_file "locked desktop policy" /etc/dconf/db/local.d/locks/00-nextlink-security <<'EOF'
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/lock-delay
/org/gnome/desktop/screensaver/ubuntu-lock-on-suspend
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/privacy/usb-protection
/org/gnome/desktop/privacy/usb-protection-level
/org/gnome/desktop/media-handling/automount-open
EOF
if [ "$mode" = apply ]; then
  install -d /etc/dconf/profile
  [ -f /etc/dconf/profile/user ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
  dconf update || true
fi

# Services a laptop does not need (M3, M5, H4). CUPS stays on localhost; Bluetooth stays.
mask_listeners "disable cups-browsed" cups-browsed.service
mask_listeners "disable crash and news phone-home" whoopsie.service whoopsie.path motd-news.timer motd-news.service apport-autoreport.timer apport-autoreport.path
mask_listeners "disable serial console login" serial-getty@ttyS0.service
run_cmd "disable kdump and openvpn" true
if [ "$mode" = apply ]; then
  systemctl disable --now kdump-tools.service openvpn.service 2>/dev/null || true
  if [ -f /etc/default/kdump-tools ]; then sed -i 's/^USE_KDUMP=.*/USE_KDUMP=0/' /etc/default/kdump-tools; fi
fi

# Old clear-text clients go everywhere; network tools only come back when the form checks
# them (Engineering's Wireshark and Zenmap install after this, review M3).
run_cmd "remove telnet ftp and unchecked network tools" true
if [ "$mode" = apply ]; then
  export DEBIAN_FRONTEND=noninteractive
  for pkg in telnet ftp tnftp inetutils-telnet inetutils-ftp nmap zenmap tcpdump wireshark wireshark-qt tshark; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then apt-get purge -y "$pkg" || true; fi
  done
fi

# NextAdmin: not in lxd, which is root-equivalent if LXD is ever installed (C1).
run_cmd "nextadmin out of lxd" true
if [ "$mode" = apply ]; then
  gpasswd -d nextadmin lxd >/dev/null 2>&1 || true
fi

# SSH client: do not offer Kerberos to arbitrary servers (L1).
write_file "ssh client gssapi off" /etc/ssh/ssh_config.d/50-nextlink.conf <<'EOF'
GSSAPIAuthentication no
EOF

if [ "$mode" = apply ]; then
  systemctl enable apparmor.service || true
  install -d -m 700 /var/lib/linux-encryption-setup
  date -Is > /var/lib/linux-encryption-setup/baseline-hardened
  echo "Baseline lockdown applied."
fi
