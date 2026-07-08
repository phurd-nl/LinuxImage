#!/bin/bash
# ansible-push-recovery.sh — document Ansible recovery passphrase integration.
#
# The wizard uses two optional env vars on linux-encryption-wizard.service:
#   ANSIBLE_API_URL  — GET recovery passphrase before setup (Ansible generates it)
#   ANSIBLE_PUSH_URL — PUT generated passphrase after setup (wizard generates it)
#
# API shape (implement on your Ansible server):
#   POST/GET {ANSIBLE_API_URL}/api/v1/machines/{hostname}/luks-recovery-passphrase
#   PUT        {ANSIBLE_PUSH_URL}/api/v1/machines/{hostname}/luks-recovery-passphrase
#   Body: {"hostname":"...","passphrase":"..."}
#
# Run: bash scripts/ansible-push-recovery.sh
set -euo pipefail
echo "Configure in /etc/systemd/system/linux-encryption-wizard.service:"
echo "  Environment=ANSIBLE_API_URL=https://ansible.example.com"
echo "  Environment=ANSIBLE_PUSH_URL=https://ansible.example.com"
echo "Then: sudo systemctl daemon-reload && sudo systemctl restart linux-encryption-wizard"