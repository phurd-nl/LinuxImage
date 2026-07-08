# LinuxEncryption

LUKS2 `/home` encryption + TPM auto-unlock for Ubuntu laptops, with a mandatory
first-boot LUKS password-box wizard. Shell scripts do the disk work; `webgui/`
drives unattended setup on golden images. Read `RUNBOOK.md` before touching disks.

## Layout

- `RUNBOOK.md` — verified hardware facts, order of operations, recovery notes.
- `webgui/` — Ubuntu first-boot wizard (password box UI + `server.py` API).
- `scripts/NN-*.sh` — numbered = strict execution order. Run as `sudo bash scripts/NN-*.sh`.
- `scripts/{build,install-setup-wizard,prepare-ubuntu-image,orchestrate-firstboot,detect-hardware}.sh` — build/deploy/first-boot.
- `scripts/{check,verify-encryption,after-reboot,test-selfheal,verify-wizard}.sh` — diagnostics.

## Build & deploy (do NOT run encryption on the dev machine)

```bash
bash scripts/build.sh                              # validate + tarball (safe on dev machine)
sudo bash scripts/deploy.sh                        # install to /opt on a target VM
sudo bash scripts/prepare-ubuntu-image.sh          # template VM only, before capture
sudo bash scripts/mark-wizard-complete.sh          # skip wizard on already-done machines
```

Golden images need ≥50 GB unallocated at end of boot disk. New laptops: user enters
login password in the wizard; everything else is automatic.

## Script order (do NOT reorder)

`01` create p4 → `02` encrypt+migrate+seal+PAM → reboot/test → `04` purge old
plaintext `/home` → recovery: `05` add recovery passphrase → `06` restore TPM
auto-unlock → `07` cleanup stray keyslots → `08` re-seal to PCR 7 only + self-heal.
(`03` was removed; it assumed the wrong mountpoint.)

## SAFETY — this tooling is destructive and machine-specific

- Machine/user values are centralized in `scripts/config.sh` (`DISK`, `PARTNUM`,
  `USERNAME`, `MAPPER`; `LUKS_DEV` derived). Every script sources it; the installed
  PAM helpers get the values baked in via `__DEV__`/`__MAPPER__`/`__USER__`→sed.
  Defaults are THIS machine (`/dev/nvme0n1` p4, `phurd`, `home_crypt`). To retarget,
  edit `config.sh` and run `bash scripts/test-config.sh` — do NOT re-hardcode literals
  back into the scripts.
- `04-purge-shadowed-plaintext-home.sh` is IRREVERSIBLE (wipes the plaintext
  `/home` copy). Only after reboot+login proves `/home` is `/dev/mapper/home_crypt`.
- `02` reformats `nvme0n1p4`. It refuses if the device has any existing signature.
- Keyslot operations can lock the user out. `05` (recovery passphrase) before any
  TPM/clevis change; `07` proves a known passphrase still opens the volume before
  removing slots; recovery passphrase is the offline floor — preserve it.
- The TPM seal uses PCR 7 only (after `08`) so firmware/BIOS updates don't lock
  out. Re-seal after a Secure Boot key change: `sudo clevis-reseal`.

## Conventions

- Every script: `set -euo pipefail`, root check, header comment explaining intent
  + guards + reversibility. Match this when adding/editing scripts.
- Destructive scripts guard before acting (existence/signature/passphrase checks)
  and abort loudly; preserve those guards.
- Logs go to `/var/log/luks-*.log` via `exec > >(tee -a ...)`.
- Installed runtime artifacts live outside the repo: `/etc/luks-keyfile.jwe`,
  `/usr/local/sbin/home-crypt-{open,close}`, `clevis-reseal`, PAM hooks in
  `/etc/pam.d/common-{auth,session}`.
