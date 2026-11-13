#!/bin/bash
# verify-security.sh — the 12 Nov 2026 security review's "Verification after the fix" list.
# Run on a freshly imaged Ubuntu laptop, as nextadmin, before the employee signs in:
#   curl -s http://192.168.26.106:8090/nocloud/extras/verify-security.sh | sudo bash
# Prints PASS/FAIL per check. Never prints file contents that could hold a secret.
set -u
pass=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }

echo "== Secrets are gone"
check "no seed user-data"            "test ! -e /opt/linux-encryption-setup/imaging/seed/nocloud/user-data"
check "no TECH-PASSWORD.txt"         "test ! -e /opt/linux-encryption-setup/imaging/seed/nocloud/TECH-PASSWORD.txt"
check "no installer log zip"          "test ! -e /tmp/nl-installer-logs.zip"
check "no setup bundle"               "test ! -e /opt/linux-encryption-setup.tar.gz"
check "no web GUI or wizard"          "test ! -e /opt/linux-encryption-setup/webgui"
check "atera folder is 700"           "[ \"\$(stat -c %a /etc/atera-agent)\" = 700 ]"
# The agent writes new files 644 after imaging; the 700 folder above is what keeps others out.
check "atera folder owned by root, others cannot enter" "[ \"\$(stat -c '%U %a' /etc/atera-agent)\" = 'root 700' ]"

echo "== Imaging data no longer leaves in clear"
check "boot-log timer gone"           "! systemctl is-enabled nextlink-boot-log.timer"
check "no unit still uses http://192.168.26.106" "! grep -rl 'http://192.168.26.106' /etc/systemd/system /usr/local/sbin"
check "only localhost listeners"      "[ -z \"\$(ss -lntuH | awk '{print \$5}' | grep -vE '^(127\\.|\\[::1\\]|::1)')\" ]"

echo "== Baseline still holds"
check "Secure Boot on"                "mokutil --sb-state | grep -qi enabled"
check "root is encrypted"             "lsblk -s -no TYPE \"\$(findmnt -no SOURCE /)\" | grep -q crypt"
check "ufw active, deny incoming"     "ufw status verbose | grep -q 'deny (incoming)'"
check "ssh server not running"        "! systemctl is-active ssh"
check "no nullok"                     "! grep -q nullok /etc/pam.d/common-auth"
check "faillock in PAM"               "grep -q pam_faillock /etc/pam.d/common-auth"
check "sudoers linux-sudo 440 root"   "[ \"\$(stat -c '%a %U %G' /etc/sudoers.d/linux-sudo)\" = '440 root root' ]"
check "nextadmin not in lxd"          "! id -nG nextadmin | grep -qw lxd"
check "telnet/ftp/tnftp not installed" "! dpkg -s telnet ftp tnftp 2>/dev/null | grep -q 'Status: install ok'"
check "cups-browsed off"              "! systemctl is-active cups-browsed"
check "kdump off"                     "! systemctl is-active kdump-tools"
check "whoopsie off"                  "! systemctl is-active whoopsie"
check "serial console login off"      "! systemctl is-active serial-getty@ttyS0"
check "hostname is NL-<serial>"       "hostname | grep -q '^NL-'"
check "legal notice on sign-in screen" "grep -q 'Authorized use only' /etc/dconf/db/gdm.d/01-entra-login"
check "no autologin"                  "grep -q '^AutomaticLoginEnable=false' /etc/gdm3/custom.conf"
check "lock screen policy locked"     "test -f /etc/dconf/db/local.d/locks/00-nextlink-security"
check "no pending security updates"   "[ -z \"\$(apt list --upgradable 2>/dev/null | grep -- -security)\" ]"
check "Wazuh running"                 "systemctl is-active wazuh-agent"
check "Atera running"                 "systemctl is-active AteraAgent"
check "UniFi Endpoint installed"      "dpkg -s unifi-endpoint | grep -q 'install ok installed'"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
